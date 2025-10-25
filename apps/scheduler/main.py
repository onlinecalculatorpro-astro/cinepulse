# apps/scheduler/main.py
#
# RUNTIME ROLE (this container = the "scheduler" process)
#
# PIPELINE RECAP
#   scheduler  → decides *what to poll* and *when*, then calls:
#                  - youtube_rss_poll(...)
#                  - rss_poll(...)
#                those pollers enqueue AdapterEventDict jobs into the "events" RQ queue
#
#   workers    → (rq worker "events")
#                normalize_event() turns AdapterEventDict → canonical story dict
#                and enqueues sanitize_story() onto the "sanitize" queue
#
#   sanitizer  → (rq worker "sanitize")
#                - dedupe (first unique version wins forever)
#                - publish to Redis feed list
#                - fanout (pubsub, stream)
#                - optional push notifications
#
#   api        → serves /v1/feed from Redis
#
# GUARANTEES:
# - scheduler never writes to the public feed list.
# - scheduler never dedupes.
# - scheduler just keeps feeding fresh source content into the pipeline.
#
# CONFIG SOURCES:
# - environment variables
# - optional YAML pointed to by $SOURCES_FILE (docker compose can mount this)
#
# Things ops must control at runtime (not buried in code defaults):
#   POLL_INTERVAL_MIN          → how often to run a full poll cycle
#   PUBLISHED_AFTER_HOURS      → ignore items older than this window
#
# We read those explicitly. If they're missing, we raise. That prevents
# "oops we shipped to prod with debug cadence".
#
# High-level flow:
#   while True:
#       pick which YT channels / RSS feeds to poll this cycle (can limit per cycle)
#       throttle domains so we don't hammer e.g. pinkvilla.com
#       call youtube_rss_poll(...) / rss_poll(...)
#       sleep until next cycle boundary (+ jitter)
#
# If ONE_SHOT=1, we run exactly one cycle and exit (handy for backfills/tests).

from __future__ import annotations

import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Tuple, Any
from urllib.parse import urlparse

from apps.workers.jobs import youtube_rss_poll, rss_poll

# YAML is optional. If not present, we fall back to env-only mode.
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


# =============================================================================
# basic helpers / logging
# =============================================================================

def _utc_now() -> datetime:
    """Return timezone-aware UTC now() so downstream timestamps are consistent."""
    return datetime.now(timezone.utc)


def _log(msg: str) -> None:
    """
    Print with a UTC timestamp prefix so logs from scheduler / workers / sanitizer
    can be correlated when tailed together.
    """
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[scheduler] {ts}Z  {msg}")


def _domain_from_url(url: str) -> str:
    """
    Extract "pinkvilla.com" from "https://www.pinkvilla.com/x".
    Used for per-domain throttling.
    """
    try:
        netloc = urlparse(url).netloc.lower()
        return netloc[4:] if netloc.startswith("www.") else netloc
    except Exception:
        return ""


def _env_list(name: str) -> List[str]:
    """
    Parse an env var that may be comma-separated and/or newline-separated and
    may contain comments (# ...). Return a clean list of non-empty entries.

    Example:
        export RSS_FEEDS="
            https://variety.com/feed|news,
            https://pinkvilla.com/rss     # default kind=news
        "

    -> ["https://variety.com/feed|news", "https://pinkvilla.com/rss"]
    """
    raw = os.getenv(name, "")
    out: List[str] = []
    for chunk in raw.replace("\r", "\n").split("\n"):
        for part in chunk.split(","):
            s = part.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    return out


def _parse_rss_specs(specs: Iterable[str]) -> List[Tuple[str, str]]:
    """
    Turn "url|kind_hint" or just "url" into [(url, kind_hint)].
    kind_hint defaults to "news".
    """
    items: List[Tuple[str, str]] = []
    for s in specs:
        if "|" in s:
            url, hint = s.split("|", 1)
            items.append((url.strip(), (hint or "news").strip()))
        else:
            items.append((s.strip(), "news"))
    return items


# =============================================================================
# config dataclasses
# =============================================================================

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # per-channel override for max_items per poll


@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # per-feed override for max_items per poll


@dataclass(frozen=True)
class Config:
    # enabled sources to poll
    yt: List[YTSpec]
    rss: List[RSSSpec]

    # cadence / pacing
    poll_every_min: int            # required: run a full poll cycle this often
    published_after_hours: float   # required: how "fresh" items must be
    spread_seconds: float          # optional: sleep between each individual poll in a cycle
    jitter_seconds: float          # optional: random pad added to between-cycle sleep
    one_shot: bool                 # if True, run one cycle then exit

    # global cap knobs
    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    # per-cycle source limits (avoid hammering 200 feeds every loop)
    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    # throttle map: {domain -> min_seconds_between_hits}
    # e.g. { "pinkvilla.com": 20, "default": 5 }
    throttle_per_domain: Dict[str, int]

    # feature toggles
    enable_youtube: bool
    enable_rss: bool


# =============================================================================
# config loader
# =============================================================================

def _require_number(val: object | None, name: str) -> float:
    """
    Enforce that time-critical knobs are provided. If missing, raise loudly.
    We DO NOT silently invent poll cadence in code; ops must set it.
    """
    if val is None or val == "":
        raise RuntimeError(
            f"Missing required setting: {name} "
            "(set it in .env or scheduler.* in SOURCES_FILE)"
        )
    return float(val)


def _read_config() -> Config:
    """
    Merge ENV + YAML ($SOURCES_FILE, usually mounted by Docker compose) into a
    single runtime Config.

    Priority:
    - env values override YAML
    - YAML fills in structure like list of feeds/channels, throttling rules, etc.
    """
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"

    raw_cfg: Dict[str, Any] = {}
    if yaml and os.path.exists(sources_path):
        try:
            with open(sources_path, "r", encoding="utf-8") as f:
                raw_cfg = yaml.safe_load(f) or {}
        except Exception as e:
            _log(f"warning: can't parse {sources_path}: {e!r}")

    if not isinstance(raw_cfg, dict):
        raw_cfg = {}

    scheduler_yaml = raw_cfg.get("scheduler") or {}

    # ---- cadence / windows (required) ---------------------------------
    poll_every_min = int(
        _require_number(
            os.getenv("POLL_INTERVAL_MIN", scheduler_yaml.get("poll_interval_min")),
            "POLL_INTERVAL_MIN / scheduler.poll_interval_min",
        )
    )

    published_after_hours = _require_number(
        os.getenv("PUBLISHED_AFTER_HOURS", scheduler_yaml.get("published_after_hours")),
        "PUBLISHED_AFTER_HOURS / scheduler.published_after_hours",
    )

    # ---- pacing (optional) -------------------------------------------
    spread_env = os.getenv("POLL_SPREAD_SEC")
    jitter_env = os.getenv("POLL_JITTER_SEC")

    spread_seconds = float(spread_env) if spread_env not in (None, "") \
        else float(scheduler_yaml.get("poll_spread_sec") or 0)

    jitter_seconds = float(jitter_env) if jitter_env not in (None, "") \
        else float(scheduler_yaml.get("poll_jitter_sec") or 0)

    # ---- run mode ----------------------------------------------------
    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # ---- global max per poller call (optional) -----------------------
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # ---- feature toggles ---------------------------------------------
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss     = os.getenv("ENABLE_RSS_INGEST", "true").lower()     not in ("0", "false", "no")

    # ---- per-run limits (optional) -----------------------------------
    # lets us say "each poll cycle only hit first N channels/feeds"
    per_run_limits_yaml = scheduler_yaml.get("per_run_limits") or {}
    per_run_limit_yt  = int(per_run_limits_yaml["youtube_channels"]) if "youtube_channels" in per_run_limits_yaml else None
    per_run_limit_rss = int(per_run_limits_yaml["rss_feeds"])        if "rss_feeds"        in per_run_limits_yaml else None

    # ---- throttle config (optional) ----------------------------------
    # raw_cfg:
    #   throttle:
    #     per_domain_min_seconds:
    #       default: 5
    #       pinkvilla.com: 20
    throttle_per_domain: Dict[str, int] = {}
    thrott_root = raw_cfg.get("throttle") or {}
    per_dom = thrott_root.get("per_domain_min_seconds") or {}
    if isinstance(per_dom, dict):
        for host, secs in per_dom.items():
            try:
                throttle_per_domain[str(host)] = int(secs)
            except Exception:
                pass

    # ---- YouTube channels --------------------------------------------
    #
    # YAML shape:
    # youtube:
    #   defaults:
    #     max_items_per_poll: 5
    #   channels:
    #     - {channel_id: "UC123", enabled: true, max_items_per_poll: 3}
    yt_specs: List[YTSpec] = []
    yt_cfg = raw_cfg.get("youtube") or {}
    if isinstance(yt_cfg, dict):
        yt_defaults = yt_cfg.get("defaults") or {}
        yt_def_max = yt_defaults.get("max_items_per_poll")
        for ch in yt_cfg.get("channels", []):
            if not isinstance(ch, dict) or not ch.get("enabled", True):
                continue
            ch_id = ch.get("channel_id")
            if not ch_id:
                continue
            mi = ch.get("max_items_per_poll", yt_def_max)
            yt_specs.append(
                YTSpec(
                    channel_id=str(ch_id),
                    max_items=int(mi) if mi else None,
                )
            )

    # fallback to env if YAML didn't provide channels
    #   YT_CHANNELS="UCabc123, UCdef456"
    if not yt_specs:
        yt_specs = [YTSpec(cid) for cid in _env_list("YT_CHANNELS")]

    # ---- RSS feeds ---------------------------------------------------
    #
    # We support two YAML shapes:
    #
    # 1) Flat:
    # rss:
    #   defaults: { kind_hint: "news", max_items_per_poll: 10 }
    #   feeds:
    #     - { url: "https://variety.com/feed", enabled: true, kind_hint: "news" }
    #
    # 2) Bucketed (for region/language verticals):
    # rss:
    #   defaults: { kind_hint: "news", max_items_per_poll: 10 }
    #   buckets:
    #     bollywood:
    #       enabled: true
    #       feeds:
    #         - { url: "...koimoi...", kind_hint: "news", enabled: true }
    #
    # You can also define other top-level groups with similar shape and then
    # gate which buckets are active via scheduler.rss_buckets_enabled in YAML.
    #
    def _collect_group_feeds(root_cfg: Dict[str, Any], block_key: str, fallback_kind: str) -> List[RSSSpec]:
        """
        Extract [RSSSpec,...] from a given block key in YAML.
        Handles flat mode and bucketed mode.
        """
        results: List[RSSSpec] = []
        block = root_cfg.get(block_key)
        if not isinstance(block, dict):
            return results

        # bucketed mode
        if "buckets" in block and isinstance(block.get("buckets"), dict):
            defaults = block.get("defaults") or {}
            def_kind = str(defaults.get("kind_hint") or fallback_kind or "news")
            def_max  = defaults.get("max_items_per_poll")

            buckets = block.get("buckets") or {}

            # If scheduler lists rss_buckets_enabled, only poll those buckets.
            enabled_list = scheduler_yaml.get("rss_buckets_enabled")
            if enabled_list:
                enabled_bucket_names = set(enabled_list)
            else:
                enabled_bucket_names = set(buckets.keys())

            for bname, bucket in buckets.items():
                if not isinstance(bucket, dict) or not bucket.get("enabled", True):
                    continue
                if bname not in enabled_bucket_names:
                    continue

                for feed in (bucket.get("feeds") or []):
                    if not isinstance(feed, dict) or not feed.get("enabled", True):
                        continue
                    f_url = (feed.get("url") or "").strip()
                    if not f_url:
                        continue

                    kind = str(feed.get("kind_hint") or def_kind or "news")
                    mi   = feed.get("max_items_per_poll", def_max)

                    results.append(
                        RSSSpec(
                            url=f_url,
                            kind_hint=kind,
                            max_items=int(mi) if mi else None,
                        )
                    )
            return results

        # flat mode
        defaults = block.get("defaults") or {}
        def_kind = str(defaults.get("kind_hint") or fallback_kind or "news")
        def_max  = defaults.get("max_items_per_poll")

        for feed in (block.get("feeds") or []):
            if not isinstance(feed, dict) or not feed.get("enabled", True):
                continue
            f_url = (feed.get("url") or "").strip()
            if not f_url:
                continue

            kind = str(feed.get("kind_hint") or def_kind or "news")
            mi   = feed.get("max_items_per_poll", def_max)

            results.append(
                RSSSpec(
                    url=f_url,
                    kind_hint=kind,
                    max_items=int(mi) if mi else None,
                )
            )
        return results

    rss_specs: List[RSSSpec] = []

    # main "rss" block
    rss_specs.extend(_collect_group_feeds(raw_cfg, "rss", fallback_kind="news"))

    # any other top-level block that *looks* like an rss group
    for key, val in raw_cfg.items():
        if key in ("youtube", "scheduler", "throttle", "rss"):
            continue
        if isinstance(val, dict) and ("feeds" in val or "buckets" in val):
            rss_specs.extend(_collect_group_feeds(raw_cfg, key, fallback_kind="news"))

    # fallback to env if YAML gave us none
    #   RSS_FEEDS="https://variety.com/feed|news, https://pinkvilla.com/rss|news"
    if not rss_specs:
        rss_specs = [
            RSSSpec(url=u, kind_hint=k)
            for (u, k) in _parse_rss_specs(_env_list("RSS_FEEDS"))
        ]

    return Config(
        yt=yt_specs,
        rss=rss_specs,
        poll_every_min=poll_every_min,
        published_after_hours=float(published_after_hours),
        spread_seconds=float(spread_seconds),
        jitter_seconds=float(jitter_seconds),
        one_shot=one_shot,
        yt_global_max_items=yt_global_max_items,
        rss_global_max_items=rss_global_max_items,
        per_run_limit_yt=per_run_limit_yt,
        per_run_limit_rss=per_run_limit_rss,
        throttle_per_domain=throttle_per_domain,
        enable_youtube=enable_youtube,
        enable_rss=enable_rss,
    )


# =============================================================================
# throttling (politeness / rate control per domain)
# =============================================================================

class _Throttle:
    """
    Throttle calls to the same host so we don't blast someone's origin.
    Example throttle map:
        { "default": 5, "pinkvilla.com": 20 }
    Means we wait 20s between polls to pinkvilla.com and 5s between polls
    to everything else.
    """
    def __init__(self, per_domain: Dict[str, int]):
        self.rules = per_domain or {}
        self.last_hit: Dict[str, float] = {}

    def wait_for(self, host: str) -> None:
        if not host:
            return

        min_gap = self.rules.get(host) or self.rules.get("default")
        if not min_gap:
            # no throttle rule for this host
            return

        now = time.monotonic()
        last = self.last_hit.get(host)

        # first time calling this host -> just timestamp it
        if last is None:
            self.last_hit[host] = now
            return

        delay = (last + float(min_gap)) - now
        if delay > 0:
            _log(f"throttle: sleeping {delay:.1f}s before hitting {host}")
            time.sleep(delay)

        # record fresh hit time after potential sleep
        self.last_hit[host] = time.monotonic()


# =============================================================================
# one poll cycle
# =============================================================================

def _poll_once(cfg: Config) -> None:
    """
    Execute one full poll pass:
      - respect feature toggles (enable_youtube / enable_rss)
      - randomize source order to avoid always starving the tail
      - obey per_run_limit_* to avoid hammering 100+ feeds every loop
      - throttle per domain
      - call youtube_rss_poll(...) / rss_poll(...)

    NOTE:
    We ONLY enqueue work into RQ ("events"). We do not write feed. We do not dedupe.
    Sanitizer downstream is the only authority for publishing to feed.
    """
    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("all ingestion toggles disabled; skipping poll")
        return

    # freshness cutoff: "ignore anything older than X hours"
    cutoff_since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours and cfg.published_after_hours > 0
        else None
    )

    yt_list = list(cfg.yt) if cfg.enable_youtube else []
    rss_list = list(cfg.rss) if cfg.enable_rss else []

    # randomize order each cycle for fairness
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # only hit N sources per cycle if requested
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- YouTube channels -------------------------------------------
    for ch in yt_list:
        try:
            # YouTube is effectively one domain
            throttle.wait_for("youtube.com")

            # pick per-channel max_items override or global override
            max_items = ch.max_items if ch.max_items is not None else cfg.yt_global_max_items

            if max_items is None:
                youtube_rss_poll(
                    ch.channel_id,
                    published_after=cutoff_since,
                )
            else:
                youtube_rss_poll(
                    ch.channel_id,
                    published_after=cutoff_since,
                    max_items=int(max_items),
                )

        except Exception as e:
            _log(f"ERROR polling YouTube channel={ch.channel_id}: {e!r}")

        # spread out bursts within the same cycle so we don't spike-traffic
        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)

    # --- RSS feeds ---------------------------------------------------
    for feed in rss_list:
        try:
            host = _domain_from_url(feed.url)
            throttle.wait_for(host)

            max_items = feed.max_items if feed.max_items is not None else cfg.rss_global_max_items

            if max_items is None:
                rss_poll(
                    feed.url,
                    kind_hint=feed.kind_hint,
                )
            else:
                rss_poll(
                    feed.url,
                    kind_hint=feed.kind_hint,
                    max_items=int(max_items),
                )

        except Exception as e:
            _log(f"ERROR polling RSS url={feed.url}: {e!r}")

        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)


# =============================================================================
# main loop
# =============================================================================

def main() -> None:
    cfg = _read_config()

    _log(
        "boot: "
        f"{len(cfg.yt)} yt_channels, {len(cfg.rss)} rss_feeds | "
        f"interval={cfg.poll_every_min}m "
        f"window={cfg.published_after_hours}h "
        f"spread={cfg.spread_seconds}s "
        f"jitter≤{cfg.jitter_seconds}s "
        f"one_shot={cfg.one_shot}"
    )

    # If config is effectively empty, don't spin like crazy. Just idle.
    if (not cfg.enable_youtube and not cfg.enable_rss) or (not cfg.yt and not cfg.rss):
        _log("no enabled sources; sleeping forever (scheduler idle mode)")
        while True:
            time.sleep(300)

    while True:
        cycle_start = time.monotonic()

        _poll_once(cfg)

        if cfg.one_shot:
            _log("ONE_SHOT=1 → completed single poll pass, exiting.")
            return

        elapsed = time.monotonic() - cycle_start

        # We want each cycle START to be ~poll_every_min apart (+ jitter),
        # not "sleep exactly poll_every_min no matter how long polling took".
        base_period = float(cfg.poll_every_min) * 60.0
        jitter = random.uniform(
            0.0,
            float(cfg.jitter_seconds) if cfg.jitter_seconds else 0.0,
        )
        sleep_for = (base_period + jitter) - elapsed
        if sleep_for < 0:
            sleep_for = 0.0

        _log(f"cycle finished in {elapsed:.1f}s; sleeping {sleep_for:.1f}s")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
