# apps/scheduler/main.py
#
# ROLE IN PIPELINE (runtime order):
#
#   1. scheduler (this file, running in infra-scheduler-1)
#        - figures out which sources to poll (YouTube channels, RSS feeds)
#        - rate-limits them, staggers them, respects freshness window
#        - calls youtube_rss_poll(...) / rss_poll(...)
#
#      ↓ those pollers enqueue AdapterEvents into the "events" RQ queue
#
#   2. workers (infra-workers-1, rq worker events)
#        - consume "events"
#        - normalize each event into a canonical story dict
#        - enqueue the story to the "sanitize" queue
#
#   3. sanitizer (infra-sanitizer-1, rq worker sanitize)
#        - dedupe, first-one-wins
#        - if new: writes story into Redis feed list, fanout, optional push
#
#   4. api (infra-api-1)
#        - reads Redis feed list and serves /v1/feed to clients
#
# IMPORTANT:
# - scheduler does NOT push anything to the public feed.
# - scheduler does NOT dedupe.
# - scheduler just keeps adding poll work into the pipeline forever (or once,
#   if ONE_SHOT is set).
#
# Config comes from:
#   - env vars
#   - YAML file pointed at by $SOURCES_FILE (default /app/infra/source.yml)
#
# We do not hardcode operational cadence defaults in code. Required timing
# values must be provided in env/YAML. That keeps prod behavior controlled
# by config, not code.


import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Tuple, Dict, Any
from urllib.parse import urlparse

from apps.workers.jobs import youtube_rss_poll, rss_poll

# Optional YAML support
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


# ------------------------------------------------------------------------------
# basic helpers
# ------------------------------------------------------------------------------

def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _log(msg: str) -> None:
    # We log in UTC for consistency across containers.
    print(f"[scheduler] {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')}Z  {msg}")


def _env_list(name: str) -> List[str]:
    """
    Parse a comma/newline-separated env var into a list of strings, skipping blanks/#comments.
    Example:
        RSS_FEEDS="https://site.com/rss|news, https://other.com/feed|release"
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
    Each spec can be:
      "<url>|<kind_hint>"
    or just
      "<url>"
    where kind_hint falls back to "news".
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
    try:
        d = urlparse(url).netloc.lower()
        return d[4:] if d.startswith("www.") else d
    except Exception:
        return ""


# ------------------------------------------------------------------------------
# config dataclasses
# ------------------------------------------------------------------------------

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # optional per-channel poll cap override


@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # optional per-feed poll cap override


@dataclass(frozen=True)
class Config:
    yt: List[YTSpec]
    rss: List[RSSSpec]

    poll_every_min: int                 # required: how often we loop
    published_after_hours: float        # required: "freshness" cutoff
    spread_seconds: float               # optional: delay between polls in a single loop
    jitter_seconds: float               # optional: random pad added to sleep between loops
    one_shot: bool                      # exit after one cycle if True

    yt_global_max_items: Optional[int]  # global cap per-channel if not overridden
    rss_global_max_items: Optional[int] # global cap per-feed if not overridden

    per_run_limit_yt: Optional[int]     # how many YT channels we poll per cycle
    per_run_limit_rss: Optional[int]    # how many RSS feeds we poll per cycle

    throttle_per_domain: Dict[str, int] # { "pinkvilla.com": 30, "default": 5 }

    enable_youtube: bool                # feature flag
    enable_rss: bool                    # feature flag


# ------------------------------------------------------------------------------
# config loader
# ------------------------------------------------------------------------------

def _require_number(val: Optional[str] | Optional[float] | Optional[int], name: str) -> float:
    """
    Helper to enforce required numeric settings come from config.
    We don't silently invent defaults here because cadence in prod is important.
    """
    if val is None or val == "":
        raise RuntimeError(
            f"Missing required setting: {name} "
            f"(set it in .env or in scheduler.* of your sources file)"
        )
    return float(val)


def _read_config() -> Config:
    """
    Merge environment + sources YAML into a unified Config object.
    Priority:
      - env overrides
      - YAML defaults
    The idea: ops tweaks poll cadence / sources without code changes.
    """

    # Compose sets SOURCES_FILE=/app/infra/source.yml
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"
    S: Dict[str, Any] = {}
    if yaml and os.path.exists(sources_path):
        try:
            with open(sources_path, "r", encoding="utf-8") as f:
                S = yaml.safe_load(f) or {}
        except Exception as e:
            _log(f"Warning: unable to read sources file '{sources_path}': {e!r}")

    sched_yaml = (S.get("scheduler") or {}) if isinstance(S, dict) else {}

    # --- core cadence / freshness window (REQUIRED) ---
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

    # --- spread/jitter (OPTIONAL) ---
    # If not provided, default them to 0.0 (explicit here, not hidden magic in logic).
    spread_env = os.getenv("POLL_SPREAD_SEC")
    jitter_env = os.getenv("POLL_JITTER_SEC")

    spread_seconds = float(spread_env) if spread_env not in (None, "") \
        else float(sched_yaml.get("poll_spread_sec") or 0)

    jitter_seconds = float(jitter_env) if jitter_env not in (None, "") \
        else float(sched_yaml.get("poll_jitter_sec") or 0)

    # --- run mode toggle ---
    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # --- global caps (OPTIONAL) ---
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # --- ingestion toggles ---
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss     = os.getenv("ENABLE_RSS_INGEST", "true").lower()     not in ("0", "false", "no")

    # --- per-run source limits (OPTIONAL, usually set in YAML) ---
    per_run_yaml = (sched_yaml.get("per_run_limits") or {})
    per_run_limit_yt  = int(per_run_yaml["youtube_channels"]) if "youtube_channels" in per_run_yaml else None
    per_run_limit_rss = int(per_run_yaml["rss_feeds"])        if "rss_feeds"        in per_run_yaml else None

    # --- throttle map (OPTIONAL) ---
    # throttle.per_domain_min_seconds:
    #   default: 5
    #   pinkvilla.com: 20
    # etc.
    throttle: Dict[str, int] = {}
    th = ((S.get("throttle") or {}).get("per_domain_min_seconds") or {}) if isinstance(S, dict) else {}
    for host, secs in (th.items() if isinstance(th, dict) else []):
        try:
            throttle[str(host)] = int(secs)
        except Exception:
            pass

    # --- YouTube channel list ---
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

    # Fallback to env if YAML was empty
    if not yt_specs:
        yt_specs = [YTSpec(ch) for ch in _env_list("YT_CHANNELS")]

    # --- RSS feed list ---
    # We support both a flat "rss" block and multiple logical groups/buckets with their own defaults.
    def _collect_group_feeds(top: Dict[str, Any], block_key: str, default_kind: str) -> List[RSSSpec]:
        out: List[RSSSpec] = []
        block = top.get(block_key)
        if not isinstance(block, dict):
            return out

        # Bucketed form:
        #   rss:
        #     defaults: { kind_hint: "news", max_items_per_poll: 10 }
        #     buckets:
        #       bollywood:
        #         enabled: true
        #         feeds:
        #           - { url: "https://...", kind_hint: "news", enabled: true }
        # scheduler.rss_buckets_enabled controls which buckets are allowed this run.
        if "buckets" in block and isinstance(block.get("buckets"), dict):
            defaults = block.get("defaults") or {}
            def_kind = str(defaults.get("kind_hint") or default_kind or "news")
            def_max  = defaults.get("max_items_per_poll")

            buckets = block.get("buckets") or {}
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

        # Simple form:
        #   rss:
        #     defaults: { kind_hint: "news", max_items_per_poll: 10 }
        #     feeds:
        #       - { url: "...", kind_hint: "release", enabled: true }
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
        # "rss" block:
        rss_specs.extend(_collect_group_feeds(S, "rss", default_kind="news"))

        # Any other top-level keys that look like feed groups:
        for key, val in S.items():
            if key in ("youtube", "scheduler", "throttle", "rss"):
                continue
            if isinstance(val, dict) and ("feeds" in val or "buckets" in val):
                rss_specs.extend(_collect_group_feeds(S, key, default_kind="news"))

    # Fallback to env if YAML was empty
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


# ------------------------------------------------------------------------------
# throttling controller
# ------------------------------------------------------------------------------

class _Throttle:
    """
    Tracks minimum delay per domain so we don't hammer the same site
    too aggressively within a single poll loop.
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

        if last is None:
            self.last[host] = now
            return

        delay = (last + float(min_gap)) - now
        if delay > 0:
            _log(f"Throttle: sleeping {delay:.1f}s before hitting {host}")
            time.sleep(delay)

        self.last[host] = time.monotonic()


# ------------------------------------------------------------------------------
# single polling cycle
# ------------------------------------------------------------------------------

def _poll_once(cfg: Config) -> None:
    """
    Run one poll cycle:
    - For each allowed YouTube channel / RSS feed:
        * apply throttle
        * call youtube_rss_poll(...) / rss_poll(...)
          (those will enqueue normalize_event jobs on "events")
    - Honor per-run limits to avoid hammering too many sources in one cycle.
    - Sleep spread_seconds between polls if configured.

    NOTE:
    We do NOT call sanitizer here.
    We do NOT write to Redis feed here.
    """

    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("All ingestion toggles disabled; nothing to poll.")
        return

    since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours and cfg.published_after_hours > 0
        else None
    )

    yt_list = list(cfg.yt) if cfg.enable_youtube else []
    rss_list = list(cfg.rss) if cfg.enable_rss else []

    # randomize order per cycle for fairness
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # enforce per-run caps, if any
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- poll YouTube channels ---
    for ch in yt_list:
        try:
            throttle.wait_for("youtube.com")

            max_items = ch.max_items if ch.max_items is not None else cfg.yt_global_max_items
            if max_items is None:
                youtube_rss_poll(ch.channel_id, published_after=since)
            else:
                youtube_rss_poll(ch.channel_id, published_after=since, max_items=int(max_items))

        except Exception as e:
            _log(f"ERROR polling YouTube channel={ch.channel_id}: {e!r}")

        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)

    # --- poll RSS feeds ---
    for feed in rss_list:
        try:
            host = _domain_from_url(feed.url)
            throttle.wait_for(host)

            max_items = feed.max_items if feed.max_items is not None else cfg.rss_global_max_items
            if max_items is None:
                rss_poll(feed.url, kind_hint=feed.kind_hint)
            else:
                rss_poll(feed.url, kind_hint=feed.kind_hint, max_items=int(max_items))

        except Exception as e:
            _log(f"ERROR polling RSS url={feed.url}: {e!r}")

        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)


# ------------------------------------------------------------------------------
# main loop
# ------------------------------------------------------------------------------

def main() -> None:
    cfg = _read_config()

    _log(
        "Start: "
        f"{len(cfg.yt)} YT channels, {len(cfg.rss)} RSS feeds; "
        f"every {cfg.poll_every_min}m (spread {cfg.spread_seconds}s, "
        f"jitter ≤ {cfg.jitter_seconds}s, window {cfg.published_after_hours}h)."
    )

    # If nothing is enabled or configured, just idle.
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
