# apps/scheduler/main.py
#
# PIPELINE OVERVIEW (runtime order):
#
#   1. scheduler  (this file, runs in infra-scheduler-1)
#        - decides WHICH sources to poll (YouTube channels, RSS feeds)
#        - enforces throttling / staggering / freshness window
#        - calls youtube_rss_poll(...) / rss_poll(...)
#
#      ↓ those pollers enqueue AdapterEvents into the "events" RQ queue
#
#   2. workers    (infra-workers-1, rq worker "events")
#        - consume "events"
#        - normalize each event into a canonical story dict
#        - enqueue that story into the "sanitize" RQ queue
#
#   3. sanitizer  (infra-sanitizer-1, rq worker "sanitize")
#        - dedupe by semantic signature ("first one wins")
#        - if brand new:
#             * LPUSH into Redis public feed list
#             * trim list
#             * publish realtime fanout
#             * enqueue optional push
#          else drop as duplicate
#
#   4. api        (infra-api-1)
#        - serves /v1/feed by reading the Redis list
#
# IMPORTANT CONTRACTS:
# - scheduler NEVER writes to the public feed list.
# - scheduler NEVER dedupes.
# - scheduler just keeps feeding poll work into the pipeline forever
#   (or once if ONE_SHOT=true).
#
# CONFIG SOURCES:
# - Environment variables (.env / compose)
# - YAML file pointed at by $SOURCES_FILE (default /app/infra/source.yml)
#
# We don't silently invent timing defaults in code. Critical cadence knobs
# like POLL_INTERVAL_MIN and PUBLISHED_AFTER_HOURS must be provided by config,
# so ops controls prod behavior without touching code.


import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Tuple, Dict, Any
from urllib.parse import urlparse

from apps.workers.jobs import youtube_rss_poll, rss_poll

# Optional YAML support. It's okay if YAML is missing; we'll fall back to env.
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def _utc_now() -> datetime:
    """Current time in UTC as an aware datetime."""
    return datetime.now(timezone.utc)


def _log(msg: str) -> None:
    """
    Log with a UTC timestamp so all containers (scheduler/workers/sanitizer/api)
    can be correlated easily in logs.
    """
    print(f"[scheduler] {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')}Z  {msg}")


def _env_list(name: str) -> List[str]:
    """
    Parse a comma/newline-separated env var into a list, skipping blank lines
    and comments starting with '#'.

    Example:
        RSS_FEEDS="https://site.com/rss|news, https://other.com/feed|release"
    -> ["https://site.com/rss|news", "https://other.com/feed|release"]
    """
    raw = os.getenv(name, "")
    items: List[str] = []
    for chunk in raw.replace("\r", "\n").split("\n"):
        for part in chunk.split(","):
            s = part.strip()
            if not s or s.startswith("#"):
                continue
            items.append(s)
    return items


def _parse_rss_specs(specs: Iterable[str]) -> List[Tuple[str, str]]:
    """
    Turn env-style RSS specs into (url, kind_hint) pairs.

    "<url>|<kind_hint>" -> (url, kind_hint)
    "<url>"             -> (url, "news")
    """
    out: List[Tuple[str, str]] = []
    for s in specs:
        if "|" in s:
            url, hint = s.split("|", 1)
            out.append((url.strip(), (hint or "news").strip()))
        else:
            out.append((s.strip(), "news"))
    return out


def _domain_from_url(url: str) -> str:
    """
    Extract host from URL ("https://www.pinkvilla.com/x" -> "pinkvilla.com").
    Used for per-domain throttling.
    """
    try:
        d = urlparse(url).netloc.lower()
        return d[4:] if d.startswith("www.") else d
    except Exception:
        return ""


# ---------------------------------------------------------------------------
# config dataclasses
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # per-channel poll cap override


@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # per-feed poll cap override


@dataclass(frozen=True)
class Config:
    # which sources to poll
    yt: List[YTSpec]
    rss: List[RSSSpec]

    # cadence / pacing
    poll_every_min: int          # REQUIRED: how often we run a full loop
    published_after_hours: float # REQUIRED: freshness cutoff for stories
    spread_seconds: float        # OPTIONAL: delay between polls inside one loop
    jitter_seconds: float        # OPTIONAL: random pad added to sleep between loops
    one_shot: bool               # if True: do exactly one poll cycle then exit

    # global caps for each source type
    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    # per-run source limits to avoid hammering everything every loop
    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    # throttle map { "pinkvilla.com": 20, "default": 5, ... }
    throttle_per_domain: Dict[str, int]

    # feature toggles
    enable_youtube: bool
    enable_rss: bool


# ---------------------------------------------------------------------------
# config loader
# ---------------------------------------------------------------------------

def _require_number(val: object | None, name: str) -> float:
    """
    Enforce that critical timing knobs are explicitly configured.
    We don't silently invent defaults here because prod cadence matters.

    If it's not provided (None or ""), we raise so ops notices.
    """
    if val is None or val == "":
        raise RuntimeError(
            f"Missing required setting: {name} "
            f"(set it in .env or in scheduler.* of your sources file)"
        )
    return float(val)


def _read_config() -> Config:
    """
    Merge environment variables + YAML (SOURCES_FILE) into a single Config.

    Priority:
      - env overrides
      - YAML defaults

    This allows changing poll cadence, source lists, throttling, etc.
    without rebuilding code.
    """
    # Compose normally sets SOURCES_FILE=/app/infra/source.yml
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"

    S: Dict[str, Any] = {}
    if yaml and os.path.exists(sources_path):
        try:
            with open(sources_path, "r", encoding="utf-8") as f:
                S = yaml.safe_load(f) or {}
        except Exception as e:
            _log(f"Warning: unable to read sources file '{sources_path}': {e!r}")

    sched_yaml = (S.get("scheduler") or {}) if isinstance(S, dict) else {}

    # --- required cadence / freshness window ---
    poll_every_min = int(
        _require_number(
            os.getenv("POLL_INTERVAL_MIN", sched_yaml.get("poll_interval_min")),
            "POLL_INTERVAL_MIN / scheduler.poll_interval_min",
        )
    )

    published_after_hours = _require_number(
        os.getenv("PUBLISHED_AFTER_HOURS", sched_yaml.get("published_after_hours")),
        "PUBLISHED_AFTER_HOURS / scheduler.published_after_hours",
    )

    # --- optional pacing knobs ---
    # If not provided, explicitly default to 0.0 (we don't hide defaults in logic).
    spread_env = os.getenv("POLL_SPREAD_SEC")
    jitter_env = os.getenv("POLL_JITTER_SEC")

    spread_seconds = float(spread_env) if spread_env not in (None, "") \
        else float(sched_yaml.get("poll_spread_sec") or 0)

    jitter_seconds = float(jitter_env) if jitter_env not in (None, "") \
        else float(sched_yaml.get("poll_jitter_sec") or 0)

    # --- run mode ---
    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # --- global caps (optional) ---
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # --- feature toggles ---
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss     = os.getenv("ENABLE_RSS_INGEST", "true").lower()     not in ("0", "false", "no")

    # --- per-run source limits ---
    per_run_yaml = (sched_yaml.get("per_run_limits") or {})
    per_run_limit_yt  = int(per_run_yaml["youtube_channels"]) if "youtube_channels" in per_run_yaml else None
    per_run_limit_rss = int(per_run_yaml["rss_feeds"])        if "rss_feeds"        in per_run_yaml else None

    # --- throttle map ---
    # Example YAML:
    # throttle:
    #   per_domain_min_seconds:
    #     default: 5
    #     pinkvilla.com: 20
    throttle: Dict[str, int] = {}
    th = ((S.get("throttle") or {}).get("per_domain_min_seconds") or {}) if isinstance(S, dict) else {}
    for host, secs in (th.items() if isinstance(th, dict) else []):
        try:
            throttle[str(host)] = int(secs)
        except Exception:
            pass

    # --- YouTube channel specs ---
    yt_specs: List[YTSpec] = []
    yt_cfg = S.get("youtube") or {}
    channels = (yt_cfg.get("channels") or []) if isinstance(yt_cfg, dict) else []
    yt_def_max = (yt_cfg.get("defaults") or {}).get("max_items_per_poll") if isinstance(yt_cfg, dict) else None

    for ch in channels:
        if not isinstance(ch, dict) or not ch.get("enabled", True):
            continue
        cid = ch.get("channel_id")
        if not cid:
            continue
        mi = ch.get("max_items_per_poll", yt_def_max)
        yt_specs.append(
            YTSpec(
                channel_id=str(cid),
                max_items=int(mi) if mi else None,
            )
        )

    # fallback to env if YAML had no channels
    if not yt_specs:
        yt_specs = [YTSpec(ch) for ch in _env_list("YT_CHANNELS")]

    # --- RSS feed specs ---
    # We support:
    #   rss:
    #     defaults: { kind_hint: "news", max_items_per_poll: 10 }
    #     feeds:
    #       - { url: "...", kind_hint: "release", enabled: true }
    #
    # or:
    #   rss:
    #     defaults: ...
    #     buckets:
    #       bollywood:
    #         enabled: true
    #         feeds:
    #           - { url: "...", kind_hint: "news", enabled: true }
    #
    # Optionally scheduler.rss_buckets_enabled can whitelist certain buckets.
    def _collect_group_feeds(top: Dict[str, Any], block_key: str, default_kind: str) -> List[RSSSpec]:
        out: List[RSSSpec] = []
        block = top.get(block_key)
        if not isinstance(block, dict):
            return out

        # bucketed mode
        if "buckets" in block and isinstance(block.get("buckets"), dict):
            defaults = block.get("defaults") or {}
            def_kind = str(defaults.get("kind_hint") or default_kind or "news")
            def_max  = defaults.get("max_items_per_poll")

            buckets = block.get("buckets") or {}

            # if scheduler.rss_buckets_enabled exists, only poll those buckets;
            # else poll all enabled buckets
            enabled_list = (sched_yaml.get("rss_buckets_enabled") or None)
            enabled_names = set(enabled_list) if enabled_list else set(buckets.keys())

            for bname, bucket in buckets.items():
                if not isinstance(bucket, dict) or not bucket.get("enabled", True):
                    continue
                if bname not in enabled_names:
                    continue

                for feed in (bucket.get("feeds") or []):
                    if not isinstance(feed, dict) or not feed.get("enabled", True):
                        continue
                    url = (feed.get("url") or "").strip()
                    if not url:
                        continue

                    kind = str(feed.get("kind_hint") or def_kind or "news")
                    mi   = feed.get("max_items_per_poll", def_max)

                    out.append(
                        RSSSpec(
                            url=url,
                            kind_hint=kind,
                            max_items=int(mi) if mi else None,
                        )
                    )
            return out

        # flat mode
        defaults = block.get("defaults") or {}
        def_kind = str(defaults.get("kind_hint") or default_kind or "news")
        def_max  = defaults.get("max_items_per_poll")

        for feed in (block.get("feeds") or []):
            if not isinstance(feed, dict) or not feed.get("enabled", True):
                continue
            url = (feed.get("url") or "").strip()
            if not url:
                continue

            kind = str(feed.get("kind_hint") or def_kind or "news")
            mi   = feed.get("max_items_per_poll", def_max)

            out.append(
                RSSSpec(
                    url=url,
                    kind_hint=kind,
                    max_items=int(mi) if mi else None,
                )
            )

        return out

    rss_specs: List[RSSSpec] = []
    if isinstance(S, dict):
        # main "rss" block, if present
        rss_specs.extend(_collect_group_feeds(S, "rss", default_kind="news"))

        # any other top-level block that looks like an rss group / bucket set
        for key, val in S.items():
            if key in ("youtube", "scheduler", "throttle", "rss"):
                continue
            if isinstance(val, dict) and ("feeds" in val or "buckets" in val):
                rss_specs.extend(_collect_group_feeds(S, key, default_kind="news"))

    # fallback to env if YAML had no feeds
    if not rss_specs:
        rss_specs = [
            RSSSpec(url=u, kind_hint=k)
            for (u, k) in _parse_rss_specs(_env_list("RSS_FEEDS"))
        ]

    return Config(
        yt=yt_specs,
        rss=rss_specs,
        poll_every_min=int(poll_every_min),
        published_after_hours=float(published_after_hours),
        spread_seconds=float(spread_seconds),
        jitter_seconds=float(jitter_seconds),
        one_shot=one_shot,
        yt_global_max_items=yt_global_max_items,
        rss_global_max_items=rss_global_max_items,
        per_run_limit_yt=per_run_limit_yt,
        per_run_limit_rss=per_run_limit_rss,
        throttle_per_domain=throttle,
        enable_youtube=enable_youtube,
        enable_rss=enable_rss,
    )


# ---------------------------------------------------------------------------
# throttling
# ---------------------------------------------------------------------------

class _Throttle:
    """
    Per-domain throttle guard.

    Example throttle map:
        { "default": 5, "pinkvilla.com": 20 }
    means:
        - wait at least 5s before hitting any domain not explicitly listed
        - wait at least 20s between consecutive polls to pinkvilla.com
    """
    def __init__(self, per_domain: Dict[str, int]):
        self.rules = per_domain or {}
        self.last: Dict[str, float] = {}

    def wait_for(self, host: str) -> None:
        if not host:
            return

        min_gap = self.rules.get(host) or self.rules.get("default")
        if not min_gap:
            return

        now = time.monotonic()
        last = self.last.get(host)

        # first time hitting this host -> just record timestamp
        if last is None:
            self.last[host] = now
            return

        delay = (last + float(min_gap)) - now
        if delay > 0:
            _log(f"Throttle: sleeping {delay:.1f}s before hitting {host}")
            time.sleep(delay)

        # record the hit time (fresh monotonic after sleep)
        self.last[host] = time.monotonic()


# ---------------------------------------------------------------------------
# one polling cycle
# ---------------------------------------------------------------------------

def _poll_once(cfg: Config) -> None:
    """
    Run a single poll cycle:

    - Shuffle sources for fairness.
    - Respect per_run_limit_* so we don't hit everything every loop.
    - Throttle per domain.
    - Call youtube_rss_poll(...) / rss_poll(...).
      Those pollers enqueue AdapterEvents into the "events" RQ queue.

    CRITICAL:
    We do NOT write anything directly to the public feed list here.
    We do NOT dedupe here.
    That is sanitizer's job downstream.
    """
    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("All ingestion toggles disabled; nothing to poll.")
        return

    # Freshness cutoff (e.g. 'only consider videos newer than the last X hours')
    since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours and cfg.published_after_hours > 0
        else None
    )

    yt_list = list(cfg.yt) if cfg.enable_youtube else []
    rss_list = list(cfg.rss) if cfg.enable_rss else []

    # Randomize poll order each cycle so we don't starve the same tail every time.
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # Per-cycle caps (helps spread load across cycles)
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- YouTube poll loop ---
    for ch in yt_list:
        try:
            throttle.wait_for("youtube.com")

            max_items = ch.max_items if ch.max_items is not None else cfg.yt_global_max_items
            if max_items is None:
                youtube_rss_poll(ch.channel_id, published_after=since)
            else:
                youtube_rss_poll(
                    ch.channel_id,
                    published_after=since,
                    max_items=int(max_items),
                )

        except Exception as e:
            _log(f"ERROR polling YouTube channel={ch.channel_id}: {e!r}")

        # Stagger calls within one poll cycle if configured
        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)

    # --- RSS poll loop ---
    for feed in rss_list:
        try:
            host = _domain_from_url(feed.url)
            throttle.wait_for(host)

            max_items = feed.max_items if feed.max_items is not None else cfg.rss_global_max_items
            if max_items is None:
                rss_poll(feed.url, kind_hint=feed.kind_hint)
            else:
                rss_poll(
                    feed.url,
                    kind_hint=feed.kind_hint,
                    max_items=int(max_items),
                )

        except Exception as e:
            _log(f"ERROR polling RSS url={feed.url}: {e!r}")

        # Stagger RSS calls too
        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)


# ---------------------------------------------------------------------------
# main loop
# ---------------------------------------------------------------------------

def main() -> None:
    cfg = _read_config()

    _log(
        "Start: "
        f"{len(cfg.yt)} YT channels, {len(cfg.rss)} RSS feeds; "
        f"every {cfg.poll_every_min}m (spread {cfg.spread_seconds}s, "
        f"jitter ≤ {cfg.jitter_seconds}s, "
        f"window {cfg.published_after_hours}h)."
    )

    # If everything is disabled or empty, just idle (don't crash-loop).
    if (not cfg.enable_youtube and not cfg.enable_rss) or (not cfg.yt and not cfg.rss):
        _log("Empty or disabled config; sleeping.")
        while True:
            time.sleep(300)

    while True:
        started = time.monotonic()

        _poll_once(cfg)

        if cfg.one_shot:
            _log("ONE_SHOT=1: exiting after a single cycle.")
            return

        elapsed = time.monotonic() - started

        # We want each cycle to START roughly every poll_every_min (+ optional jitter).
        base_sleep = float(cfg.poll_every_min) * 60.0
        jitter = random.uniform(
            0.0,
            float(cfg.jitter_seconds) if cfg.jitter_seconds else 0.0,
        )
        sleep_for = (base_sleep + jitter) - elapsed
        if sleep_for < 0:
            sleep_for = 0.0

        _log(f"Cycle took {elapsed:.1f}s; sleeping {sleep_for:.1f}s.")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
