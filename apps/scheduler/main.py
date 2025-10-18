# apps/scheduler/main.py
import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Tuple

# Import from the repo package path
from apps.workers.jobs import youtube_rss_poll, rss_poll


# ----------------------------- helpers ---------------------------------

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


# ----------------------------- config ----------------------------------

@dataclass(frozen=True)
class Config:
    yt_channels: List[str]
    rss_feeds: List[Tuple[str, str]]   # (url, kind_hint)
    poll_every_min: int
    published_after_hours: int
    spread_seconds: float              # delay between individual polls
    jitter_seconds: int                # added randomly to each cycle
    yt_max_items: Optional[int]
    rss_max_items: Optional[int]
    one_shot: bool

def _read_config() -> Config:
    yt = _env_list("YT_CHANNELS")
    rss_specs = _parse_rss_specs(_env_list("RSS_FEEDS"))

    return Config(
        yt_channels=yt,
        rss_feeds=rss_specs,
        poll_every_min=int(os.getenv("POLL_INTERVAL_MIN", "15")),
        published_after_hours=int(os.getenv("PUBLISHED_AFTER_HOURS", "72")),
        spread_seconds=float(os.getenv("POLL_SPREAD_SEC", "2.0")),
        jitter_seconds=int(os.getenv("POLL_JITTER_SEC", "10")),
        yt_max_items=int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None,
        rss_max_items=int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None,
        one_shot=os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes"),
    )


# ------------------------------ main -----------------------------------

def _poll_once(cfg: Config) -> None:
    if not cfg.yt_channels and not cfg.rss_feeds:
        _log("Nothing to poll (both YT_CHANNELS and RSS_FEEDS are empty).")
        return

    # Compute published-after cutoff (optional)
    since: Optional[datetime]
    if cfg.published_after_hours > 0:
        since = _utc_now() - timedelta(hours=cfg.published_after_hours)
    else:
        since = None

    # YouTube channels
    for ch in cfg.yt_channels:
        try:
            if cfg.yt_max_items is None:
                youtube_rss_poll(ch, published_after=since)
            else:
                youtube_rss_poll(ch, published_after=since, max_items=cfg.yt_max_items)
        except Exception as e:  # keep the loop alive
            _log(f"ERROR polling YouTube channel={ch}: {e!r}")
        time.sleep(cfg.spread_seconds)

    # Generic RSS feeds
    for url, kind_hint in cfg.rss_feeds:
        try:
            if cfg.rss_max_items is None:
                rss_poll(url, kind_hint=kind_hint)
            else:
                rss_poll(url, kind_hint=kind_hint, max_items=cfg.rss_max_items)
        except Exception as e:
            _log(f"ERROR polling RSS url={url}: {e!r}")
        time.sleep(cfg.spread_seconds)

def main() -> None:
    cfg = _read_config()

    if not cfg.yt_channels and not cfg.rss_feeds:
        _log("YT_CHANNELS and RSS_FEEDS are empty; sleeping forever.")
        while True:
            time.sleep(300)

    _log(
        f"Starting with {len(cfg.yt_channels)} YT channels, "
        f"{len(cfg.rss_feeds)} RSS feeds; every {cfg.poll_every_min}m "
        f"(spread {cfg.spread_seconds}s, jitter <= {cfg.jitter_seconds}s)."
    )

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
        _log(f"Cycle done in {elapsed:.1f}s; sleeping {sleep_for:.1f}s.")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
