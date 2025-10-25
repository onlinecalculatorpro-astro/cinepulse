# apps/workers/jobs.py
#
# PIPELINE ROLE (this file runs in the "workers" container / RQ queue: events)
#
#   scheduler  → polls YouTube/RSS and enqueues AdapterEventDict into "events"
#   workers    → THIS FILE, rq worker events
#                 - normalize_event(): turn AdapterEventDict → canonical story dict
#                 - enqueue that story onto the "sanitize" queue
#
#   sanitizer  → rq worker sanitize
#                 - dedupe using canonical(title+summary)
#                 - first one wins, later variants dropped
#                 - push to Redis FEED_KEY (public feed), trim, fanout, push notify
#
#   api        → serves /v1/feed by reading FEED_KEY
#
# IMPORTANT:
# - workers do NOT write directly to FEED_KEY.
# - workers do NOT dedupe.
# - workers do NOT push notifications.
# - workers just normalize and forward to sanitizer.
#
# Extra utility:
# - backfill_repair_recent() is a manual/maintenance helper to patch old items
#   in FEED_KEY (e.g. missing thumbnails). This is not part of the live loop.


from __future__ import annotations

import calendar
import hashlib
import html
import json
import os
import re
import time as _time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Optional, Union, TypedDict, Tuple, List, Dict, Any
from urllib.parse import urlparse

import feedparser
from redis import Redis
from rq import Queue

from apps.workers.extractors import (
    build_rss_payload,   # returns (payload, thumb_hint, candidates)
    abs_url,
    to_https,
)

__all__ = [
    "youtube_rss_poll",
    "rss_poll",
    "normalize_event",
    "backfill_repair_recent",
]

# =====================================================================
# Redis / env config
# =====================================================================

def _redis() -> Redis:
    """
    Build a Redis client using REDIS_URL.

    Workers use Redis for:
    - scheduling RQ jobs ("events" -> normalize_event, "sanitize" -> sanitize_story)
    - persisting poller state (etag / last-modified tracking)
    - maintenance helpers that read/write FEED_KEY for backfill
    """
    return Redis.from_url(
        os.getenv("REDIS_URL", "redis://redis:6379/0"),
        decode_responses=True,
    )

# Final public feed LIST that API reads.
# Workers DON'T write to this during live ingest — only sanitizer does.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Backfill / repair knobs (used only in backfill_repair_recent)
REPAIR_SCAN = int(os.getenv("REPAIR_SCAN", "250"))
REPAIR_BY_URL = os.getenv("REPAIR_BY_URL", "1").lower() not in ("0", "", "false", "no")

# Poller defaults (scheduler can override per-feed/per-channel)
YT_MAX_ITEMS = int(os.getenv("YT_MAX_ITEMS", "50"))
RSS_MAX_ITEMS = int(os.getenv("RSS_MAX_ITEMS", "30"))

# Summary tuning for normalize_event()
SUMMARY_TARGET = int(os.getenv("SUMMARY_TARGET_WORDS", "85"))
SUMMARY_MIN    = int(os.getenv("SUMMARY_MIN_WORDS", "60"))
SUMMARY_MAX    = int(os.getenv("SUMMARY_MAX_WORDS", "110"))
PASSTHROUGH_MAX_WORDS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_WORDS", "120"))
PASSTHROUGH_MAX_CHARS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_CHARS", "900"))

# =====================================================================
# Types
# =====================================================================

class AdapterEventDict(TypedDict, total=False):
    source: str                  # "youtube" | "rss:<domain>"
    source_event_id: str         # unique per source (e.g. YouTube video ID or hash of RSS link)
    title: str
    kind: str                    # trailer | ott | news | release
    published_at: Optional[str]  # RFC3339 UTC
    thumb_url: Optional[str]
    payload: dict                # raw-ish extracted payload (link, html, etc.)

# =====================================================================
# Classification / text cleanup helpers
# =====================================================================

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)

# OTT providers: helps classify OTT releases and tag platforms
_OTT_PROVIDERS = [
    "Netflix", "Prime Video", "Amazon Prime Video", "Disney\\+ Hotstar", "Hotstar",
    "JioCinema", "ZEE5", "Zee5", "SonyLIV", "Sony LIV", "Hulu", "Max",
    "HBO Max", "Apple TV\\+", "Apple TV",
]
OTT_RE = re.compile(
    rf"(?:on|premieres on|streams on|streaming on|now on)\s+({'|'.join(_OTT_PROVIDERS)})",
    re.I,
)

THEATRE_RE = re.compile(
    r"\b(in\s+(?:theatres|theaters|cinemas?)|theatrical(?:\s+release)?)\b",
    re.I,
)

RELEASE_VERBS_RE = re.compile(
    r"\b(release[sd]?|releasing|releases|to\s+release|set\s+to\s+release|slated\s+to\s+release|opens?|opening|hits?)\b",
    re.I,
)
COMING_SOON_RE = re.compile(r"\bcoming\s+soon\b", re.I)

_MONTHS = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
}
_MN = r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
DAY_MON_YR = re.compile(rf"\b(\d{{1,2}})\s+({_MN})\s*(\d{{2,4}})?\b", re.I)
MON_DAY_YR = re.compile(rf"\b({_MN})\s+(\d{{1,2}})(?:,\s*(\d{{2,4}}))?\b", re.I)
MON_YR     = re.compile(rf"\b({_MN})\s+(\d{{4}})\b", re.I)

# Noise filters for summary extraction
_BOILERPLATE_RE = re.compile(
    r"^\s*(subscribe|follow|like|comment|share|credits?:|cast:|music by|original score|prod(?:uction)? by|"
    r"cinematograph(?:y)?|director:?|producer:?|©|copyright|http[s]?://|#\w+|the post .* appeared first on)\b",
    re.I,
)
_TIMESTAMP_RE = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b")
_WS_RE = re.compile(r"\s+")
_TAG_RE = re.compile(r"<[^>]+>")
_URL_INLINE_RE     = re.compile(r"https?://\S+", re.I)
_HASHTAG_INLINE_RE = re.compile(r"(?<!\w)#\w+\b")
_CTA_NOISE_RE      = re.compile(
    r"\b(get\s+tickets?|book\s+now|buy\s+now|pre[- ]?order|link\s+in\s+bio|watch\s+now|stream\s+now)\b",
    re.I,
)
_ELLIPSIS_TAIL_RE = re.compile(r"(\[\s*(?:…|\.{3})\s*\]\s*)+$")
_DANGLING_ELLIPSIS_RE = re.compile(r"(?:…|\.{3})\s*$")
_BAD_END_WORD = re.compile(r"\b(?:and|but|or|so|because|since|although|though|while|as)\.?$", re.I)
_AUX_TAIL_RE = re.compile(
    r"\b(?:has|have|had|is|are|was|were|will|can|could|should|may|might|do|does|did)\b[\.…]*\s*$",
    re.I,
)
_SENT_SPLIT_RE = re.compile(r"(?<=[\.!?])\s+")

# =====================================================================
# Time helpers
# =====================================================================

def _to_rfc3339(value: Optional[Union[str, datetime, _time.struct_time]]) -> Optional[str]:
    """
    Normalize mixed timestamp formats into RFC3339 UTC ("YYYY-MM-DDTHH:MM:SSZ").

    - datetime:
        naive → assume UTC
        tz-aware → convert to UTC
    - struct_time: treat as UTC (feedparser gives UTC-ish)
    - str: parse common RFC822/RFC3339-ish formats (respects embedded tz)
    """
    if value is None:
        return None

    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if isinstance(value, _time.struct_time):
        epoch = calendar.timegm(value)
        dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    s = str(value).strip()
    if not s:
        return None

    try:
        dt = parsedate_to_datetime(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        # Already ISO-like? just trust it.
        return s

# =====================================================================
# ID/link helpers
# =====================================================================

def _extract_video_id(entry: dict) -> Optional[str]:
    """
    Try to get YouTube video ID from feedparser entry.
    """
    vid = entry.get("yt_videoid") or entry.get("yt:videoid")
    if vid:
        return vid

    link = (entry.get("link") or "") + " "
    if "watch?v=" in link:
        return link.split("watch?v=", 1)[1].split("&", 1)[0]

    return None


def _safe_job_id(prefix: str, *parts: str) -> str:
    """
    Create a stable-but-sanitized job_id for RQ.
    """
    def clean(s: str) -> str:
        return re.sub(r"[^A-Za-z0-9_\-]+", "-", s).strip("-")

    jid = "-".join([clean(prefix), *(clean(p) for p in parts if p)]).strip("-")
    return (jid or clean(prefix))[:200]


def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"


def _hash_link(link: str) -> str:
    """
    Hash normalized link so the same story across mirror URLs
    ends up with the same source_event_id.
    """
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()

# =====================================================================
# Release date classification
# =====================================================================

def _nearest_future(year: int, month: int, day: int | None) -> datetime:
    """
    Interpret a (possibly ambiguous) date reference from title and push it forward
    if it would land in the past.
    """
    now = datetime.now(timezone.utc)
    d = 1 if day is None else max(1, min(28, day))

    # Basic heuristic for 2-digit years.
    if year < 100:
        year = 1900 + year if year >= 70 else 2000 + year

    candidate = datetime(year, month, d, tzinfo=timezone.utc)

    if candidate < now:
        # e.g. "releases July 15" but that's gone already this year -> assume next year
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
    Pull out theatrical/OTT release timing from the title if present.

    Returns (release_date_iso, is_theatrical, is_upcoming_flag)
    """
    t = title or ""
    if not t:
        return (None, False, False)

    now = datetime.now(timezone.utc)
    is_theatrical = bool(THEATRE_RE.search(t))
    rd: Optional[datetime] = None

    # "12 Jan 2025" / "12 January 2025"
    m = DAY_MON_YR.search(t)
    if m:
        day = int(m.group(1))
        mon = _month_to_num(m.group(2)) or 1
        yr  = int(m.group(3)) if m.group(3) else now.year
        rd = _nearest_future(yr, mon, day)

    # "Jan 12, 2025"
    if not rd:
        m = MON_DAY_YR.search(t)
        if m:
            mon = _month_to_num(m.group(1)) or 1
            day = int(m.group(2))
            yr  = int(m.group(3)) if m.group(3) else now.year
            rd = _nearest_future(yr, mon, day)

    # "Jan 2025"
    if not rd:
        m = MON_YR.search(t)
        if m:
            mon = _month_to_num(m.group(1)) or 1
            yr  = int(m.group(2))
            rd = _nearest_future(yr, mon, 1)

    verb_release = bool(RELEASE_VERBS_RE.search(t))
    coming_flag  = bool(COMING_SOON_RE.search(t))

    is_upcoming = rd > now if rd else (coming_flag or verb_release)
    iso = rd.strftime("%Y-%m-%dT%H:%M:%SZ") if rd else None
    return (iso, is_theatrical, is_upcoming)


def _classify(title: str, fallback: str = "news") -> Tuple[str, Optional[str], Optional[str], bool, bool]:
    """
    Decide story.kind:
      - "trailer"  -> explicit trailer/teaser keywords
      - "ott"      -> mentions "now on Netflix" / "streaming on Hotstar", etc.
      - "release"  -> theatrical/OTT release timing found in title
      - else fallback (usually "news")

    Returns:
      (kind, release_date_iso, ott_provider, is_theatrical, is_upcoming)
    """
    t = title or ""
    if TRAILER_RE.search(t):
        return ("trailer", None, None, False, False)

    m = OTT_RE.search(t)
    if m:
        provider = m.group(1)
        return ("ott", None, provider, False, False)

    rd_iso, is_theatrical, is_upcoming = _parse_release_from_title(t)
    if rd_iso or is_theatrical or is_upcoming:
        return ("release", rd_iso, None, is_theatrical, is_upcoming)

    return (fallback, None, None, False, False)

# =====================================================================
# Summary generation helpers
# =====================================================================

def _strip_html(s: str) -> str:
    """
    Convert messy HTML-ish description into cleaner plain text,
    and drop marketing boilerplate like "get tickets now".
    """
    if not s:
        return ""

    # decode entities, nuke tags/timecodes/hashtags/CTAs/etc.
    s = html.unescape(s)
    s = _TAG_RE.sub(" ", s)
    s = _TIMESTAMP_RE.sub(" ", s)

    lines = [ln.strip() for ln in s.splitlines()]
    keep: list[str] = []
    for ln in lines:
        if not ln:
            continue
        if _BOILERPLATE_RE.search(ln) or _CTA_NOISE_RE.search(ln):
            continue
        keep.append(ln)

    s2 = " ".join(keep)
    s2 = _URL_INLINE_RE.sub(" ", s2)
    s2 = _HASHTAG_INLINE_RE.sub(" ", s2)
    s2 = _ELLIPSIS_TAIL_RE.sub("", s2)
    s2 = _DANGLING_ELLIPSIS_RE.sub("", s2)
    return _WS_RE.sub(" ", s2).strip()


def _score_sentence(title_kw: set[str], s: str) -> int:
    """
    Heuristic importance score for candidate summary sentences:
    - overlap with title keywords
    - sign of "action" verbs (announced / releasing / delayed / etc.)
    """
    overlap = len(
        title_kw.intersection(
            w.lower() for w in re.findall(r"[A-Za-z0-9]+", s)
        )
    )
    verb_bonus = 1 if re.search(
        r"\b(is|are|was|were|has|have|had|will|to|set|announc\w+|releas\w+|premier\w+|exit\w+|walk\w+|cancel\w+|delay\w+)\b",
        s,
        re.I,
    ) else 0
    return overlap * 2 + verb_bonus


def _tidy_end(s: str) -> str:
    """
    Clean up ragged sentence endings and make sure we end with punctuation.
    """
    s = _DANGLING_ELLIPSIS_RE.sub("", s).strip()
    s = _BAD_END_WORD.sub("", s).rstrip()
    if s and s[-1] not in ".!?":
        s += "."
    return s


def _select_sentences_for_summary(title: str, body_text: str) -> str:
    """
    Build a summary paragraph:
    - If the cleaned body is already short, just use it (tidied).
    - Otherwise pick the top-scoring sentences (see _score_sentence),
      making sure we hit SUMMARY_MIN..SUMMARY_TARGET words but don't
      blow past SUMMARY_MAX.
    """
    body_text = (body_text or "").strip()
    if not body_text:
        return title.strip()

    words_all = body_text.split()
    if len(words_all) <= PASSTHROUGH_MAX_WORDS and len(body_text) <= PASSTHROUGH_MAX_CHARS:
        return _tidy_end(body_text)

    title_kw = set(w.lower() for w in re.findall(r"[A-Za-z0-9]+", title))
    sentences = [x.strip() for x in _SENT_SPLIT_RE.split(body_text) if x.strip()]
    if not sentences:
        return _tidy_end(body_text)

    scored = [(_score_sentence(title_kw, s), i, s) for i, s in enumerate(sentences)]
    scored.sort(key=lambda x: (-x[0], x[1]))
    pool_idx = {i for _, i, _ in scored[:10]}

    chosen: list[tuple[int, str]] = []
    count = 0
    for i, s in enumerate(sentences):
        if i not in pool_idx:
            continue
        wc = len(s.split())
        if wc < 6:
            continue
        if count < SUMMARY_MIN or (count + wc) <= SUMMARY_MAX:
            chosen.append((i, s))
            count += wc
        if count >= SUMMARY_MIN and count >= SUMMARY_TARGET:
            break

    if not chosen:
        # fallback to first semi-long sentence
        for s in sentences:
            if len(s.split()) >= 6:
                chosen = [(0, s)]
                break

    chosen.sort(key=lambda x: x[0])

    # drop weak trailing sentence
    while len(chosen) > 1:
        tail = chosen[-1][1]
        if len(tail.split()) < 8 or _AUX_TAIL_RE.search(tail):
            chosen.pop()
        else:
            break

    summary = " ".join(s for _, s in chosen).strip()

    # enforce SUMMARY_MAX on final text
    while len(summary.split()) > SUMMARY_MAX and len(chosen) > 1:
        chosen.pop()
        summary = " ".join(s for _, s in chosen).strip()

    return _tidy_end(summary)

# =====================================================================
# Tagging helpers
# =====================================================================

INDUSTRY_ORDER = ["hollywood", "bollywood", "tollywood", "kollywood", "mollywood", "sandalwood"]

DOMAIN_TO_INDUSTRY = {
    "variety.com": "hollywood",
    "hollywoodreporter.com": "hollywood",
    "deadline.com": "hollywood",
    "indiewire.com": "hollywood",
    "slashfilm.com": "hollywood",
    "collider.com": "hollywood",
    "vulture.com": "hollywood",

    "bollywoodhungama.com": "bollywood",
    "koimoi.com": "bollywood",
    "filmfare.com": "bollywood",
    "pinkvilla.com": "bollywood",

    "123telugu.com": "tollywood",
    "telugu360.com": "tollywood",
    "greatandhra.com": "tollywood",
    "gulte.com": "tollywood",
    "cinejosh.com": "tollywood",

    "onlykollywood.com": "kollywood",
    "behindwoods.com": "kollywood",
    "galatta.com": "kollywood",

    "onmanorama.com": "mollywood",
    "manoramaonline.com": "mollywood",

    "chitraloka.com": "sandalwood",
}

KEYWORD_TO_INDUSTRY = [
    (re.compile(r"\bbollywood\b|\bhindi\b", re.I), "bollywood"),
    (re.compile(r"\btollywood\b|\btelugu\b", re.I), "tollywood"),
    (re.compile(r"\bkollywood\b|\btamil\b", re.I), "kollywood"),
    (re.compile(r"\bmollywood\b|\bmalayalam\b", re.I), "mollywood"),
    (re.compile(r"\bsandalwood\b|\bkannada\b", re.I), "sandalwood"),
    (re.compile(r"\bhollywood\b", re.I), "hollywood"),
]

YOUTUBE_CHANNEL_TAG: dict[str, str] = {
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "hollywood",
}


def _industry_tags(source: str, source_domain: Optional[str], title: str, body_text: str, payload: dict) -> list[str]:
    """
    Infer industry tags (bollywood, tollywood, etc.) from:
    - domain heuristics (pinkvilla.com -> bollywood)
    - keywords in title/body ("tollywood", "telugu", etc.)
    - known YouTube channels
    """
    cand = set()

    dom = (source_domain or "").lower()
    for suffix, tag in DOMAIN_TO_INDUSTRY.items():
        if dom.endswith(suffix):
            cand.add(tag)
            break

    hay = f"{title}\n{body_text or ''}"
    for rx, t in KEYWORD_TO_INDUSTRY:
        if rx.search(hay):
            cand.add(t)

    if source == "youtube":
        ch = (payload or {}).get("channelId")
        if ch and ch in YOUTUBE_CHANNEL_TAG:
            cand.add(YOUTUBE_CHANNEL_TAG[ch])

    return [t for t in INDUSTRY_ORDER if t in cand]

# =====================================================================
# Image helpers
# =====================================================================

_YT_ID = re.compile(r"(?:v=|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})")

def _youtube_thumb(link: str | None) -> str | None:
    """
    Best-effort YouTube thumbnail derivation from watch URL.
    """
    if not link:
        return None
    m = _YT_ID.search(link)
    if not m:
        return None
    vid = m.group(1)
    return f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"


def _images_from_html_block(html_str: Optional[str], base_url: str) -> List[Tuple[str, int]]:
    """
    Wrapper around the extractor's HTML image scraping helper.
    Returns list[(url, size_estimate)].
    """
    from apps.workers.extractors import _images_from_html_block as _imgs  # type: ignore
    return _imgs(html_str, base_url)


# --- NEW: heuristics to skip ugly social-card / watermark thumbs ---------

_BAD_IMG_RE = re.compile(
    r"(sprite|icon|favicon|logo|watermark|default[-_]?og|default[-_]?share|"
    r"social[-_]?share|generic[-_]?share|breaking[-_]?news[-_]?card)",
    re.I,
)

def _looks_bad_brand_card(u: str) -> bool:
    """
    Heuristic: skip obvious branding / watermark / social share cards.
    These are the KOIMOI-style red-circle/logotype social cards,
    generic "breaking news" slates, favicons, etc.
    We still allow real photos / posters.
    """
    l = u.lower()

    # If URL screams 'logo' / 'icon' / 'share-card' / 'default-og' etc.
    if _BAD_IMG_RE.search(l):
        return True

    # Tiny squares / tracking pixels / low-res thumbs often look like junk:
    # e.g. "...-150x150.jpg", "...1x1.png", etc.
    if re.search(r"(\b|_)(1x1|64x64|100x100|150x150)(\b|_)", l):
        return True

    # Some sites serve "default social share" fallback images
    if "default" in l and ("og" in l or "share" in l or "social" in l):
        return True

    return False


def _pick_image_from_payload(payload: dict, base: str, thumb_hint: Optional[str]) -> Optional[str]:
    """
    Choose a representative hero image for the story.

    Priority with filtering:
    1. payload["image_candidates"] (ranked by extractor) but SKIP obvious
       watermark / logo / social share cards
    2. thumb_hint (if not skipped)
    3. <enclosure> images in RSS
    4. Inline <img> candidates in content_html / description_html / summary
    5. Fallback to first usable URL even if it's "meh"

    Returns first usable https URL, else None.
    """

    def _norm_one(u: Optional[str]) -> Optional[str]:
        if not u:
            return None
        return to_https(abs_url(u, base))

    ordered: List[str] = []

    # 1. Ranked candidates from extractor.build_rss_payload()
    cand_list = payload.get("image_candidates")
    if isinstance(cand_list, list):
        for u in cand_list:
            if isinstance(u, str):
                ordered.append(u)

    # 2. thumb_hint from poller (often same as first candidate anyway)
    if thumb_hint:
        ordered.insert(0, thumb_hint)

    # 3. RSS enclosures (<enclosure type="image/..."> or ...jpg)
    for enc in (payload.get("enclosures") or []):
        if not isinstance(enc, dict):
            continue
        u = enc.get("href") or enc.get("url")
        if not u:
            continue
        t = (enc.get("type") or "").lower()
        if t.startswith("image/") or u.lower().split("?", 1)[0].endswith((
            ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif",
            ".bmp", ".jfif", ".pjpeg",
        )):
            ordered.append(u)

    # 4. Inline imgs from HTML blocks (content_html / description_html / summary)
    for key in ("content_html", "description_html", "summary"):
        for u, _bias in _images_from_html_block(payload.get(key), base):
            ordered.append(u)

    # PASS 1: return first *good* candidate (not a social-card / logo)
    for raw in ordered:
        normed = _norm_one(raw)
        if not normed:
            continue
        if not _looks_bad_brand_card(normed):
            return normed

    # PASS 2: fallback to first valid URL at all
    for raw in ordered:
        normed = _norm_one(raw)
        if normed:
            return normed

    return None


def _has_any_image(obj: Dict[str, Any]) -> bool:
    """
    Lightweight predicate for "story already has an image-like field".
    Used by backfill_repair_recent.
    """
    return bool(
        obj.get("image")
        or obj.get("thumb_url")
        or obj.get("thumbnail")
        or obj.get("poster")
        or obj.get("media")
    )

# =====================================================================
# Main worker job: normalize_event
# =====================================================================

def normalize_event(event: AdapterEventDict) -> dict:
    """
    TURN RAW ADAPTER EVENT → CANONICAL STORY → HAND OFF TO SANITIZER.

    This runs inside the "events" RQ worker (the workers container).

    Flow:
      1. Gather source info (YouTube / RSS).
      2. Extract/clean body text, title, publish time, etc.
      3. Classify kind (trailer / ott / release / news).
      4. Build summary.
      5. Pick a thumbnail.
      6. Attach industry tags, timestamps, etc.
      7. Enqueue this story to the "sanitize" queue.

    CRITICAL: We DO NOT write to FEED_KEY or dedupe here.
              Sanitizer is the only one allowed to publish to the feed.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")
    title = (event.get("title") or "").strip()

    # classify kind
    base_fallback = (event.get("kind") or "news").strip()
    kind, rd_iso, provider_from_title, is_theatrical, is_upcoming = _classify(
        title,
        fallback=base_fallback,
    )

    published_at = _to_rfc3339(event.get("published_at"))
    payload = event.get("payload") or {}

    # Build canonical link / domain / body text / thumb hint
    if source == "youtube":
        link = payload.get("watch_url") or (
            f"https://www.youtube.com/watch?v={src_id}" if src_id else None
        )
        source_domain = "youtube.com"

        desc = payload.get("description") or ""
        raw_text = _strip_html(desc)

        # NOTE: _detect_ott_provider referenced here in your original codebase;
        # leaving call as-is since you already use it.
        ott_platform = provider_from_title or _detect_ott_provider(f"{title}\n{desc}")
        thumb_hint = event.get("thumb_url") or _youtube_thumb(link)

    else:
        link = payload.get("url")
        source_domain = _domain(link or source.replace("rss:", ""))

        raw_html = payload.get("content_html") or payload.get("description_html") or ""
        raw_sum  = payload.get("summary") or ""
        body     = raw_html or raw_sum
        raw_text = _strip_html(body)

        ott_platform = provider_from_title
        thumb_hint   = event.get("thumb_url")

    # Normalize to absolute https URL
    link = to_https(abs_url(link, payload.get("feed") or link or "")) or ""
    base_for_imgs = link or (payload.get("feed") or "")

    # Choose image (now with brand-card filtering in _pick_image_from_payload)
    image_url = _pick_image_from_payload(payload, base_for_imgs, thumb_hint)
    if not image_url and source == "youtube":
        image_url = _youtube_thumb(link)

    # Build summary text
    summary_text = _select_sentences_for_summary(title, raw_text)

    # Tag industries/regions
    tags = _industry_tags(source, source_domain, title, raw_text, payload)

    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    story = {
        "id": story_id,
        "kind": kind,
        "title": title,
        "summary": summary_text or None,
        "published_at": published_at,        # source publish time (UTC)
        "source": source,
        "thumb_url": image_url or thumb_hint,
        "release_date": rd_iso,
        "is_theatrical": True if is_theatrical else None,
        "is_upcoming": True if is_upcoming else None,

        # first-seen / normalized timestamps
        "ingested_at": now_ts,
        "normalized_at": now_ts,

        "url": link or None,
        "source_domain": source_domain,
        "ott_platform": ott_platform,
        "tags": tags or None,

        # canonical image-ish fields
        "image": image_url,
        "thumbnail": image_url,
        "poster": image_url,
        "media": image_url,

        # transparency / debug
        "enclosures": payload.get("enclosures") or None,
        "image_candidates": payload.get("image_candidates") or None,
        "inline_images": payload.get("inline_images") or None,
        "payload": payload,
    }

    # -------------------------------------------------
    # HANDOFF TO SANITIZER QUEUE
    # -------------------------------------------------
    # Sanitizer = rq worker "sanitize" running apps.sanitizer.sanitizer.sanitize_story.
    # That is the only component allowed to:
    #   - dedupe across sources
    #   - decide "accepted" vs "duplicate" vs "invalid"
    #   - write to FEED_KEY
    #   - trim FEED_KEY
    #   - publish realtime / enqueue push
    #
    q_sanitize = Queue("sanitize", connection=conn)

    sanitize_job_id = _safe_job_id("sanitize", story_id)
    q_sanitize.enqueue(
        "apps.sanitizer.sanitizer.sanitize_story",
        story,
        job_id=sanitize_job_id,
        ttl=600,
        result_ttl=60,
        failure_ttl=600,
        job_timeout=30,
    )

    print(f"[normalize_event] QUEUED sanitize -> {story_id} | {title}")
    return story

# =====================================================================
# Pollers: youtube_rss_poll / rss_poll
# =====================================================================

YOUTUBE_CHANNEL_KIND = {
    # channel_id -> force kind label if you want, e.g. "ott" / "trailer"
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "ott",
    # "UCvC4D8onUfXzvjTOM-dBfEA": "trailer",
}

def youtube_rss_poll(
    channel_id: str,
    published_after: Optional[Union[str, datetime]] = None,
    max_items: int = YT_MAX_ITEMS,
) -> int:
    """
    Poll a YouTube channel's Atom feed and enqueue normalize_event jobs
    into the "events" RQ queue. This is called by the scheduler container.

    We keep track of ETag / Last-Modified in Redis so subsequent polls
    can short-circuit (304).
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

    # Save conditional headers for next time
    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        conn.setex(mod_key, 7 * 24 * 3600, str(calendar.timegm(parsed.modified_parsed)))

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

        # Ignore too-old items if scheduler passed a cutoff window
        if cutoff and pub_norm and pub_norm <= cutoff:
            continue

        # Channel-based override for kind, else infer from title
        ch_kind = YOUTUBE_CHANNEL_KIND.get(channel_id)
        if ch_kind:
            kind = ch_kind
        else:
            if TRAILER_RE.search(title):
                kind = "trailer"
            elif OTT_RE.search(title):
                kind = "ott"
            else:
                kind = "news"

        yt_desc = (
            entry.get("media_description")
            or entry.get("summary")
            or entry.get("subtitle")
            or ""
        )

        watch_url = entry.get("link") or f"https://www.youtube.com/watch?v={vid}"

        ev: AdapterEventDict = {
            "source": "youtube",
            "source_event_id": vid,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": None,  # normalize_event will finalize thumbnail
            "payload": {
                "channelId": channel_id,
                "videoId": vid,
                "description": yt_desc,
                "watch_url": watch_url,
            },
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


def rss_poll(
    url: str,
    kind_hint: str = "news",
    max_items: int = RSS_MAX_ITEMS,
) -> int:
    """
    Poll a generic RSS/Atom feed and enqueue normalize_event jobs
    into the "events" RQ queue. This is called by the scheduler container.

    We also store per-feed ETag / Last-Modified headers in Redis.
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

    # Save conditional headers
    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        conn.setex(mod_key, 7 * 24 * 3600, str(calendar.timegm(parsed.modified_parsed)))

    source_domain = _domain(parsed.feed.get("link") or url)

    q = Queue("events", connection=conn)
    emitted = 0

    for entry in (parsed.entries or [])[:max_items]:
        title = entry.get("title", "") or ""
        raw_link = entry.get("link") or entry.get("id") or ""
        if not raw_link:
            continue

        # Normalize link first so mirrors hash the same
        norm_link = to_https(abs_url(raw_link, url)) or raw_link
        src_id = _hash_link(norm_link)

        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )

        # Classify this item (kind), hint is fallback
        kind, _, _, _, _ = _classify(title, fallback=kind_hint)

        # Extract full payload + potential thumb candidates
        payload, thumb_hint, _cands = build_rss_payload(entry, url)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": thumb_hint,  # normalize_event will pick final img
            "payload": payload,
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

# =====================================================================
# Manual maintenance: backfill_repair_recent
# =====================================================================

def backfill_repair_recent(scan: int = None) -> int:
    """
    Offline repair tool for FEED_KEY entries that already went live.

    Use this manually (admin script / cron you control), NOT in the live path.

    What it tries to do:
    - Walk the most recent N items in FEED_KEY.
    - Ensure 'ingested_at' exists.
    - If an item has zero image fields, try to rebuild a thumbnail
      from stored payload and write it back with LSET.

    NOTE:
    - This mutates past stories. The live path explicitly does *not*
      retro-upgrade items anymore. First accepted version "wins"
      and we do not overwrite it during ingest.
    - backfill_repair_recent exists just to clean up old feed quality
      (e.g. before a demo).
    """
    conn = _redis()
    window = int(scan or REPAIR_SCAN)

    items = conn.lrange(FEED_KEY, 0, max(window - 1, 0))
    patched = 0

    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for idx, raw in enumerate(items):
        try:
            obj = json.loads(raw)
        except Exception:
            continue

        need_save = False

        # Ensure stable first-seen timestamp
        if not obj.get("ingested_at"):
            obj["ingested_at"] = obj.get("normalized_at") or now_ts
            need_save = True

        # Try to recover missing image(s)
        if not _has_any_image(obj):
            payload = obj.get("payload") or {}
            link = obj.get("url") or (
                payload.get("url") if isinstance(payload, dict) else None
            )
            base = link or (
                payload.get("feed") if isinstance(payload, dict) else ""
            )

            # Try what we already have in payload
            if isinstance(payload, dict) and payload:
                thumb = _pick_image_from_payload(
                    payload,
                    base,
                    payload.get("image_candidates", [None])[0]
                    if isinstance(payload.get("image_candidates"), list)
                    else None,
                )
            else:
                thumb = None

            # Try rebuilding by re-running the extractor heuristics
            if not thumb and link:
                dummy_entry = {
                    "link": link,
                    "summary": obj.get("summary") or "",
                    "description": payload.get("description_html") if isinstance(payload, dict) else "",
                    "content": [
                        {
                            "type": "text/html",
                            "value": payload.get("content_html") if isinstance(payload, dict) else "",
                        }
                    ],
                }
                new_payload, thumb_hint, _ = build_rss_payload(
                    dummy_entry,
                    payload.get("feed") if isinstance(payload, dict) else "",
                )
                payload = (
                    {**payload, **new_payload}
                    if isinstance(payload, dict)
                    else new_payload
                )
                thumb = _pick_image_from_payload(payload, base, thumb_hint)

            if thumb:
                for k in ("image", "thumb_url", "thumbnail", "poster", "media"):
                    obj[k] = thumb
                obj["normalized_at"] = now_ts
                need_save = True

        # Write back if we changed anything
        if need_save:
            conn.lset(FEED_KEY, idx, json.dumps(obj, ensure_ascii=False))
            patched += 1
            print(f"[backfill_repair_recent] patched idx={idx} url={obj.get('url')}")

    print(f"[backfill_repair_recent] done patched={patched}")
    return patched
