# apps/workers/jobs.py
from __future__ import annotations

import hashlib
import json
import os
import re
import time as _time
from datetime import datetime, timezone
from typing import Optional, Union, TypedDict
from urllib.parse import urlparse

import feedparser
from redis import Redis
from rq import Queue

__all__ = ["youtube_rss_poll", "rss_poll", "normalize_event"]

# ============================================================================
# Redis / keys
# ============================================================================

def _redis() -> Redis:
    # redis://host:port/db
    return Redis.from_url(
        os.getenv("REDIS_URL", "redis://redis:6379/0"),
        decode_responses=True,
    )

# Single source of truth for the app feed LIST key.
# Keep default aligned with the API.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")   # LIST, newest-first
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen")    # SET of story ids for dedupe

# Max number of items to retain in the feed LIST (trimmed on each insert).
FEED_MAX = int(os.getenv("FEED_MAX", "1200"))

# Per-poller defaults (overridable by env)
YT_MAX_ITEMS = int(os.getenv("YT_MAX_ITEMS", "50"))
RSS_MAX_ITEMS = int(os.getenv("RSS_MAX_ITEMS", "30"))

# ============================================================================
# Types
# ============================================================================

class AdapterEventDict(TypedDict, total=False):
    source: str                  # "youtube" | "rss:<domain>"
    source_event_id: str         # unique per source (videoId | link hash)
    title: str
    # incoming hint; final kind decided in normalize_event()
    # trailer | ott | news | release | (legacy hints; we enrich/expand)
    kind: str
    published_at: Optional[str]  # RFC3339
    thumb_url: Optional[str]
    payload: dict                # may include url, channelId, videoId, feed, etc.

# ============================================================================
# Regex helpers (classification)
# ============================================================================

# Video/promos
TRAILER_PAT     = re.compile(r"\b(trailer|teaser|glimpse|promo)\b", re.I)
CLIP_PAT        = re.compile(r"\b(clip|tv\s*spot|scene|sneak\s*peek)\b", re.I)
FEATURETTE_PAT  = re.compile(r"\b(featurette|behind\s+the\s+scenes|making\s+of|\bbts\b)\b", re.I)
SONG_PAT        = re.compile(r"\b(song|lyric\s*video|audio\s*launch|single|title\s*track)\b", re.I)
POSTER_PAT      = re.compile(r"\b(first\s*look|motion\s*poster|poster|title\s*reveal)\b", re.I)

# Releases & schedule
REL_ANNOUNCE_PAT = re.compile(
    r"\b(announce[sd]?|set\s+to\s+(?:release|premiere)|slated\s+for|to\s+release|"
    r"releases?\s+on|premieres?\s+on|coming\s+in|coming\s+on|opening\s+on|hits\s+theatres?)\b",
    re.I,
)
SCHEDULE_CHANGE_PAT = re.compile(r"\b(postponed|pushed|advanced|preponed|shifted|rescheduled|delayed|moved)\b", re.I)

# OTT platforms
PLATFORM_PAT = re.compile(
    r"\b("
    r"Netflix|Prime\s*Video|Amazon\s*Prime(?:\s*Video)?|Disney\+\s*Hotstar|Hotstar|"
    r"JioCinema|ZEE5|SonyLIV|Hulu|Max|Apple\s*TV\+|Paramount\+|Peacock|"
    r"Lionsgate\s*Play|Aha|Sun\s*NXT|Hoichoi"
    r")\b",
    re.I,
)

# Production & business
ANNOUNCEMENT_PAT    = re.compile(r"\b(announc(?:e|es|ed)|unveil(?:s|ed)|reveal(?:s|ed))\b", re.I)
CASTING_PAT         = re.compile(r"\b(joins\s+cast|boards|cast\s+as|to\s+star|starring|roped\s+in|onboards?)\b", re.I)
PROD_UPDATE_PAT     = re.compile(r"\b(shoot\s+begins|commenc(?:e|es)d?\s+shoot(?:ing)?|wrap(?:s|ped)|schedule\s+wrap|"
                                 r"completed?\s+filming|principal\s+photography|dubbing|patchwork|kickstarts?)\b", re.I)
ACQUISITION_PAT     = re.compile(r"\b(acquires?|acquired|rights|distribution|distributor|picked\s+up\s+by|sold\s+to)\b", re.I)
CENSOR_PAT          = re.compile(r"\b(CBFC|censor|certificate|U\/A|U-A|U\/A|U|A\s+certificate)\b", re.I)

# Reviews / performance / recognition
REVIEW_PAT          = re.compile(r"\b(review|first\s+reactions?|our\s+take|rating|stars?\/\d)\b", re.I)
BOXOFFICE_PAT       = re.compile(r"\b(box\s*office|collections?|opening|day\s*\d|weekend|lifetime|gross|nett|crore?s?)\b", re.I)
AWARD_PAT           = re.compile(r"\b(nominat(?:ed|ions?)|wins?|best\s+(actor|actress|film|picture)|Oscars?|BAFTA|SIIMA|Filmfare)\b", re.I)
FESTIVAL_PAT        = re.compile(r"\b(premieres?\s+at|festival|lineup|Cannes|Venice|TIFF|Sundance|IFFI|Berlinale)\b", re.I)

# People & soft news
INTERVIEW_PAT       = re.compile(r"\b(interview|talks\s+about|speaks\s+about|Q&A)\b", re.I)
OBITUARY_PAT        = re.compile(r"\b(passes\s+away|dies(?:\s+at)?|demise|RIP|no\s+more)\b", re.I)
RUMOR_PAT           = re.compile(r"\b(reportedly|rumou?r(?:ed)?|speculation|buzz\s+is)\b", re.I)

# Month words → number
MONTHS = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "september": 9, "oct": 10, "october": 10,
    "nov": 11, "november": 11, "dec": 12, "december": 12,
}

# Light language hints by domain (best-effort)
LANG_BY_DOMAIN = {
    "123telugu.com": "te",
    "telugu360.com": "te",
    "greatandhra.com": "te",
    "bollywoodhungama.com": "hi",
    "variety.com": "en",
    "hollywoodreporter.com": "en",
    "deadline.com": "en",
    "indiewire.com": "en",
    "slashfilm.com": "en",
}

# ============================================================================
# Utils
# ============================================================================

def _classify_from_title(title: str, fallback: str = "news") -> str:
    """Legacy coarse classifier (still used as a weak hint in pollers)."""
    t = title or ""
    if TRAILER_PAT.search(t):
        return "trailer"
    if REL_ANNOUNCE_PAT.search(t):
        return "release"
    return fallback

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
    # RQ/Redis can handle long IDs, but keep it sane.
    return (jid or clean(prefix))[:200]

def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"

def _hash_link(link: str) -> str:
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()

def _source_domain_from(event_source: str) -> str:
    if (event_source or "").startswith("rss:"):
        return (event_source.split(":", 1)[1] or "rss").lower()
    if event_source == "youtube":
        return "youtube.com"
    return "rss"

def _parse_release_date_from_title(title: str) -> Optional[str]:
    """Extracts a YYYY-MM-DD from common title patterns. Month+Year -> day=01."""
    t = (title or "").strip()

    # ISO-like: 2026-03-15
    m = re.search(r"\b(20\d{2})-(\d{1,2})-(\d{1,2})\b", t)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        try:
            return datetime(y, mo, d, tzinfo=timezone.utc).strftime("%Y-%m-%d")
        except Exception:
            pass

    # "March 15, 2026" or "Mar 15, 2026"
    m = re.search(r"\b(?P<mon>[A-Za-z]{3,9})\s+(?P<day>\d{1,2}),?\s+(?P<year>20\d{2})\b", t)
    if m:
        mon = MONTHS.get(m.group("mon").lower())
        if mon:
            y, d = int(m.group("year")), int(m.group("day"))
            try:
                return datetime(y, mon, d, tzinfo=timezone.utc).strftime("%Y-%m-%d")
            except Exception:
                pass

    # "March 2026" → day=1
    m = re.search(r"\b(?P<mon>[A-Za-z]{3,9})\s+(?P<year>20\d{2})\b", t)
    if m:
        mon = MONTHS.get(m.group("mon").lower())
        if mon:
            y = int(m.group("year"))
            try:
                return datetime(y, mon, 1, tzinfo=timezone.utc).strftime("%Y-%m-%d")
            except Exception:
                pass

    return None

def _enrich(title: str, kind_hint: str, domain: str) -> dict:
    """
    Return dict with:
      kind, is_upcoming, is_theatrical, ott_platform, release_date, tags
    """
    t = title or ""
    tags = [f"source:{domain}"]
    lang = LANG_BY_DOMAIN.get(domain)
    if lang:
        tags.append(f"lang:{lang}")

    # --- Strong video/promos first (specific beats generic) ---
    if TRAILER_PAT.search(t):
        return dict(kind="trailer", is_upcoming=True, is_theatrical=None,
                    ott_platform=None, release_date=_parse_release_date_from_title(t), tags=tags)
    if TE := CLIP_PAT.search(t):
        return dict(kind="clip", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if FEATURETTE_PAT.search(t):
        return dict(kind="featurette", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if SONG_PAT.search(t):
        return dict(kind="song", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if POSTER_PAT.search(t):
        return dict(kind="poster", is_upcoming=True, is_theatrical=None,
                    ott_platform=None, release_date=_parse_release_date_from_title(t), tags=tags)

    # --- Platforms / releases ---
    plat_m = PLATFORM_PAT.search(t)
    ott_platform = plat_m.group(1).strip() if plat_m else None
    release_date = _parse_release_date_from_title(t)
    is_releasey = bool(REL_ANNOUNCE_PAT.search(t) or release_date)

    if is_releasey:
        if ott_platform:
            tags += [f"platform:{ott_platform}", "channel:ott"]
            return dict(kind="release-ott", is_upcoming=True, is_theatrical=False,
                        ott_platform=ott_platform, release_date=release_date, tags=tags)
        else:
            tags += ["channel:theatrical"]
            return dict(kind="release-theatrical", is_upcoming=True, is_theatrical=True,
                        ott_platform=None, release_date=release_date, tags=tags)

    if SCHEDULE_CHANGE_PAT.search(t):
        tags += ["channel:theatrical"]
        return dict(kind="schedule-change", is_upcoming=True, is_theatrical=True,
                    ott_platform=None, release_date=release_date, tags=tags)

    # --- Production & business ---
    if CASTING_PAT.search(t):
        return dict(kind="casting", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if PROD_UPDATE_PAT.search(t):
        return dict(kind="production-update", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if ACQUISITION_PAT.search(t):
        if ott_platform:
            tags += [f"platform:{ott_platform}", "channel:ott"]
        return dict(kind="acquisition", is_upcoming=None, is_theatrical=None,
                    ott_platform=ott_platform, release_date=None, tags=tags)
    if CENSOR_PAT.search(t):
        return dict(kind="censorship", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)

    # --- Reviews / performance / recognition ---
    if REVIEW_PAT.search(t):
        return dict(kind="review", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if BOXOFFICE_PAT.search(t):
        tags += ["channel:theatrical"]
        return dict(kind="boxoffice", is_upcoming=None, is_theatrical=True,
                    ott_platform=None, release_date=None, tags=tags)
    if AWARD_PAT.search(t):
        return dict(kind="award", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if FESTIVAL_PAT.search(t):
        return dict(kind="festival", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)

    # --- People & soft news ---
    if INTERVIEW_PAT.search(t):
        return dict(kind="interview", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if OBITUARY_PAT.search(t):
        return dict(kind="obituary", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)
    if RUMOR_PAT.search(t):
        return dict(kind="rumor", is_upcoming=None, is_theatrical=None,
                    ott_platform=None, release_date=None, tags=tags)

    # --- Platform mention without release phrasing → OTT-aligned news ---
    if ott_platform and (kind_hint or "news") != "trailer":
        tags += [f"platform:{ott_platform}", "channel:ott"]
        return dict(kind="ott", is_upcoming=None, is_theatrical=False,
                    ott_platform=ott_platform, release_date=None, tags=tags)

    # Fallback to hint or news
    return dict(kind=(kind_hint or "news"), is_upcoming=None, is_theatrical=None,
                ott_platform=None, release_date=None, tags=tags)

# ============================================================================
# Normalizer (writes to feed)
# ============================================================================

def normalize_event(event: AdapterEventDict) -> dict:
    """
    Convert adapter events into the canonical, enriched feed shape and append to
    the Redis LIST (newest-first). Dedupes on <source>:<source_event_id>.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")
    kind_hint = (event.get("kind") or "news").strip()
    title = (event.get("title") or "").strip()
    published_at = _to_rfc3339(event.get("published_at"))
    thumb_url = event.get("thumb_url")

    if source == "youtube" and not thumb_url and src_id:
        thumb_url = f"https://i.ytimg.com/vi/{src_id}/hqdefault.jpg"

    domain = _source_domain_from(source)
    enrich = _enrich(title, kind_hint, domain)

    # URL for "Open" buttons
    payload = event.get("payload") or {}
    url = payload.get("url")
    if (not url) and (source == "youtube" and src_id):
        url = f"https://www.youtube.com/watch?v={src_id}"

    story = {
        "id": story_id,
        "kind": enrich["kind"],
        "title": title,
        "summary": None,
        "published_at": published_at,
        "source": source,
        "source_domain": domain,
        "thumb_url": thumb_url,
        "url": url,
        "release_date": enrich.get("release_date"),
        "is_upcoming": enrich.get("is_upcoming"),
        "is_theatrical": enrich.get("is_theatrical"),
        "ott_platform": enrich.get("ott_platform"),
        "tags": enrich.get("tags") or [],
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

# ============================================================================
# YouTube poller
# ============================================================================

# Optional channel overrides (channel_id -> kind hint)
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
    q = Queue("default", connection=conn)
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
        kind_hint = YOUTUBE_CHANNEL_KIND.get(channel_id) or (
            "trailer" if TRAILER_PAT.search(title) else "ott"
        )

        ev: AdapterEventDict = {
            "source": "youtube",
            "source_event_id": vid,
            "title": title,
            "kind": kind_hint,
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

# ============================================================================
# Generic RSS poller
# ============================================================================

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
    q = Queue("default", connection=conn)
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

        # legacy weak hint; final decision is in normalize_event()
        kind_hint_local = _classify_from_title(title, fallback=kind_hint)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind_hint_local,
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
