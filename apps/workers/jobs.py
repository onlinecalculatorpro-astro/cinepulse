# apps/workers/jobs.py
from __future__ import annotations

import hashlib
import json
import os
import re
import time as _time
from datetime import datetime, timezone, timedelta
from typing import Optional, Union, TypedDict, Tuple
from urllib.parse import urlparse

import feedparser
from redis import Redis
from rq import Queue

__all__ = ["youtube_rss_poll", "rss_poll", "normalize_event"]

# ============================ Redis / keys ============================

def _redis() -> Redis:
    # redis://host:port/db
    return Redis.from_url(
        os.getenv("REDIS_URL", "redis://redis:6379/0"),
        decode_responses=True,
    )

# Single source of truth for the app feed LIST key.
# Keep default aligned with your API/health endpoint.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")   # LIST, newest-first
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen")    # SET of story ids for dedupe

# Max number of items to retain in the feed LIST (trimmed on each insert).
FEED_MAX = int(os.getenv("FEED_MAX", "1200"))

# Per-poller defaults (overridable by env)
YT_MAX_ITEMS = int(os.getenv("YT_MAX_ITEMS", "50"))
RSS_MAX_ITEMS = int(os.getenv("RSS_MAX_ITEMS", "30"))

# =============================== Types ===============================

class AdapterEventDict(TypedDict, total=False):
    source: str                  # "youtube" | "rss:<domain>"
    source_event_id: str         # unique per source (videoId | link hash)
    title: str
    kind: str                    # trailer | ott | news | release
    published_at: Optional[str]  # RFC3339
    thumb_url: Optional[str]
    payload: dict

# =============================== Utils ===============================

# Core cues
TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)

# OTT: keep broad list; we just need detection for classification
_OTT_PROVIDERS = [
    "Netflix", "Prime Video", "Amazon Prime Video", "Disney\\+ Hotstar", "Hotstar",
    "JioCinema", "ZEE5", "Zee5", "SonyLIV", "Sony LIV", "Hulu", "Max",
    "HBO Max", "Apple TV\\+", "Apple TV"
]
OTT_RE = re.compile(
    rf"(?:on|premieres on|streams on|streaming on|now on)\s+({'|'.join(_OTT_PROVIDERS)})",
    re.I
)

# Theatrical cues
THEATRE_RE = re.compile(
    r"\b(in\s+(?:theatres|theaters|cinemas?)|theatrical(?:\s+release)?)\b",
    re.I
)

# Release/coming cues
RELEASE_VERBS_RE = re.compile(
    r"\b(release[sd]?|releasing|releases|to\s+release|set\s+to\s+release|slated\s+to\s+release|opens?|opening|hits?)\b",
    re.I
)
COMING_SOON_RE = re.compile(r"\bcoming\s+soon\b", re.I)

# Months map
_MONTHS = {
    "jan": 1, "january": 1,
    "feb": 2, "february": 2,
    "mar": 3, "march": 3,
    "apr": 4, "april": 4,
    "may": 5,
    "jun": 6, "june": 6,
    "jul": 7, "july": 7,
    "aug": 8, "august": 8,
    "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10,
    "nov": 11, "november": 11,
    "dec": 12, "december": 12,
}

# Date patterns:
#  - 12 Nov 2025 / 12 November 2025 / 12 Nov
#  - Nov 12, 2025 / November 12
#  - March 2026
_MN = r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
DAY_MON_YR = re.compile(rf"\b(\d{{1,2}})\s+({_MN})\s*(\d{{2,4}})?\b", re.I)
MON_DAY_YR = re.compile(rf"\b({_MN})\s+(\d{{1,2}})(?:,\s*(\d{{2,4}}))?\b", re.I)
MON_YR     = re.compile(rf"\b({_MN})\s+(\d{{4}})\b", re.I)

def _to_rfc3339(value: Optional[Union[str, datetime, _time.struct_time]]) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, _time.struct_time):
        dt = datetime.fromtimestamp(_time.mktime(value), tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    v = str(value).strip()
    return v if v else None

def _extract_video_id(entry: dict) -> Optional[str]:
    vid = entry.get("yt_videoid") or entry.get("yt:videoid")
    if vid:
        return vid
    link = (entry.get("link") or "") + " "
    if "watch?v=" in link:
        return link.split("watch?v=", 1)[1].split("&", 1)[0]
    return None

def _link_thumb(entry: dict) -> Optional[str]:
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list) and thumbs:
        url = thumbs[0].get("url") if isinstance(thumbs[0], dict) else None
        if url:
            return url
    for l in entry.get("links") or []:
        if isinstance(l, dict) and l.get("rel") == "enclosure" and l.get("type", "").startswith("image/"):
            return l.get("href")
    for k in ("image", "picture", "logo"):
        v = entry.get(k)
        if isinstance(v, str) and v.startswith("http"):
            return v
        if isinstance(v, dict) and v.get("href"):
            return v["href"]
    return None

def _safe_job_id(prefix: str, *parts: str) -> str:
    def clean(s: str) -> str:
        return re.sub(r"[^A-Za-z0-9_\-]+", "-", s).strip("-")
    jid = "-".join([clean(prefix), *(clean(p) for p in parts if p)])
    return (jid or clean(prefix))[:200]

def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"

def _hash_link(link: str) -> str:
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()

def _nearest_future(year: int, month: int, day: int | None) -> datetime:
    now = datetime.now(timezone.utc)
    if day is None:
        d = 1
    else:
        d = max(1, min(28, day))  # keep safe
    # If year is 2-digit, expand (>=70 -> 1900s else 2000s)
    if year < 100:
        year = 1900 + year if year >= 70 else 2000 + year
    candidate = datetime(year, month, d, tzinfo=timezone.utc)
    if candidate < now:
        # If no year in text, push to next year
        if day is None or len(str(year)) <= 2:
            try:
                candidate = datetime(year + 1, month, d, tzinfo=timezone.utc)
            except ValueError:
                candidate = datetime(year + 1, month, 1, tzinfo=timezone.utc)
    return candidate

def _month_to_num(m: str) -> int | None:
    return _MONTHS.get(m.lower()[:3]) or _MONTHS.get(m.lower())

def _parse_release_from_title(title: str) -> Tuple[Optional[str], bool, bool]:
    """
    Try to extract (release_date_iso, is_theatrical, is_upcoming)
    from a headline. Best-effort, safe defaults.
    """
    t = title or ""
    if not t:
        return (None, False, False)

    now = datetime.now(timezone.utc)
    is_theatrical = bool(THEATRE_RE.search(t))
    # date candidates
    rd: Optional[datetime] = None

    # 12 Nov 2025 / 12 November / 12 Nov
    m = DAY_MON_YR.search(t)
    if m:
        day = int(m.group(1))
        mon = _month_to_num(m.group(2)) or 1
        yr  = int(m.group(3)) if m.group(3) else now.year
        rd = _nearest_future(yr, mon, day)

    # Nov 12, 2025 / November 12
    if not rd:
        m = MON_DAY_YR.search(t)
        if m:
            mon = _month_to_num(m.group(1)) or 1
            day = int(m.group(2))
            yr  = int(m.group(3)) if m.group(3) else now.year
            rd = _nearest_future(yr, mon, day)

    # March 2026
    if not rd:
        m = MON_YR.search(t)
        if m:
            mon = _month_to_num(m.group(1)) or 1
            yr  = int(m.group(2))
            rd = _nearest_future(yr, mon, 1)

    # Fallbacks: phrases without explicit date still hint "upcoming"
    verb_release = bool(RELEASE_VERBS_RE.search(t))
    coming_flag  = bool(COMING_SOON_RE.search(t))

    is_upcoming = False
    if rd:
        is_upcoming = rd > now
    else:
        # No date, but language suggests future
        is_upcoming = coming_flag or verb_release

    iso = rd.strftime("%Y-%m-%dT%H:%M:%SZ") if rd else None
    return (iso, is_theatrical, is_upcoming)

def _classify(title: str, fallback: str = "news") -> Tuple[str, Optional[str], Optional[str], bool, bool]:
    """
    Decide kind + computed attributes from title.
    Returns: (kind, release_date_iso, provider, is_theatrical, is_upcoming)
    """
    t = title or ""

    # Trailer takes precedence
    if TRAILER_RE.search(t):
        return ("trailer", None, None, False, False)

    # OTT provider?
    m = OTT_RE.search(t)
    if m:
        provider = m.group(1)
        # treat as OTT item
        return ("ott", None, provider, False, False)

    # Theatrical / release style?
    rd_iso, is_theatrical, is_upcoming = _parse_release_from_title(t)
    if rd_iso or is_theatrical or is_upcoming:
        return ("release", rd_iso, None, is_theatrical, is_upcoming)

    return (fallback, None, None, False, False)

# ===================== Normalizer (writes to feed) ====================

def normalize_event(event: AdapterEventDict) -> dict:
    """
    Converts adapter events into the canonical feed shape and appends to the
    Redis LIST (newest-first). Dedupes on <source>:<source_event_id>.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")
    title = (event.get("title") or "").strip()

    # base classification (use adapter hint as fallback)
    base_fallback = (event.get("kind") or "news").strip()
    kind, rd_iso, _provider, is_theatrical, is_upcoming = _classify(title, fallback=base_fallback)

    published_at = _to_rfc3339(event.get("published_at"))
    thumb_url = event.get("thumb_url")
    if source == "youtube" and not thumb_url and src_id:
        thumb_url = f"https://i.ytimg.com/vi/{src_id}/hqdefault.jpg"

    story = {
        "id": story_id,
        "kind": kind,
        "title": title,
        "summary": None,
        "published_at": published_at,
        "source": source,
        "thumb_url": thumb_url,
        # computed extras for tabs/filters
        "release_date": rd_iso,
        "is_theatrical": True if is_theatrical else None,
        "is_upcoming": True if is_upcoming else None,
        "normalized_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # Deduplicate on story id: only push if brand-new.
    if conn.sadd(SEEN_KEY, story_id):
        pipe = conn.pipeline()
        pipe.lpush(FEED_KEY, json.dumps(story))
        pipe.ltrim(FEED_KEY, 0, FEED_MAX - 1)
        pipe.execute()
        print(f"[normalize_event] NEW  -> {story_id} | {title}")
        return story

    print(f"[normalize_event] SKIP -> {story_id} (duplicate)")
    return story

# ========================== YouTube poller ===========================

# Optional channel overrides (channel_id -> kind)
YOUTUBE_CHANNEL_KIND = {
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "ott",      # Netflix (example)
    # "UCvC4D8onUfXzvjTOM-dBfEA": "trailer",  # Marvel (example)
}

def youtube_rss_poll(
    channel_id: str,
    published_after: Optional[Union[str, datetime]] = None,
    max_items: int = YT_MAX_ITEMS,
) -> int:
    """
    Poll a YouTube channel's Atom feed and enqueue normalize jobs.
    Respects ETag/Last-Modified via Redis for efficiency.
    """
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    conn = _redis()
    etag_key = f"rss:etag:yt:{channel_id}"
    mod_key  = f"rss:mod:yt:{channel_id}"

    etag = conn.get(etag_key)
    mod_epoch = conn.get(mod_key)
    modified = _time.gmtime(float(mod_epoch)) if mod_epoch else None

    try:
        parsed = feedparser.parse(url, etag=etag, modified=modified)
    except Exception as e:
        print(f"[youtube_rss_poll] ERROR parse {channel_id}: {e}")
        return 0

    status = getattr(parsed, "status", 200)
    if status == 304:
        print(f"[youtube_rss_poll] channel={channel_id} no changes (304)")
        return 0

    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        from time import mktime as _mktime
        conn.setex(mod_key, 7 * 24 * 3600, str(_mktime(parsed.modified_parsed)))

    cutoff = _to_rfc3339(published_after)
    q = Queue("events", connection=conn)
    emitted = 0

    for entry in (parsed.entries or [])[:max_items]:
        vid = _extract_video_id(entry) or ""
        if not vid:
            continue

        title = entry.get("title", "") or ""
        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )
        if cutoff and pub_norm and pub_norm <= cutoff:
            continue

        # channel override > title logic
        ch_kind = YOUTUBE_CHANNEL_KIND.get(channel_id)
        if ch_kind:
            kind = ch_kind
        else:
            kind = "trailer" if TRAILER_RE.search(title) else "ott" if OTT_RE.search(title) else "news"

        ev: AdapterEventDict = {
            "source": "youtube",
            "source_event_id": vid,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": None,  # computed in normalize if missing
            "payload": {"channelId": channel_id, "videoId": vid},
        }

        jid = _safe_job_id("normalize", ev["source"], ev["source_event_id"])
        q.enqueue(
            normalize_event,
            ev,
            job_id=jid,
            ttl=600,
            result_ttl=300,
            failure_ttl=300,
            job_timeout=30,
        )
        emitted += 1

    print(f"[youtube_rss_poll] channel={channel_id} emitted={emitted}")
    return emitted

# ========================== Generic RSS poller =======================

def rss_poll(
    url: str,
    kind_hint: str = "news",
    max_items: int = RSS_MAX_ITEMS,
) -> int:
    """
    Poll a generic RSS/Atom feed and enqueue normalize jobs.
    """
    conn = _redis()
    etag_key = f"rss:etag:{url}"
    mod_key  = f"rss:mod:{url}"

    etag = conn.get(etag_key)
    mod_epoch = conn.get(mod_key)
    modified = _time.gmtime(float(mod_epoch)) if mod_epoch else None

    try:
        parsed = feedparser.parse(url, etag=etag, modified=modified)
    except Exception as e:
        print(f"[rss_poll] ERROR parse {url}: {e}")
        return 0

    status = getattr(parsed, "status", 200)
    if status == 304:
        print(f"[rss_poll] url={url} no changes (304)")
        return 0

    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        from time import mktime as _mktime
        conn.setex(mod_key, 7 * 24 * 3600, str(_mktime(parsed.modified_parsed)))

    source_domain = _domain(parsed.feed.get("link") or url)
    q = Queue("events", connection=conn)
    emitted = 0

    for entry in (parsed.entries or [])[:max_items]:
        title = entry.get("title", "") or ""
        link = entry.get("link") or entry.get("id") or ""
        if not link:
            continue

        src_id = _hash_link(link)
        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )

        # classify with hint as fallback
        kind, _, _, _, _ = _classify(title, fallback=kind_hint)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": _link_thumb(entry),
            "payload": {"url": link, "feed": url},
        }

        jid = _safe_job_id("normalize", "rss", source_domain, src_id[:10])
        q.enqueue(
            normalize_event,
            ev,
            job_id=jid,
            ttl=600,
            result_ttl=300,
            failure_ttl=300,
            job_timeout=30,
        )
        emitted += 1

    print(f"[rss_poll] url={url} domain={source_domain} emitted={emitted}")
    return emitted
