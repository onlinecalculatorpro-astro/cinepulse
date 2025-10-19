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
    kind: str                    # trailer | ott | news | release  (be conservative)
    published_at: Optional[str]  # RFC3339
    thumb_url: Optional[str]
    payload: dict                # raw-ish fields we may use while normalizing

# =============================== Regexes =============================

MONTH = r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
ORD = r"(?:st|nd|rd|th)?"
SP = r"[ ,.-]+"

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)

# Strong theatrical-now signals (not just “will release”)
THEATRICAL_NOW_RE = re.compile(
    r"\b(now|opens?|hits?)\s+(in\s+)?(?:theatres?|theaters?|cinemas?)\b"
    r"|in\s+(?:theatres?|theaters?|cinemas?)\s+(?:today|this\s+friday|this\s+weekend)",
    re.I,
)

# OTT hint
OTT_RE = re.compile(
    r"\b(netflix|prime\s*video|amazon\s*prime|disney\+?\s*hotstar|hotstar|zee5|jiocinema|sony\s*liv|hulu|apple\s*tv\+?)\b",
    re.I,
)

# Generic “will release” marker
RELEASE_TALK_RE = re.compile(
    r"\b(release[sd]?|releasing|set\s+to\s+release|slated\s+to\s+release|to\s+hit\s+(?:theatres?|theaters?|cinemas?))\b",
    re.I,
)

# Date patterns we try (month-first, day-first, and ISO)
DATE_PATTERNS = [
    # Oct 21, 2025  |  October 21, 2025
    re.compile(rf"\b({MONTH}){SP}(\d{{1,2}}){ORD}(?:{SP}(\d{{4}}))?\b", re.I),
    # 21 Oct 2025
    re.compile(rf"\b(\d{{1,2}}){ORD}{SP}({MONTH})(?:{SP}(\d{{4}}))?\b", re.I),
    # October 2025 (no day)
    re.compile(rf"\b({MONTH})(?:{SP}(\d{{4}}))\b", re.I),
    # ISO-like 2025-11-05
    re.compile(r"\b(20\d{2})-(\d{1,2})-(\d{1,2})\b"),
]

MONTH_MAP = {
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

# =============================== Utils ===============================

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
    jid = "-join".replace("join", "").join([clean(prefix), *(clean(p) for p in parts if p)])
    # simpler: just concatenate with hyphens
    jid = "-".join([clean(prefix), *(clean(p) for p in parts if p)])
    return (jid or clean(prefix))[:200]

def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"

def _hash_link(link: str) -> str:
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()

def _month_to_int(name: str) -> Optional[int]:
    return MONTH_MAP.get(name.lower())

# ---------------------- release info extraction ----------------------

def _parse_release(text: str) -> Tuple[Optional[str], Optional[bool]]:
    """
    Try to extract a release date (RFC3339 midnight UTC) and a theatrical flag
    from free text. Returns (release_date, is_theatrical).

    * If only month+year is found -> day=01.
    * is_theatrical is True only when strong theatre words are present.
    """
    if not text:
        return None, None

    theatrical = bool(THEATRICAL_NOW_RE.search(text)) or bool(
        re.search(r"\b(in\s+(?:theatres?|theaters?|cinemas?)|theatrical)\b", text, re.I)
    )

    # ISO 2025-11-05
    m = DATE_PATTERNS[3].search(text)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        try:
            dt = datetime(y, mo, d, tzinfo=timezone.utc)
            return _to_rfc3339(dt), theatrical or None
        except ValueError:
            pass

    # Oct 21, 2025  |  October 21, 2025
    m = DATE_PATTERNS[0].search(text)
    if m:
        mo_name, day_s, year_s = m.group(1), m.group(2), m.group(3)
        mo = _month_to_int(mo_name)
        if mo:
            day = int(day_s)
            year = int(year_s) if year_s else datetime.now(timezone.utc).year
            try:
                dt = datetime(year, mo, day, tzinfo=timezone.utc)
                return _to_rfc3339(dt), theatrical or None
            except ValueError:
                pass

    # 21 Oct 2025
    m = DATE_PATTERNS[1].search(text)
    if m:
        day_s, mo_name, year_s = m.group(1), m.group(2), m.group(3)
        mo = _month_to_int(mo_name)
        if mo:
            day = int(day_s)
            year = int(year_s) if year_s else datetime.now(timezone.utc).year
            try:
                dt = datetime(year, mo, day, tzinfo=timezone.utc)
                return _to_rfc3339(dt), theatrical or None
            except ValueError:
                pass

    # October 2025 (no day)
    m = DATE_PATTERNS[2].search(text)
    if m:
        mo_name, year_s = m.group(1), m.group(2)
        mo = _month_to_int(mo_name)
        if mo:
            year = int(year_s)
            # default to 1st of month
            dt = datetime(year, mo, 1, tzinfo=timezone.utc)
            return _to_rfc3339(dt), theatrical or None

    return None, theatrical or None

def _classify_from_title(title: str, fallback: str = "news") -> str:
    """Conservative kind classifier (avoid false 'release')."""
    t = title or ""
    if TRAILER_RE.search(t):
        return "trailer"
    if OTT_RE.search(t):
        return "ott"
    # Only very strong signals should flip to 'release'
    if THEATRICAL_NOW_RE.search(t):
        return "release"
    return fallback

# ===================== Normalizer (writes to feed) ====================

def _enrich_release_fields(
    title: str, payload: dict
) -> Tuple[Optional[str], Optional[bool], Optional[bool]]:
    """
    Parse release info from title + any text in payload (e.g., summary).
    Returns (release_date, is_theatrical, is_upcoming).
    """
    text = " ".join(
        [
            title or "",
            str(payload.get("summary") or ""),
            str(payload.get("description") or ""),
        ]
    )

    rel_date, theatrical_flag = _parse_release(text)

    is_upcoming = None
    if rel_date:
        try:
            dt = datetime.fromisoformat(rel_date.replace("Z", "+00:00"))
            is_upcoming = dt > datetime.now(timezone.utc)
        except Exception:
            is_upcoming = None

    return rel_date, theatrical_flag, is_upcoming

def normalize_event(event: AdapterEventDict) -> dict:
    """
    Converts adapter events into the canonical feed shape and appends to the
    Redis LIST (newest-first). Dedupes on <source>:<source_event_id>.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")
    # keep kind conservative; don't auto-upgrade to 'release'
    kind = _classify_from_title(event.get("title") or "", fallback=(event.get("kind") or "news").strip())
    title = (event.get("title") or "").strip()
    published_at = _to_rfc3339(event.get("published_at"))
    thumb_url = event.get("thumb_url")
    payload = event.get("payload") or {}

    if source == "youtube" and not thumb_url and src_id:
        thumb_url = f"https://i.ytimg.com/vi/{src_id}/hqdefault.jpg"

    release_date, is_theatrical, is_upcoming = _enrich_release_fields(title, payload)

    story = {
        "id": story_id,
        "kind": kind,
        "title": title,
        "summary": None,
        "published_at": published_at,
        "source": source,
        "thumb_url": thumb_url,
        "normalized_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        # enrichment
        "release_date": release_date,
        "is_theatrical": is_theatrical,
        "is_upcoming": is_upcoming,
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

        # channel override > title regex fallback
        kind = YOUTUBE_CHANNEL_KIND.get(channel_id) or (
            "trailer" if TRAILER_RE.search(title) else
            "ott" if OTT_RE.search(title) else "news"
        )

        ev: AdapterEventDict = {
            "source": "youtube",
            "source_event_id": vid,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": None,  # computed in normalize if missing
            "payload": {"channelId": channel_id, "videoId": vid, "summary": entry.get("summary", "")},
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

        # Keep kind conservative (avoid false 'release')
        kind = _classify_from_title(title, fallback=kind_hint)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": _link_thumb(entry),
            "payload": {
                "url": link,
                "feed": url,
                "summary": entry.get("summary", "") or entry.get("description", ""),
            },
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
