# apps/scheduler/main.py
import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Tuple, Dict
from urllib.parse import urlparse

# Import polling functions implemented in workers
from apps.workers.jobs import youtube_rss_poll, rss_poll

# Optional YAML (for infra/source.yml). Falls back to env-only if missing.
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
    """
    Split env var by comma OR newline; ignore empty segments and comments (#...).
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
    Accept items like:
      - "https://example.com/feed"            -> kind_hint="news"
      - "https://site/rss.xml|ott"            -> kind_hint="ott"
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


# ----------------------------- config shapes ---------------------------------

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
    published_after_hours: int
    spread_seconds: float
    jitter_seconds: int
    one_shot: bool

    # Optional global caps
    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    # Per-run caps when using many sources
    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    # Throttle per-domain (seconds between hits)
    throttle_per_domain: Dict[str, int]


# ----------------------------- config loader ---------------------------------

def _read_config() -> Config:
    # Defaults (env can override)
    poll_every_min = int(os.getenv("POLL_INTERVAL_MIN", "15"))
    published_after_hours = int(os.getenv("PUBLISHED_AFTER_HOURS", "72"))
    spread_seconds = float(os.getenv("POLL_SPREAD_SEC", "1.5"))
    jitter_seconds = int(os.getenv("POLL_JITTER_SEC", "8"))
    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # Global caps
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # Fallback lists from env
    yt_specs: List[YTSpec] = [YTSpec(ch) for ch in _env_list("YT_CHANNELS")]
    rss_specs: List[RSSSpec] = [
        RSSSpec(url=u, kind_hint=k) for (u, k) in _parse_rss_specs(_env_list("RSS_FEEDS"))
    ]

    per_run_limit_yt: Optional[int] = None
    per_run_limit_rss: Optional[int] = None
    throttle_per_domain: Dict[str, int] = {}

    # Optional YAML sources file
    use_sources_file = os.getenv("USE_SOURCES_FILE", "").lower() in ("1", "true", "yes")
    sources_path = os.getenv("SOURCES_FILE") or "infra/source.yml"

    if use_sources_file and yaml and os.path.exists(sources_path):
        try:
            with open(sources_path, "r", encoding="utf-8") as f:
                S = yaml.safe_load(f) or {}

            # Scheduler defaults from YAML (env still wins)
            sched = (S.get("scheduler") or {})
            poll_every_min = int(os.getenv("POLL_INTERVAL_MIN", str(sched.get("poll_interval_min", poll_every_min))))
            published_after_hours = int(os.getenv("PUBLISHED_AFTER_HOURS", str(sched.get("published_after_hours", published_after_hours))))
            per_run = (sched.get("per_run_limits") or {})
            per_run_limit_yt = per_run.get("youtube_channels")
            per_run_limit_rss = per_run.get("rss_feeds")

            # Throttle map
            throttle = (S.get("throttle") or {}).get("per_domain_min_seconds") or {}
            for host, secs in throttle.items():
                try:
                    throttle_per_domain[host] = int(secs)
                except Exception:
                    pass

            # YouTube channels
            yt_cfg = S.get("youtube") or {}
            yt_def_max = (yt_cfg.get("defaults") or {}).get("max_items_per_poll")
            channels = (yt_cfg.get("channels") or [])
            file_yt: List[YTSpec] = []
            for ch in channels:
                if not ch.get("enabled", True):
                    continue
                cid = ch.get("channel_id")
                if not cid:
                    continue
                mi = ch.get("max_items_per_poll", yt_def_max)
                file_yt.append(YTSpec(channel_id=cid, max_items=int(mi) if mi else None))
            if file_yt:
                yt_specs = file_yt  # prefer file over env

            # RSS buckets
            rss_cfg = S.get("rss") or {}
            rss_def = (rss_cfg.get("defaults") or {})
            rss_def_max = rss_def.get("max_items_per_poll")
            buckets = (rss_cfg.get("buckets") or {})

            # If YAML lists explicit enabled buckets, honor that; else take all enabled
            enabled_bucket_names = set((sched.get("rss_buckets_enabled") or buckets.keys()))
            file_rss: List[RSSSpec] = []
            for bname, bucket in buckets.items():
                if not bucket.get("enabled", True):
                    continue
                if bname not in enabled_bucket_names:
                    continue
                for feed in bucket.get("feeds", []):
                    if not feed.get("enabled", True):
                        continue
                    url = feed.get("url")
                    if not url:
                        continue
                    kind = feed.get("kind_hint") or rss_def.get("kind_hint", "news")
                    mi = feed.get("max_items_per_poll", rss_def_max)
                    file_rss.append(RSSSpec(url=url, kind_hint=kind, max_items=int(mi) if mi else None))
            if file_rss:
                rss_specs = file_rss  # prefer file over env

        except Exception as e:
            _log(f"Unable to read sources file '{sources_path}': {e!r} (falling back to env)")

    return Config(
        yt=yt_specs,
        rss=rss_specs,
        poll_every_min=poll_every_min,
        published_after_hours=published_after_hours,
        spread_seconds=spread_seconds,
        jitter_seconds=jitter_seconds,
        one_shot=one_shot,
        yt_global_max_items=yt_global_max_items,
        rss_global_max_items=rss_global_max_items,
        per_run_limit_yt=per_run_limit_yt,
        per_run_limit_rss=per_run_limit_rss,
        throttle_per_domain=throttle_per_domain,
    )


# ----------------------------- throttling ------------------------------------

class _Throttle:
    def __init__(self, per_domain: Dict[str, int]):
        # host -> min seconds between hits
        self.rules = per_domain or {}
        # host -> last-hit timestamp (monotonic)
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


# ----------------------------- core polling ----------------------------------

def _poll_once(cfg: Config) -> None:
    if not cfg.yt and not cfg.rss:
        _log("Nothing to poll (no YouTube channels and no RSS feeds).")
        return

    since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours > 0 else None
    )

    # Fairness: randomize order each cycle
    yt_list = list(cfg.yt)
    rss_list = list(cfg.rss)
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # Per-run caps (avoid floods when enabling many feeds)
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- YouTube channels (domain throttle: youtube.com) ---
    for ch in yt_list:
        try:
            throttle.wait_for("youtube.com")
            max_items = ch.max_items if ch.max_items is not None else cfg.yt_global_max_items
            if max_items is None:
                youtube_rss_poll(ch.channel_id, published_after=since)
            else:
                youtube_rss_poll(ch.channel_id, published_after=since, max_items=int(max_items))
        except Exception as e:  # keep loop alive
            _log(f"ERROR polling YouTube channel={ch.channel_id}: {e!r}")
        time.sleep(max(0.0, cfg.spread_seconds))

    # --- Generic RSS feeds (domain-based throttle) ---
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
        time.sleep(max(0.0, cfg.spread_seconds))


# --------------------------------- main --------------------------------------

def main() -> None:
    cfg = _read_config()

    _log(
        f"Start: {len(cfg.yt)} YT channels, {len(cfg.rss)} RSS feeds; "
        f"every {cfg.poll_every_min}m (spread {cfg.spread_seconds}s, "
        f"jitter ≤ {cfg.jitter_seconds}s, window {cfg.published_after_hours}h)."
    )

    if not cfg.yt and not cfg.rss:
        _log("Empty config; sleeping forever.")
        while True:
            time.sleep(300)

    while True:
        started = time.monotonic()
        _poll_once(cfg)

        if cfg.one_shot:
            _log("ONE_SHOT=1: exiting after a single cycle.")
            return

        elapsed = time.monotonic() - started
        base_sleep = cfg.poll_every_min * 60
        jitter = random.uniform(0, max(0, cfg.jitter_seconds))
        sleep_for = max(1.0, base_sleep + jitter - elapsed)
        _log(f"Cycle took {elapsed:.1f}s; sleeping {sleep_for:.1f}s.")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
