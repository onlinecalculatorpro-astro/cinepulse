# apps/scheduler/main.py
#
# ─────────────────────────────────────────────────────────────────────
# SCHEDULER ROLE (this process = "scheduler" container / cron brain)
# ─────────────────────────────────────────────────────────────────────
#
# FULL PIPELINE (must NEVER be broken):
#
#   1. scheduler
#        - decides WHAT to poll and WHEN
#        - calls:
#              youtube_rss_poll(channel_id=…)
#              rss_poll(url=…)
#          those functions DO NOT publish to the public feed.
#          they just enqueue AdapterEventDict jobs on the "events" RQ queue.
#
#   2. workers  (rq worker "events")
#        - normalize_event()
#              AdapterEventDict → canonical story dict
#              adds:
#                • cleaned headline (generate_safe_title)
#                • neutral summary paragraph (summarize_story_safe)
#                • kind / kind_meta / timestamps
#                • verticals / tags
#                • hero image
#                • safety flags:
#                    - is_risky: legal/PR heat (raids, FIR, leaked chat, etc.)
#                    - gossip_only: relationship / breakup / outrage bait
#                                   with no OTT / release / box office / match-result context
#          then it enqueues sanitize_story() on the "sanitize" queue.
#
#   3. sanitizer  (rq worker "sanitize")
#        - FINAL GATEKEEPER
#            • rejects pure gossip (gossip_only == True)
#            • fuzzy topic dedupe (first unique version wins, later repeats dropped)
#            • LPUSH accepted stories to Redis FEED_KEY (newest first)
#            • LTRIM FEED_KEY (keeps feed bounded)
#            • realtime fanout + optional push
#
#   4. api
#        - /v1/feed reads FEED_KEY
#
# HARD GUARANTEES FOR LEGAL / TRUST:
#   - scheduler MUST NEVER write to FEED_KEY directly.
#   - scheduler MUST NEVER bypass normalize_event() or sanitize_story().
#   - scheduler MUST NEVER try to be clever about dedupe or gossip.
#     That all lives in sanitizer so we keep one source of truth.
#
# WHY THIS MATTERS:
#   The safety promises we make (no raw gossip, no un-attributed accusations,
#   "According to <source>…", no spammy dupes) only hold if every single story
#   flows through:
#       scheduler → workers.normalize_event() → sanitizer.sanitize_story()
#   and NOTHING jumps the line.
#
# ─────────────────────────────────────────────────────────────────────
# CONFIG INPUTS
# ─────────────────────────────────────────────────────────────────────
#
# We load one root YAML file (default /app/infra/source.yml). That file:
#
#   scheduler.poll_interval_min
#   scheduler.published_after_hours        (freshness window for YouTube)
#   scheduler.per_run_limits.youtube_channels / rss_feeds
#   scheduler.rss_buckets_enabled          (optional allowlist of RSS buckets)
#
#   throttle.per_domain_min_seconds:
#       polite crawl pacing per origin ("pinkvilla.com": 240, "default": 180, …)
#
#   include_verticals:
#       - verticals/entertainment.yml
#       - verticals/sports.yml
#       ...
#
# Each vertical YAML contributes:
#
#   youtube:
#     defaults: { max_items_per_poll, ... }
#     channels:
#       - { name: "...", channel_id: "...", enabled: true, ... }
#
#   rss:
#     defaults: { kind_hint: "news", max_items_per_poll: 12, ... }
#     buckets:
#       buzzdesk / boxoffice / ott_streaming / mainstream / sports_results ...
#       with each feed defined as:
#         - name: "...",
#           url: "https://....rss",
#           enabled: true,
#           kind_hint: "news" | "release" | "ott" | etc.
#
# We MERGE all of those vertical YAMLs into one combined config so we get:
#   • one flat list of YouTube channels (enabled only)
#   • one flat list of RSS feeds (enabled only, respecting bucket allowlist)
#   • merged throttle map (max seconds wins per domain = safest / politest)
#
# We also allow fallback env vars in dev:
#   YT_CHANNELS="UCabc...,UCxyz..."
#   RSS_FEEDS="https://site/feed|news,https://other/rss|ott"
#
# In production, YAML is expected to be the source of truth.
#
# ─────────────────────────────────────────────────────────────────────
# RUNTIME LOOP
# ─────────────────────────────────────────────────────────────────────
#
#   while True:
#       - choose which YouTube channels & RSS feeds to poll this cycle
#         (shuffle for fairness, slice by per_run_limit_yt/per_run_limit_rss)
#       - enforce polite throttle per domain
#       - call youtube_rss_poll(...) / rss_poll(...)
#           ↳ those functions enqueue normalize_event() jobs on the "events" queue
#       - sleep until next poll window (+ jitter)
#
#   If ONE_SHOT=1 → run one cycle and exit (useful for testing).
#
# ─────────────────────────────────────────────────────────────────────
# LEGAL / SAFETY REMINDER:
#   The scheduler is ALLOWED to pull spicy / high-buzz sources
#   (ex: Bollywood Hungama box office, Pinkvilla filtered "buzzdesk",
#   Star Sports match result headlines), *but only because* downstream:
#     - summarize_story_safe() strips hype, tones down accusations,
#       and adds attribution like "According to <domain>: …"
#     - generate_safe_title() removes clickbait
#     - sanitizer.sanitize_story() will DROP pure gossip (gossip_only=True)
#       so breakup / leaked chat / "fans slammed" with no work context
#       NEVER reaches users.
#
#   DO NOT EVER short-circuit that.
#

from __future__ import annotations

import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlparse

from apps.workers.jobs import youtube_rss_poll, rss_poll

# YAML is optional in some dev shells; scheduler should still boot.
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore


# -------------------------------------------------------------------
# small helpers / logging
# -------------------------------------------------------------------

def _utc_now() -> datetime:
    """Return timezone-aware UTC now()."""
    return datetime.now(timezone.utc)


def _log(msg: str) -> None:
    """Prefix logs with UTC for easier cross-service debugging."""
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[scheduler] {ts}Z  {msg}")


def _domain_from_url(url: str) -> str:
    """
    Extract host from a URL.
    "https://www.pinkvilla.com/x" -> "pinkvilla.com"
    """
    try:
        netloc = urlparse(url).netloc.lower()
        return netloc[4:] if netloc.startswith("www.") else netloc
    except Exception:
        return ""


def _env_list(name: str) -> List[str]:
    """
    Parse comma/newline-separated env vars into a clean list.
    Lines starting with "#" are ignored.
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
    Turn env-style strings into [(url, kind_hint)].
    Example:
        "https://site.com/feed|news"
        "https://other.com/rss"         (defaults to "news")
    →  [
         ("https://site.com/feed", "news"),
         ("https://other.com/rss", "news"),
       ]
    """
    items: List[Tuple[str, str]] = []
    for s in specs:
        if "|" in s:
            url, hint = s.split("|", 1)
            items.append((url.strip(), (hint or "news").strip()))
        else:
            items.append((s.strip(), "news"))
    return items


# -------------------------------------------------------------------
# dataclasses for runtime config
# -------------------------------------------------------------------

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # per-channel override for max items / poll


@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # per-feed override for max items / poll


@dataclass(frozen=True)
class Config:
    # sources to poll (already merged from all vertical YAMLs)
    yt: List[YTSpec]
    rss: List[RSSSpec]

    # cadence / pacing knobs
    poll_every_min: int            # run a full cycle this often
    published_after_hours: float   # ignore YouTube uploads older than this window
    spread_seconds: float          # pause between individual polls inside a cycle
    jitter_seconds: float          # random pad between cycles
    one_shot: bool                 # run one cycle then exit (for tests)

    # global caps if channel/feed doesn't override its own max_items
    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    # we don't hammer 200 feeds every loop; we slice per run
    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    # polite crawl throttle map: { "pinkvilla.com": 240, "default": 180, ... }
    throttle_per_domain: Dict[str, int]

    # feature toggles
    enable_youtube: bool
    enable_rss: bool


# -------------------------------------------------------------------
# YAML loader / vertical merge
# -------------------------------------------------------------------

def _safe_load_yaml(path: str) -> Dict[str, Any]:
    """
    Read YAML → dict.
    If the file is missing / invalid / yaml lib missing, we return {}.
    Scheduler MUST still boot, even in degraded mode.
    """
    if not yaml:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        if isinstance(data, dict):
            return data
        return {}
    except Exception as e:
        _log(f"warning: could not read {path}: {e!r}")
        return {}


def _merge_verticals(global_cfg: Dict[str, Any], root_path: str) -> Dict[str, Any]:
    """
    Combine root source.yml + each vertical YAML under include_verticals
    into ONE merged config the scheduler can act on.

    Merge rules:
      • throttle.per_domain_min_seconds:
          take the MAX value per domain → safest (slowest) wins.
      • youtube.channels:
          concat all channels where enabled == true.
      • rss.buckets / rss.feeds:
          concat all feeds where enabled == true.
          You can also whitelist bucket names using
          scheduler.rss_buckets_enabled in the root YAML. Anything
          not whitelisted is skipped.
    """
    base_dir = os.path.dirname(root_path)

    include_verticals = global_cfg.get("include_verticals") or []
    if not isinstance(include_verticals, list):
        include_verticals = []

    # accumulators while merging
    yt_defaults: Dict[str, Any] = {}
    yt_channels: List[Dict[str, Any]] = []

    rss_defaults: Dict[str, Any] = {}
    rss_feeds_flat: List[Dict[str, Any]] = []
    rss_buckets: Dict[str, Dict[str, Any]] = {}

    throttle_map: Dict[str, int] = {}

    def _merge_throttle(block: Dict[str, Any]) -> None:
        """Merge throttle.per_domain_min_seconds using 'max wins'."""
        tcfg = block.get("throttle")
        if not isinstance(tcfg, dict):
            return
        pd = tcfg.get("per_domain_min_seconds")
        if not isinstance(pd, dict):
            return
        for host, secs in pd.items():
            try:
                val = int(secs)
            except Exception:
                continue
            prev = throttle_map.get(host)
            if prev is None or val > prev:
                throttle_map[host] = val

    def _merge_block(block: Dict[str, Any]) -> None:
        """
        Pull youtube/rss/throttle from one YAML (root or per-vertical).
        Only keep enabled:true entries.
        """
        nonlocal yt_defaults, yt_channels, rss_defaults, rss_feeds_flat, rss_buckets

        # throttle
        _merge_throttle(block)

        # youtube
        yb = block.get("youtube")
        if isinstance(yb, dict):
            if isinstance(yb.get("defaults"), dict):
                yt_defaults.update(yb["defaults"])
            chs = yb.get("channels") or []
            for ch in chs:
                if not isinstance(ch, dict):
                    continue
                if not ch.get("enabled", True):
                    continue
                yt_channels.append(ch)

        # rss
        rb = block.get("rss")
        if isinstance(rb, dict):
            if isinstance(rb.get("defaults"), dict):
                rss_defaults.update(rb["defaults"])

            # flat feeds mode
            for fd in rb.get("feeds") or []:
                if not isinstance(fd, dict):
                    continue
                if not fd.get("enabled", True):
                    continue
                rss_feeds_flat.append(fd)

            # bucketed mode
            buckets = rb.get("buckets") or {}
            if isinstance(buckets, dict):
                for bname, bucket in buckets.items():
                    if not isinstance(bucket, dict):
                        continue
                    if not bucket.get("enabled", True):
                        continue

                    incoming_feeds: List[Dict[str, Any]] = []
                    for fd in bucket.get("feeds") or []:
                        if not isinstance(fd, dict):
                            continue
                        if not fd.get("enabled", True):
                            continue
                        incoming_feeds.append(fd)

                    if bname not in rss_buckets:
                        rss_buckets[bname] = {
                            "enabled": True,
                            "feeds": list(incoming_feeds),
                        }
                    else:
                        rss_buckets[bname]["enabled"] = (
                            rss_buckets[bname].get("enabled", True) or True
                        )
                        rss_buckets[bname]["feeds"].extend(incoming_feeds)

    # merge root/global first
    _merge_block(global_cfg)

    # merge each vertical file listed under include_verticals
    for rel_path in include_verticals:
        full = os.path.join(base_dir, str(rel_path))
        vert_cfg = _safe_load_yaml(full)
        _merge_block(vert_cfg)

    # final combined dict looks structurally like a single vertical file
    combined: Dict[str, Any] = {
        "scheduler": global_cfg.get("scheduler") or {},
        "throttle": {"per_domain_min_seconds": throttle_map},
        "youtube": {
            "defaults": yt_defaults,
            "channels": yt_channels,
        },
        "rss": {
            "defaults": rss_defaults,
        },
    }

    if rss_feeds_flat:
        combined["rss"]["feeds"] = rss_feeds_flat
    if rss_buckets:
        combined["rss"]["buckets"] = rss_buckets

    return combined


# -------------------------------------------------------------------
# config ingestion
# -------------------------------------------------------------------

def _require_number(val: object | None, name: str) -> float:
    """
    poll_every_min and published_after_hours are mandatory.
    We don't silently invent them in code because cadence is a product/legal knob.
    """
    if val is None or val == "":
        raise RuntimeError(
            f"Missing required setting: {name} "
            "(set it in .env or scheduler.* in your YAML)"
        )
    return float(val)


def _read_config() -> Config:
    """
    Load + normalize runtime config:
      1. read SOURCES_FILE (default /app/infra/source.yml)
      2. merge include_verticals into one combined view
      3. pull scheduler.* knobs
      4. build YTSpec[] and RSSSpec[] lists
      5. attach throttle, limits, toggles
    """
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"

    # root YAML
    root_yaml = _safe_load_yaml(sources_path)

    # merge vertical YAMLs (entertainment, sports, etc.)
    merged_cfg = _merge_verticals(root_yaml, sources_path)

    scheduler_yaml = merged_cfg.get("scheduler") or {}

    # ===== cadence / freshness =====
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

    # ===== pacing (optional) =====
    spread_env = os.getenv("POLL_SPREAD_SEC")
    jitter_env = os.getenv("POLL_JITTER_SEC")

    spread_seconds = float(spread_env) if spread_env not in (None, "") \
        else float(scheduler_yaml.get("poll_spread_sec") or 0)

    jitter_seconds = float(jitter_env) if jitter_env not in (None, "") \
        else float(scheduler_yaml.get("poll_jitter_sec") or 0)

    # ===== mode =====
    one_shot = os.getenv("ONE_SHOT", "").lower() in ("1", "true", "yes")

    # ===== global max_items per poll (optional) =====
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # ===== feature toggles =====
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss     = os.getenv("ENABLE_RSS_INGEST", "true").lower()     not in ("0", "false", "no")

    # ===== per-run caps =====
    per_run_limits_yaml = scheduler_yaml.get("per_run_limits") or {}
    per_run_limit_yt  = int(per_run_limits_yaml["youtube_channels"]) if "youtube_channels" in per_run_limits_yaml else None
    per_run_limit_rss = int(per_run_limits_yaml["rss_feeds"])        if "rss_feeds"        in per_run_limits_yaml else None

    # ===== throttle map =====
    throttle_per_domain: Dict[str, int] = {}
    throttle_root = merged_cfg.get("throttle") or {}
    per_dom = throttle_root.get("per_domain_min_seconds") or {}
    if isinstance(per_dom, dict):
        for host, secs in per_dom.items():
            try:
                throttle_per_domain[str(host)] = int(secs)
            except Exception:
                pass

    # ===== YouTube channels =====
    yt_specs: List[YTSpec] = []
    yt_cfg = merged_cfg.get("youtube") or {}
    if isinstance(yt_cfg, dict):
        yt_def_max = (
            (yt_cfg.get("defaults") or {}).get("max_items_per_poll")
            if isinstance(yt_cfg.get("defaults"), dict)
            else None
        )
        for ch in yt_cfg.get("channels", []):
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

    # DEV FALLBACK:
    # If YAML gave us nothing (like a local env sandbox), allow env-based
    # YT_CHANNELS list just so the pipeline can still run.
    if not yt_specs:
        yt_specs = [YTSpec(cid) for cid in _env_list("YT_CHANNELS")]

    # ===== RSS feeds =====
    #
    # merged_cfg["rss"] may have:
    #   {
    #     "defaults": {...},
    #     "feeds": [...],        # flat mode
    #     "buckets": {...}       # bucketed mode
    #   }
    #
    # We respect scheduler.rss_buckets_enabled (optional allowlist)
    # so product/legal can temporarily disable an entire bucket like
    # "buzzdesk" if it starts drifting into pure-personal gossip.
    #
    def _collect_group_feeds(top: Dict[str, Any]) -> List[RSSSpec]:
        out: List[RSSSpec] = []

        rb = top.get("rss") or {}
        if not isinstance(rb, dict):
            return out

        defaults = rb.get("defaults") or {}
        def_kind = str(defaults.get("kind_hint") or "news")
        def_max  = defaults.get("max_items_per_poll")

        # flat feeds
        for feed in rb.get("feeds", []) or []:
            if not isinstance(feed, dict) or not feed.get("enabled", True):
                continue
            f_url = (feed.get("url") or "").strip()
            if not f_url:
                continue
            kind = str(feed.get("kind_hint") or def_kind or "news")
            mi   = feed.get("max_items_per_poll", def_max)
            out.append(
                RSSSpec(
                    url=f_url,
                    kind_hint=kind,
                    max_items=int(mi) if mi else None,
                )
            )

        # bucketed feeds
        buckets = rb.get("buckets") or {}
        if isinstance(buckets, dict):
            # whitelist if provided
            enabled_list = scheduler_yaml.get("rss_buckets_enabled")
            bucket_allow = set(enabled_list) if enabled_list else set(buckets.keys())

            for bname, bucket in buckets.items():
                if bname not in bucket_allow:
                    continue
                if not isinstance(bucket, dict) or not bucket.get("enabled", True):
                    continue

                for feed in bucket.get("feeds") or []:
                    if not isinstance(feed, dict) or not feed.get("enabled", True):
                        continue
                    f_url = (feed.get("url") or "").strip()
                    if not f_url:
                        continue
                    kind = str(feed.get("kind_hint") or def_kind or "news")
                    mi   = feed.get("max_items_per_poll", def_max)
                    out.append(
                        RSSSpec(
                            url=f_url,
                            kind_hint=kind,
                            max_items=int(mi) if mi else None,
                        )
                    )

        return out

    rss_specs = _collect_group_feeds(merged_cfg)

    # DEV FALLBACK:
    # If YAML had nothing (like local sandbox), allow env RSS_FEEDS so dev
    # can still smoke test the pipeline. In prod we expect YAML to be non-empty.
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


# -------------------------------------------------------------------
# polite throttle gate
# -------------------------------------------------------------------

class _Throttle:
    """
    Per-domain courtesy. We don't hammer anyone.

    Example throttle_per_domain:
        {
            "default": 180,
            "youtube.com": 120,
            "pinkvilla.com": 240,
        }

    Meaning:
        - wait at least 180s between hits to hosts not explicitly listed
        - wait at least 120s between hits to YouTube
        - wait at least 240s between hits to pinkvilla.com
    """
    def __init__(self, per_domain: Dict[str, int]):
        self.rules = per_domain or {}
        self.last_hit: Dict[str, float] = {}

    def wait_for(self, host: str) -> None:
        if not host:
            return

        min_gap = self.rules.get(host) or self.rules.get("default")
        if not min_gap:
            return

        now = time.monotonic()
        last = self.last_hit.get(host)

        # first time -> just record timestamp
        if last is None:
            self.last_hit[host] = now
            return

        delay = (last + float(min_gap)) - now
        if delay > 0:
            _log(f"throttle: sleeping {delay:.1f}s before hitting {host}")
            time.sleep(delay)

        self.last_hit[host] = time.monotonic()


# -------------------------------------------------------------------
# one polling cycle
# -------------------------------------------------------------------

def _poll_once(cfg: Config) -> None:
    """
    Do ONE pass of polling:
      1. shuffle YT + RSS so tail feeds get a turn
      2. slice to per_run_limit_* so we don't crawl every single source each cycle
      3. enforce throttle per domain
      4. call youtube_rss_poll / rss_poll
         NOTE: those functions push jobs to the "events" RQ queue.
               From there, normalize_event() + sanitize_story() handle safety.
               Scheduler NEVER touches FEED_KEY.
    """
    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("all ingestion toggles disabled; skipping poll")
        return

    # Freshness cutoff for YouTube:
    # We'll ignore uploads older than `published_after_hours`.
    cutoff_since: Optional[datetime] = (
        _utc_now() - timedelta(hours=cfg.published_after_hours)
        if cfg.published_after_hours and cfg.published_after_hours > 0
        else None
    )

    yt_list = list(cfg.yt) if cfg.enable_youtube else []
    rss_list = list(cfg.rss) if cfg.enable_rss else []

    # Shuffle so we don't starve sources that happen to sit at the bottom.
    random.shuffle(yt_list)
    random.shuffle(rss_list)

    # Slice per-cycle so we don't hammer 200 feeds every loop.
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- poll YouTube channels --------------------------------------
    for ch in yt_list:
        try:
            throttle.wait_for("youtube.com")

            max_items = ch.max_items if ch.max_items is not None else cfg.yt_global_max_items

            if max_items is None:
                emitted = youtube_rss_poll(
                    ch.channel_id,
                    published_after=cutoff_since,
                )
            else:
                emitted = youtube_rss_poll(
                    ch.channel_id,
                    published_after=cutoff_since,
                    max_items=int(max_items),
                )

            _log(f"yt poll channel={ch.channel_id} -> emitted={emitted}")

        except Exception as e:
            _log(f"ERROR polling YouTube channel={ch.channel_id}: {e!r}")

        # Small delay between polls in the same cycle so bursts feel gentler.
        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)

    # --- poll RSS feeds ---------------------------------------------
    for feed in rss_list:
        try:
            host = _domain_from_url(feed.url)
            throttle.wait_for(host)

            max_items = feed.max_items if feed.max_items is not None else cfg.rss_global_max_items

            if max_items is None:
                emitted = rss_poll(
                    feed.url,
                    kind_hint=feed.kind_hint,
                )
            else:
                emitted = rss_poll(
                    feed.url,
                    kind_hint=feed.kind_hint,
                    max_items=int(max_items),
                )

            _log(f"rss poll url={feed.url} host={host} -> emitted={emitted}")

        except Exception as e:
            _log(f"ERROR polling RSS url={feed.url}: {e!r}")

        if cfg.spread_seconds and cfg.spread_seconds > 0:
            time.sleep(cfg.spread_seconds)


# -------------------------------------------------------------------
# main loop
# -------------------------------------------------------------------

def main() -> None:
    cfg = _read_config()

    _log(
        "boot: "
        f"{len(cfg.yt)} yt_channels, {len(cfg.rss)} rss_feeds | "
        f"interval={cfg.poll_every_min}m "
        f"fresh_window={cfg.published_after_hours}h "
        f"spread={cfg.spread_seconds}s "
        f"jitter≤{cfg.jitter_seconds}s "
        f"one_shot={cfg.one_shot}"
    )

    # If config is basically empty, we idle instead of spinning hot.
    if (not cfg.enable_youtube and not cfg.enable_rss) or (not cfg.yt and not cfg.rss):
        _log("no enabled sources; going into idle sleep loop")
        while True:
            time.sleep(300)

    while True:
        cycle_start = time.monotonic()

        _poll_once(cfg)

        if cfg.one_shot:
            _log("ONE_SHOT=1 → completed single poll pass, exiting.")
            return

        elapsed = time.monotonic() - cycle_start

        # Aim for poll_every_min (+ jitter). We don't try to 'catch up' if slow;
        # we're fine being slightly slower rather than hammering sources.
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
