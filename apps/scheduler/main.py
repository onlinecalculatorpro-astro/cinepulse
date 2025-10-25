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
# CONFIG SOURCES
# - env vars (.env from docker compose)
# - /app/infra/source.yml  (mounted in the image)
#      ├─ global knobs:
#      │    scheduler: {...}, throttle: {...}, etc.
#      │    include_verticals:
#      │      - verticals/entertainment.yml
#      │      - verticals/sports.yml
#      │      ...
#      └─ each vertical YAML defines:
#           youtube:
#             defaults: {...}
#             channels: [...]
#           rss:
#             defaults: {...}
#             buckets: { bucketA: {enabled: true, feeds:[...]}, ... }
#
# The scheduler now MERGES all vertical YAMLs into one combined view:
#   - all youtube.channels become one big list
#   - all rss buckets/feeds become one big list/map
#   - throttle.per_domain_min_seconds gets merged (max seconds wins per host)
#
# REQUIRED RUNTIME KNOBS (must be set either via env or YAML scheduler.*):
#   POLL_INTERVAL_MIN          → how often to run a full poll cycle
#   PUBLISHED_AFTER_HOURS      → ignore items older than this window
#
# LOOP:
#   while True:
#       pick which YT channels / RSS feeds to poll this cycle (respect per_run limits)
#       throttle so we don't hammer the same origin
#       call youtube_rss_poll(...) / rss_poll(...)
#       sleep until next cycle (+ jitter)
#
# If ONE_SHOT=1, do one cycle then exit.

from __future__ import annotations

import os
import time
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlparse

from apps.workers.jobs import youtube_rss_poll, rss_poll

# YAML is allowed to fail gracefully (container should still boot)
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore


# -------------------------------------------------------------------
# basic helpers / logging
# -------------------------------------------------------------------

def _utc_now() -> datetime:
    """Return timezone-aware UTC now()."""
    return datetime.now(timezone.utc)


def _log(msg: str) -> None:
    """UTC timestamp prefix so logs from scheduler/workers/sanitizer correlate."""
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[scheduler] {ts}Z  {msg}")


def _domain_from_url(url: str) -> str:
    """
    Extract host from URL (e.g. https://www.pinkvilla.com/x -> pinkvilla.com).
    Used for per-domain throttling.
    """
    try:
        netloc = urlparse(url).netloc.lower()
        return netloc[4:] if netloc.startswith("www.") else netloc
    except Exception:
        return ""


def _env_list(name: str) -> List[str]:
    """
    Parse comma/newline-separated env vars, ignore blanks / lines starting '#'.
    Returns cleaned list of strings.
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
    Convert:
        "https://site.com/feed|news"
        "https://other.com/rss"
    into:
        [("https://site.com/feed", "news"),
         ("https://other.com/rss", "news")]
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
# config dataclasses
# -------------------------------------------------------------------

@dataclass(frozen=True)
class YTSpec:
    channel_id: str
    max_items: Optional[int] = None  # per-channel override for max items/poll


@dataclass(frozen=True)
class RSSSpec:
    url: str
    kind_hint: str = "news"
    max_items: Optional[int] = None  # per-feed override for max items/poll


@dataclass(frozen=True)
class Config:
    # which sources to poll
    yt: List[YTSpec]
    rss: List[RSSSpec]

    # cadence / pacing
    poll_every_min: int            # required: run a full cycle this often
    published_after_hours: float   # required: skip content older than this
    spread_seconds: float          # optional: pause between individual polls
    jitter_seconds: float          # optional: random pad between cycles
    one_shot: bool                 # run one cycle then exit

    # global caps applied if a channel/feed doesn't override max_items
    yt_global_max_items: Optional[int]
    rss_global_max_items: Optional[int]

    # per-cycle limits (avoid hammering 200+ feeds every loop)
    per_run_limit_yt: Optional[int]
    per_run_limit_rss: Optional[int]

    # throttle map: {domain -> min_seconds_between_hits}
    throttle_per_domain: Dict[str, int]

    # feature toggles
    enable_youtube: bool
    enable_rss: bool


# -------------------------------------------------------------------
# YAML loader / vertical merge
# -------------------------------------------------------------------

def _safe_load_yaml(path: str) -> Dict[str, Any]:
    """
    Read YAML file → dict. Return {} if missing / unreadable / invalid.
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
    Take the root /app/infra/source.yml (global_cfg), read each file listed in
    include_verticals:, and merge them into one combined structure.

    We produce something that *looks like* the old single-file layout, so the
    rest of the scheduler code doesn't have to change:

        {
          "scheduler": {...},
          "throttle": {"per_domain_min_seconds": {...}},
          "youtube": {
            "defaults": {...},
            "channels": [ {channel_id, enabled, ...}, ... ]
          },
          "rss": {
            "defaults": {...},
            "feeds":    [ ... ],           # optional flat list
            "buckets":  { name: {enabled, feeds:[...]}, ... }
          }
        }

    merge rules:
      - youtube.channels from all verticals are concatenated if enabled:true
      - rss.buckets.<bucket>.feeds are concatenated (enabled feeds only)
      - throttle.per_domain_min_seconds picks the *max* delay we've seen
        for a given host, which is safest/politest.
    """
    base_dir = os.path.dirname(root_path)

    # read list of vertical yamls
    include_verticals = global_cfg.get("include_verticals") or []
    if not isinstance(include_verticals, list):
        include_verticals = []

    # accumulators
    yt_defaults: Dict[str, Any] = {}
    yt_channels: List[Dict[str, Any]] = []

    rss_defaults: Dict[str, Any] = {}
    rss_feeds_flat: List[Dict[str, Any]] = []
    rss_buckets: Dict[str, Dict[str, Any]] = {}

    throttle_map: Dict[str, int] = {}

    def _merge_throttle(block: Dict[str, Any]) -> None:
        """merge throttle.per_domain_min_seconds with 'max wins'."""
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
        """pull youtube/rss/throttle from one YAML (either root or a vertical)."""
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
            feeds_list = rb.get("feeds") or []
            for fd in feeds_list:
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
                        # merge feeds
                        rss_buckets[bname]["enabled"] = (
                            rss_buckets[bname].get("enabled", True) or True
                        )
                        rss_buckets[bname]["feeds"].extend(incoming_feeds)

    # merge root/global first
    _merge_block(global_cfg)

    # then merge each vertical file
    for rel_path in include_verticals:
        full = os.path.join(base_dir, str(rel_path))
        vert_cfg = _safe_load_yaml(full)
        _merge_block(vert_cfg)

    # build final combined dict
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
# config loader
# -------------------------------------------------------------------

def _require_number(val: object | None, name: str) -> float:
    """
    Enforce that poll cadence knobs are explicitly configured.
    We DO NOT silently invent these in code.
    """
    if val is None or val == "":
        raise RuntimeError(
            f"Missing required setting: {name} "
            "(set it in .env or scheduler.* in your YAML)"
        )
    return float(val)


def _read_config() -> Config:
    """
    1. load /app/infra/source.yml (or SOURCES_FILE env)
    2. merge in all vertical YAMLs listed under include_verticals
    3. read env overrides for timing / feature flags
    4. return a Config the rest of the scheduler can use
    """
    sources_path = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"

    # read the root YAML
    root_yaml = _safe_load_yaml(sources_path)

    # merge vertical YAMLs (entertainment, sports, etc.) into one dict
    merged_cfg = _merge_verticals(root_yaml, sources_path)

    # this is what downstream logic expects:
    #   merged_cfg["scheduler"], merged_cfg["throttle"],
    #   merged_cfg["youtube"],   merged_cfg["rss"]

    scheduler_yaml = merged_cfg.get("scheduler") or {}

    # ---- cadence / windows (required) ---------------------------------
    poll_every_min = int(
        _require_number(
            os.getenv("POLL_INTERVAL_MIN", scheduler_yaml.get("poll_interval_min")),
            "POLL_INTERVAL_MIN / scheduler.poll_interval_min",
        )
    )

    published_after_hours = _require_number(
        os.getenv(
            "PUBLISHED_AFTER_HOURS",
            scheduler_yaml.get("published_after_hours"),
        ),
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

    # ---- global max_items per poll call (optional) -------------------
    yt_global_max_items = int(os.getenv("YT_MAX_ITEMS")) if os.getenv("YT_MAX_ITEMS") else None
    rss_global_max_items = int(os.getenv("RSS_MAX_ITEMS")) if os.getenv("RSS_MAX_ITEMS") else None

    # ---- feature toggles ---------------------------------------------
    enable_youtube = os.getenv("ENABLE_YOUTUBE_INGEST", "true").lower() not in ("0", "false", "no")
    enable_rss     = os.getenv("ENABLE_RSS_INGEST", "true").lower()     not in ("0", "false", "no")

    # ---- per-run limits ----------------------------------------------
    per_run_limits_yaml = scheduler_yaml.get("per_run_limits") or {}
    per_run_limit_yt  = int(per_run_limits_yaml["youtube_channels"]) if "youtube_channels" in per_run_limits_yaml else None
    per_run_limit_rss = int(per_run_limits_yaml["rss_feeds"])        if "rss_feeds"        in per_run_limits_yaml else None

    # ---- throttle map ------------------------------------------------
    throttle_per_domain: Dict[str, int] = {}
    throttle_root = merged_cfg.get("throttle") or {}
    per_dom = throttle_root.get("per_domain_min_seconds") or {}
    if isinstance(per_dom, dict):
        for host, secs in per_dom.items():
            try:
                throttle_per_domain[str(host)] = int(secs)
            except Exception:
                pass

    # ---- YouTube channels --------------------------------------------
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

    # Fallback to env if absolutely nothing made it in
    if not yt_specs:
        yt_specs = [YTSpec(cid) for cid in _env_list("YT_CHANNELS")]

    # ---- RSS feeds ---------------------------------------------------
    #
    # merged_cfg["rss"] can be:
    #   {
    #     "defaults": {...},
    #     "feeds": [...],          # flat
    #     "buckets": { ... }       # bucketed
    #   }
    #
    # We also respect scheduler_yaml["rss_buckets_enabled"] if present,
    # which is a whitelist of bucket names to actually poll.
    #
    def _collect_group_feeds(top: Dict[str, Any]) -> List[RSSSpec]:
        out: List[RSSSpec] = []

        rb = top.get("rss") or {}
        if not isinstance(rb, dict):
            return out

        defaults = rb.get("defaults") or {}
        def_kind = str(defaults.get("kind_hint") or "news")
        def_max  = defaults.get("max_items_per_poll")

        # flat feeds (if any)
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
            # whitelist (scheduler.rss_buckets_enabled) if provided
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

    # fallback to env if YAML ended up empty
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
# throttling (per-domain courtesy)
# -------------------------------------------------------------------

class _Throttle:
    """
    Throttle calls to the same host so we don't blast someone's origin.

    Example throttle map:
        { "default": 5, "pinkvilla.com": 20 }
    means:
        - wait at least 5s before hitting any unknown domain
        - wait at least 20s between hits to pinkvilla.com
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

        # first time -> just record time
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
    Execute one poll pass:
      - shuffle sources so we don't always starve the tail
      - obey per_run_limit_*
      - throttle per domain
      - call youtube_rss_poll(...) / rss_poll(...)

    NOTE:
    We ONLY enqueue work into RQ ("events"). We do not write feed or dedupe.
    Sanitizer downstream is the single source of truth for publishing.
    """
    if not cfg.enable_youtube and not cfg.enable_rss:
        _log("all ingestion toggles disabled; skipping poll")
        return

    # freshness cutoff for YouTube videos (ignore old uploads)
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

    # optional per-cycle caps
    if cfg.per_run_limit_yt is not None:
        yt_list = yt_list[: max(0, int(cfg.per_run_limit_yt))]
    if cfg.per_run_limit_rss is not None:
        rss_list = rss_list[: max(0, int(cfg.per_run_limit_rss))]

    throttle = _Throttle(cfg.throttle_per_domain)

    # --- YouTube channels -------------------------------------------
    for ch in yt_list:
        try:
            throttle.wait_for("youtube.com")

            # pick max_items override
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

        # spread out bursts in a single cycle
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


# -------------------------------------------------------------------
# main loop
# -------------------------------------------------------------------

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

    # If config is effectively empty, just idle instead of spinning hot.
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

        # target: start each cycle roughly every poll_every_min (+ jitter)
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
