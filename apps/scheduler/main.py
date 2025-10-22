# apps/scheduler/main.py
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


# ----------------------------- small utils ----------------------------------

def _utc_now() -> datetime:
    return datetime.now(timezone.utc)

def _log(msg: str) -> None:
    print(f"[scheduler] {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')}Z  {msg}")

def _env_list(name: str) -> List[str]:
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


# ----------------------------- config shapes --------------------------------

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # per-channel override

@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # per-feed override

@dataclass(frozen=True)
class Config:
    yt: List[YTSpec]
    rss: List[RSSSpec]

    poll_every_min: int
    published_after_hours: float
    spread_seconds: float
    jitter_seconds: float
    one_shot: bool

    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    throttle_per_domain: Dict[str, int]

    enable_youtube: bool
    enable_rss: bool


# ----------------------------- config loader --------------------------------

def _require_number(val: Optional[str] | Optional[float] | Optional[int], name: str) -> float:
    if val is None or val == "":
        raise RuntimeError(f"Missing required setting: {name} (set it in .env or in scheduler.* of your sources file)")
    return float(val)

def _read_config() -> Config:
    """
    Load from:
      1) Environment variables (.env via compose)
      2) Sources YAML (infra/source.yml) — if present, honors scheduler.* values there
      3) No hardcoded numeric defaults in code; required values must come from (1) or (2)
    """
    # Discover sources file (compose sets SOURCES_FILE to /app/infra/source.yml)
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"
    S: Dict[str, Any] = {}
    if yaml and os.path.exists(sources_path):
        try:
            with open(sources_path, "r", encoding="utf-8") as f:
                S = yaml.safe_load(f) or {}
        except Exception as e:
            _log(f"Warning: unable to read sources file '{sources_path}': {e!r}")

    sched_yaml = (S.get("scheduler") or {}) if isinstance(S, dict) else {}

    # Core cadence/window (REQUIRED; no hardcoded numbers)
    poll_every_min = int(_require_number(os.getenv("POLL_INTERVAL_MIN", sched_yaml.get("poll_interval_min")), "POLL_INTERVAL_MIN / scheduler.poll_interval_min"))
    published_after_hours = _require_number(os.getenv("PUBLISHED_AFTER_HOURS", sched_yaml.get("published_after_hours")), "PUBLISHED_AFTER_HOURS / scheduler.published_after_hours")

    # Spread/jitter (optional; default to 0 if missing to avoid hardcoding)
    spread_env = os.getenv("POLL_SPREAD_SEC")
    jitter_env = os.getenv("POLL_JITTER_SEC")
    spread_seconds = float(spread_env) if spread_env not in (None, "") else float(sched_yaml.get("poll_spread_sec") or 0)
    jitter_seconds = float(jitter_env) if jitter_env not in (None, "") else float(sched_yaml.get("poll_jitter_sec") or 0)

    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # Global caps (optional)
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # Enable toggles (default True if not set)
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss = os.getenv("ENABLE_RSS_INGEST", "true").lower() not in ("0", "false", "no")

    # Per-run limits (optional; usually in YAML)
    per_run_yaml = (sched_yaml.get("per_run_limits") or {})
    per_run_limit_yt = int(per_run_yaml["youtube_channels"]) if "youtube_channels" in per_run_yaml else None
    per_run_limit_rss = int(per_run_yaml["rss_feeds"]) if "rss_feeds" in per_run_yaml else None

    # Throttle map (optional)
    throttle: Dict[str, int] = {}
    th = ((S.get("throttle") or {}).get("per_domain_min_seconds") or {}) if isinstance(S, dict) else {}
    for host, secs in (th.items() if isinstance(th, dict) else []):
        try:
            throttle[str(host)] = int(secs)
        except Exception:
            pass

    # YouTube channels
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
        yt_specs.append(YTSpec(channel_id=str(cid), max_items=int(mi) if mi else None))

    # Fallback to env if file had none
    if not yt_specs:
        yt_specs = [YTSpec(ch) for ch in _env_list("YT_CHANNELS")]

    # RSS feeds (support both simple and bucketed under rss/defaults/buckets)
    def _collect_group_feeds(top: Dict[str, Any], block_key: str, default_kind: str) -> List[RSSSpec]:
        out: List[RSSSpec] = []
        block = top.get(block_key)
        if not isinstance(block, dict):
            return out

        # bucketed form
        if "buckets" in block and isinstance(block.get("buckets"), dict):
            defaults = block.get("defaults") or {}
            def_kind = str(defaults.get("kind_hint") or default_kind or "news")
            def_max = defaults.get("max_items_per_poll")
            buckets = block.get("buckets") or {}
            # scheduler.rss_buckets_enabled (string list) if present
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
                    mi = feed.get("max_items_per_poll", def_max)
                    out.append(RSSSpec(url=url, kind_hint=kind, max_items=int(mi) if mi else None))
            return out

        # simple form
        defaults = block.get("defaults") or {}
        def_kind = str(defaults.get("kind_hint") or default_kind or "news")
        def_max = defaults.get("max_items_per_poll")
        for feed in (block.get("feeds") or []):
            if not isinstance(feed, dict) or not feed.get("enabled", True):
                continue
            url = (feed.get("url") or "").strip()
            if not url:
                continue
            kind = str(feed.get("kind_hint") or def_kind or "news")
            mi = feed.get("max_items_per_poll", def_max)
            out.append(RSSSpec(url=url, kind_hint=kind, max_items=int(mi) if mi else None))
        return out

    rss_specs: List[RSSSpec] = []
    if isinstance(S, dict):
        # legacy/combined rss block
        rss_specs.extend(_collect_group_feeds(S, "rss", default_kind="news"))
        # explicit named groups (if you added more groups, they’ll still be caught by the generic loop below)
        for key, val in S.items():
            if key in ("youtube", "scheduler", "throttle", "rss"):
                continue
            if isinstance(val, dict) and ("feeds" in val or "buckets" in val):
                rss_specs.extend(_collect_group_feeds(S, key, default_kind="news"))

    # Fallback to env if file had none
    if not rss_specs:
        rss_specs = [RSSSpec(url=u, kind_hint=k) for (u, k) in _parse_rss_specs(_env_list("RSS_FEEDS"))]

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


# ----------------------------- throttling -----------------------------------

class _Throttle:
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


# ----------------------------- core polling ---------------------------------

def _poll_once(cfg: Config) -> None:
    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("All ingestion toggles disabled; nothing to poll.")
        return

    since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours and cfg.published_after_hours > 0 else None
    )

    yt_list = list(cfg.yt) if cfg.enable_youtube else []
    rss_list = list(cfg.rss) if cfg.enable_rss else []

    # fair order each cycle
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # per-run caps
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # YouTube
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

    # RSS
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


# --------------------------------- main -------------------------------------

def main() -> None:
    cfg = _read_config()

    _log(
        "Start: "
        f"{len(cfg.yt)} YT channels, {len(cfg.rss)} RSS feeds; "
        f"every {cfg.poll_every_min}m (spread {cfg.spread_seconds}s, "
        f"jitter ≤ {cfg.jitter_seconds}s, window {cfg.published_after_hours}h)."
    )

    if (not cfg.enable_youtube and not cfg.enable_rss) or (not cfg.yt and not cfg.rss):
        _log("Empty or disabled config; sleeping.")
        while True:
            time.sleep(300)  # harmless idle; env-driven cadence not applicable

    while True:
        started = time.monotonic()
        _poll_once(cfg)

        if cfg.one_shot:
            _log("ONE_SHOT=1: exiting after a single cycle.")
            return

        elapsed = time.monotonic() - started
        base_sleep = float(cfg.poll_every_min) * 60.0
        jitter = random.uniform(0.0, float(cfg.jitter_seconds) if cfg.jitter_seconds else 0.0)
        sleep_for = (base_sleep + jitter) - elapsed
        if sleep_for < 0:
            sleep_for = 0.0
        _log(f"Cycle took {elapsed:.1f}s; sleeping {sleep_for:.1f}s.")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
