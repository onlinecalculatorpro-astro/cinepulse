# apps/workers/jobs.py
#
# PIPELINE ROLE (this file runs in the "workers" container / RQ queue: events)
#
#   scheduler  → polls YouTube/RSS and enqueues AdapterEventDict into "events"
#   workers    → THIS FILE, rq worker "events"
#                 - normalize_event(): turn AdapterEventDict → canonical story dict
#                 - enqueue that story onto the "sanitize" queue
#
#   sanitizer  → rq worker "sanitize"
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
    build_rss_payload,   # -> (payload, thumb_hint, candidates)
    abs_url,
    to_https,
)
from apps.workers.summarizer import summarize_story

__all__ = [
    "youtube_rss_poll",
    "rss_poll",
    "normalize_event",
    "backfill_repair_recent",
    "FALLBACK_VERTICAL",
    "VERTICAL_RULES",
]

# =====================================================================
# Redis / env config
# =====================================================================

def _redis() -> Redis:
    """
    Build a Redis client using REDIS_URL.
    """
    return Redis.from_url(
        os.getenv("REDIS_URL", "redis://redis:6379/0"),
        decode_responses=True,
    )

FEED_KEY = os.getenv("FEED_KEY", "feed:items")

REPAIR_SCAN = int(os.getenv("REPAIR_SCAN", "250"))
REPAIR_BY_URL = os.getenv("REPAIR_BY_URL", "1").lower() not in ("0", "", "false", "no")

YT_MAX_ITEMS = int(os.getenv("YT_MAX_ITEMS", "50"))
RSS_MAX_ITEMS = int(os.getenv("RSS_MAX_ITEMS", "30"))

# =====================================================================
# Vertical config
# =====================================================================

FALLBACK_VERTICAL = os.getenv("FALLBACK_VERTICAL", "entertainment")

VERTICAL_RULES: Dict[str, Dict[str, List[str]]] = {
    "entertainment": {
        "keywords": [
            "netflix", "prime video", "amazon prime", "disney+ hotstar",
            "jiocinema", "jio cinema", "zee5", "sonyliv", "ott",
            "web series", "season ", "episode ", "now streaming",
            "trailer", "teaser", "first look", "poster reveal",
            "box office", "box-office", "collection", "opening weekend",
            "in theatres", "theatrical release", "released in cinemas",
            "bollywood", "hollywood", "tollywood", "kollywood",
            "film", "movie",
            "star cast", "cast announced", "actor", "actress", "director",
        ]
    },

    "sports": {
        "keywords": [
            "ipl", "t20", "odi", "test match", "wicket", "wickets",
            "runs", "run chase", "century", "fifty",
            "premier league", "la liga", "champions league", "goal",
            "world cup", "trophy", "final whistle",
            "wins by", "beats", "defeats", "edges past", "thrashes", "clinches win",
            "nba", "nfl", "touchdown", "super bowl", "grand slam",
            "cricket", "football", "soccer", "basketball", "tennis",
        ]
    },
}

_VERTICAL_ORDER = [FALLBACK_VERTICAL] + [
    v for v in VERTICAL_RULES.keys() if v != FALLBACK_VERTICAL
]

# =====================================================================
# Types
# =====================================================================

class AdapterEventDict(TypedDict, total=False):
    source: str                  # "youtube" | "rss:<domain>"
    source_event_id: str         # e.g. YouTube video ID or hash of normalized RSS link
    title: str
    kind: str                    # trailer | ott | news | release
    published_at: Optional[str]  # RFC3339 UTC
    thumb_url: Optional[str]
    payload: dict                # extracted payload (link, html, etc.)

# =====================================================================
# Regex / heuristics
# =====================================================================

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)

_OTT_PROVIDERS = [
    "Netflix", "Prime Video", "Amazon Prime Video", "Disney\\+ Hotstar", "Hotstar",
    "JioCinema", "Jio Cinema", "ZEE5", "Zee5", "SonyLIV", "Sony LIV", "Hulu", "Max",
    "HBO Max", "Apple TV\\+", "Apple TV",
]
OTT_RE = re.compile(
    rf"(?:on|premieres on|streams on|streaming on|now on|now streaming on)\s+({'|'.join(_OTT_PROVIDERS)})",
    re.I,
)

THEATRE_RE = re.compile(
    r"\b(in\s+(?:theatres|theaters|cinemas?)|theatrical(?:\s+release)?)\b",
    re.I,
)

RELEASE_VERBS_RE = re.compile(
    r"\b(release[sd]?|releasing|releases|to\s+release|set\s+to\s+release|"
    r"slated\s+to\s+release|opens?|opening|hits?)\b",
    re.I,
)
COMING_SOON_RE = re.compile(r"\bcoming\s+soon\b", re.I)

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
_AUX_TAIL_RE  = re.compile(
    r"\b(?:has|have|had|is|are|was|were|will|can|could|should|may|might|do|does|did)\b[\.…]*\s*$",
    re.I,
)

_BOX_OFFICE_RE = re.compile(
    r"\bbox\s*office\b|collection[s]?\b|opening\s+weekend\b|crore\b|gross(?:ed|es)?\b|earned\s+₹",
    re.I,
)
_SPORT_RESULT_RE = re.compile(
    r"\b(beats|defeats|thrashes|edges\s+past|stuns|wins\s+by|clinches\s+(?:win|victory)|"
    r"scores\s+(?:a\s+)?hat[- ]?trick|scores\s+late\s+winner)\b",
    re.I,
)

_MONTHS = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
    "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
}
_MN = (
    r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|"
    r"aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
)

DAY_MON_YR = re.compile(rf"\b(\d{{1,2}})\s+({_MN})\s*(\d{{2,4}})?\b", re.I)
MON_DAY_YR = re.compile(rf"\b({_MN})\s+(\d{{1,2}})(?:,\s*(\d{{2,4}}))?\b", re.I)
MON_YR     = re.compile(rf"\b({_MN})\s+(\d{{4}})\b", re.I)

_SENT_SPLIT_RE = re.compile(r"(?<=[\.!?])\s+")

# friendly CDNs for same-origin-ish bonus
_IMG_HOSTS_FRIENDLY = {"i0.wp.com", "i1.wp.com", "images.ctfassets.net"}

# =====================================================================
# Time helpers
# =====================================================================

def _to_rfc3339(value: Optional[Union[str, datetime, _time.struct_time]]) -> Optional[str]:
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
        return s

# =====================================================================
# ID/link helpers
# =====================================================================

def _extract_video_id(entry: dict) -> Optional[str]:
    vid = entry.get("yt_videoid") or entry.get("yt:videoid")
    if vid:
        return vid

    link = (entry.get("link") or "") + " "
    if "watch?v=" in link:
        return link.split("watch?v=", 1)[1].split("&", 1)[0]

    return None


def _safe_job_id(prefix: str, *parts: str) -> str:
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
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()

# =====================================================================
# Release date / kind classification
# =====================================================================

def _month_to_num(m: str) -> int | None:
    return _MONTHS.get(m.lower()[:3]) or _MONTHS.get(m.lower())


def _nearest_future(year: int, month: int, day: int | None) -> datetime:
    now = datetime.now(timezone.utc)
    d = 1 if day is None else max(1, min(28, day))

    if year < 100:
        year = 1900 + year if year >= 70 else 2000 + year

    candidate = datetime(year, month, d, tzinfo=timezone.utc)

    if candidate < now:
        # bump to next year for ambiguous stuff in the past
        if day is None or len(str(year)) <= 2:
            try:
                candidate = datetime(year + 1, month, d, tzinfo=timezone.utc)
            except ValueError:
                candidate = datetime(year + 1, month, 1, tzinfo=timezone.utc)

    return candidate


def _parse_release_from_title(title: str) -> Tuple[Optional[str], bool, bool]:
    t = title or ""
    if not t:
        return (None, False, False)

    now = datetime.now(timezone.utc)
    is_theatrical = bool(THEATRE_RE.search(t))
    rd: Optional[datetime] = None

    m = DAY_MON_YR.search(t)
    if m:
        day = int(m.group(1))
        mon = _month_to_num(m.group(2)) or 1
        yr  = int(m.group(3)) if m.group(3) else now.year
        rd = _nearest_future(yr, mon, day)

    if not rd:
        m = MON_DAY_YR.search(t)
        if m:
            mon = _month_to_num(m.group(1)) or 1
            day = int(m.group(2))
            yr  = int(m.group(3)) if m.group(3) else now.year
            rd = _nearest_future(yr, mon, day)

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


def _detect_ott_provider(text: str) -> Optional[str]:
    if not text:
        return None
    m = OTT_RE.search(text)
    if m:
        return m.group(1)
    return None


def _classify(title: str, fallback: str = "news") -> Tuple[str, Optional[str], Optional[str], bool, bool]:
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


def _build_kind_meta(
    kind: str,
    ott_platform: Optional[str],
    is_theatrical: bool,
    is_upcoming: bool,
    rd_iso: Optional[str],
) -> Dict[str, Any]:
    if kind == "trailer":
        return {
            "kind": "trailer",
            "label": "Official Trailer",
            "is_breaking": True,
        }

    if kind == "ott":
        return {
            "kind": "ott_drop",
            "platform": ott_platform,
            "is_breaking": True,
        }

    if kind == "release":
        return {
            "kind": "release",
            "is_theatrical": bool(is_theatrical),
            "is_upcoming": bool(is_upcoming),
            "release_date": rd_iso,
        }

    return {
        "kind": "news",
        "is_breaking": False,
    }

# =====================================================================
# Text cleanup before summarizer
# =====================================================================

def _strip_html(s: str) -> str:
    """
    Clean RSS/YouTube HTML-ish text into plain text for summarization.
    Strip boilerplate like "Subscribe", timestamps like "0:43",
    inline URLs, hashtags, etc.
    """
    if not s:
        return ""

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

# =====================================================================
# Verticals / tags
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
    # channel_id -> force an industry tag if you want
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "hollywood",
}

def _industry_tags(
    source: str,
    source_domain: Optional[str],
    title: str,
    body_text: str,
    payload: dict,
) -> List[str]:
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


def _classify_verticals(
    title: str,
    body_text: str,
    source_domain: str,
) -> List[str]:
    blob = f"{title}\n{body_text}\n{source_domain}".lower()

    hits: set[str] = set()
    for vertical_slug, cfg in VERTICAL_RULES.items():
        kws = cfg.get("keywords", [])
        for kw in kws:
            if kw.lower() in blob:
                hits.add(vertical_slug)
                break

    if not hits:
        hits = {FALLBACK_VERTICAL}

    ordered: List[str] = []
    for v in _VERTICAL_ORDER:
        if v in hits and v not in ordered:
            ordered.append(v)
    for v in sorted(hits):
        if v not in ordered:
            ordered.append(v)
    return ordered


def _content_tags(
    base_industry_tags: List[str],
    title: str,
    body_text: str,
    kind: str,
    ott_platform: Optional[str],
) -> List[str]:
    tags = set(base_industry_tags or [])
    hay = f"{title}\n{body_text or ''}"

    if kind == "trailer" or TRAILER_RE.search(title):
        tags.add("trailer")

    if kind == "ott" or ott_platform:
        tags.add("ott")
        tags.add("now-streaming")

    if _BOX_OFFICE_RE.search(hay):
        tags.add("box-office")

    if _SPORT_RESULT_RE.search(hay):
        tags.add("match-result")

    return sorted(tags)

# =====================================================================
# Image helpers
# =====================================================================

_YT_ID = re.compile(r"(?:v=|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})")

def _youtube_thumb(link: str | None) -> str | None:
    if not link:
        return None
    m = _YT_ID.search(link)
    if not m:
        return None
    vid = m.group(1)
    return f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"


def _images_from_html_block(html_str: Optional[str], base_url: str) -> List[Tuple[str, int]]:
    """
    Wrapper around extractor._images_from_html_block.
    Returns list[(url, size_bias)].
    """
    from apps.workers.extractors import _images_from_html_block as _imgs  # type: ignore
    return _imgs(html_str, base_url)

_BAD_IMG_RE = re.compile(
    r"(sprite|icon|favicon|logo|watermark|default[-_]?og|default[-_]?share|"
    r"social[-_]?share|generic[-_]?share|breaking[-_]?news[-_]?card)",
    re.I,
)

def _looks_bad_brand_card(u: str) -> bool:
    l = u.lower()

    if _BAD_IMG_RE.search(l):
        return True

    if re.search(r"(\b|_)(1x1|64x64|100x100|150x150)(\b|_)", l):
        return True

    if "default" in l and ("og" in l or "share" in l or "social" in l):
        return True

    return False

def _numeric_size_hint(u: str) -> int:
    """
    Rough size signal from URL like 1200x630, _1080, etc.
    Larger number == likely bigger/hero image.
    """
    size = 0
    m = re.search(r'(\d{3,5})[xX_ -](\d{3,5})', u)
    if m:
        try:
            a, b = int(m.group(1)), int(m.group(2))
            size = max(a, b)
        except Exception:
            pass
    else:
        m = re.search(r'[^0-9](\d{3,5})(?:p|w|h|)(?!\d)', u)
        if m:
            try:
                size = int(m.group(1))
            except Exception:
                pass
    return size

def _same_origin_bonus(img_url: str, page_url: str) -> int:
    try:
        host_img = urlparse(img_url).netloc.lower().removeprefix("www.")
        host_pg  = urlparse(page_url).netloc.lower().removeprefix("www.")
        if host_img == host_pg:
            return 80
        if host_img in _IMG_HOSTS_FRIENDLY:
            return 40
    except Exception:
        pass
    return 0

def _score_image_for_card(img_url: str, page_url: str) -> int:
    """
    NEW: score candidates so we PREFER real article/inline photos
    (like that James Gunn headshot) and AVOID branded social cards
    (like KOIMOI's orange logo tile).
    """
    score = 0
    l = img_url.lower()

    # If it's obviously junk / watermark / social card -> huge penalty.
    if _looks_bad_brand_card(img_url):
        score -= 5000

    # Prefer real article images from WordPress/media uploads.
    if "/wp-content/uploads/" in l or re.search(r"/(uploads|upload|gallery|media)/", l):
        score += 800

    # Penalize obvious share/og/social words, which tend to be social cards.
    if re.search(r"(og|open[-_]?graph|social|share[_-]?img|share[_-]?card|shareimage)", l):
        score -= 400

    # Penalize "default"/"placeholder".
    if "default" in l or "placeholder" in l:
        score -= 400

    # Tiny thumbs / pixel trackers get nuked.
    if re.search(r"(1x1|64x64|100x100|150x150)", l):
        score -= 500

    # Bigger dimension hints get a boost (1200x630 etc.).
    score += _numeric_size_hint(l)

    # Prefer same origin / friendly CDNs.
    score += _same_origin_bonus(img_url, page_url)

    # Mild bonus if it's a standard photo extension.
    if re.search(r"\.(jpe?g|png|webp|gif|avif|bmp|jfif|pjpeg)(?:[?#]|$)", l):
        score += 50

    return score

def _pick_image_from_payload(payload: dict, page_url: str, thumb_hint: Optional[str]) -> Optional[str]:
    """
    UPDATED: we now score ALL candidates and choose the best,
    instead of blindly trusting the first OG image.

    This fixes cases like Koimoi where og:image is a branded KOIMOI
    card but the article body has a real celebrity/photo we actually want.
    """
    def _norm_one(u: Optional[str]) -> Optional[str]:
        if not u:
            return None
        return to_https(abs_url(u, page_url or u))

    # Gather possible candidates
    raw_candidates: List[str] = []

    cand_list = payload.get("image_candidates")
    if isinstance(cand_list, list):
        for u in cand_list:
            if isinstance(u, str):
                raw_candidates.append(u)

    if thumb_hint:
        raw_candidates.insert(0, thumb_hint)

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
            raw_candidates.append(u)

    for key in ("content_html", "description_html", "summary"):
        for u, _bias in _images_from_html_block(payload.get(key), page_url):
            raw_candidates.append(u)

    # Normalize + dedupe
    normed_unique: Dict[str, int] = {}
    for raw in raw_candidates:
        nu = _norm_one(raw)
        if not nu:
            continue
        if nu not in normed_unique:
            normed_unique[nu] = 0  # placeholder

    if not normed_unique:
        return None

    # Score each normalized candidate with article-aware heuristics.
    scored: List[Tuple[int, str]] = []
    for u in normed_unique.keys():
        s = _score_image_for_card(u, page_url or "")
        scored.append((s, u))

    # Pick highest score.
    scored.sort(key=lambda x: x[0], reverse=True)
    best_score, best_url = scored[0]

    # Even if best_score is negative, we still return best_url,
    # because it's better than nothing.
    return best_url or None

def _has_any_image(obj: Dict[str, Any]) -> bool:
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

    Steps:
      1. Parse + clean raw adapter event.
      2. Summarize content using summarize_story() for pro tone.
      3. Classify kind (trailer/ott/release/news).
      4. Build kind_meta.
      5. Classify verticals (["entertainment"], ["sports"], ...).
      6. Build tags.
      7. Pick image using improved scoring (fixes KOIMOI social-card issue).
      8. Enqueue to sanitizer.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")

    title = (event.get("title") or "").strip()

    base_fallback = (event.get("kind") or "news").strip()
    kind, rd_iso, provider_from_title, is_theatrical, is_upcoming = _classify(
        title,
        fallback=base_fallback,
    )

    published_at = _to_rfc3339(event.get("published_at"))
    payload = event.get("payload") or {}

    # --- source-specific pieces -------------------------------------
    if source == "youtube":
        link = payload.get("watch_url") or (
            f"https://www.youtube.com/watch?v={src_id}" if src_id else None
        )
        source_domain = "youtube.com"

        desc = payload.get("description") or ""
        raw_text = _strip_html(desc)

        ott_platform = provider_from_title or _detect_ott_provider(f"{title}\n{desc}")
        thumb_hint = event.get("thumb_url") or _youtube_thumb(link)

    else:
        link = payload.get("url")
        source_domain = _domain(link or source.replace("rss:", ""))

        raw_html = payload.get("content_html") or payload.get("description_html") or ""
        raw_sum  = payload.get("summary") or ""
        body     = raw_html or raw_sum
        raw_text = _strip_html(body)

        ott_platform = provider_from_title or _detect_ott_provider(f"{title}\n{raw_text}")
        thumb_hint   = event.get("thumb_url")

    # Normalize link to https absolute
    link = to_https(abs_url(link, payload.get("feed") or link or "")) or ""
    page_for_imgs = link or (payload.get("feed") or "")

    # --- IMAGE PICK with new scoring --------------------------------
    image_url = _pick_image_from_payload(payload, page_for_imgs, thumb_hint)
    if not image_url and source == "youtube":
        image_url = _youtube_thumb(link)

    # --- SUMMARY -----------------------------------------------------
    summary_text = summarize_story(title, raw_text)

    # --- TAGS / VERTICALS / KIND_META -------------------------------
    industry_base = _industry_tags(source, source_domain, title, raw_text, payload)
    final_tags = _content_tags(industry_base, title, raw_text, kind, ott_platform)

    verticals = _classify_verticals(title, raw_text, source_domain)

    kind_meta = _build_kind_meta(
        kind=kind,
        ott_platform=ott_platform,
        is_theatrical=is_theatrical,
        is_upcoming=is_upcoming,
        rd_iso=rd_iso,
    )

    # --- FINAL STORY ------------------------------------------------
    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    story: Dict[str, Any] = {
        "id":              story_id,
        "kind":            kind,
        "kind_meta":       kind_meta,
        "verticals":       verticals,

        "title":           title,
        "summary":         summary_text or None,

        "published_at":    published_at,
        "ingested_at":     now_ts,
        "normalized_at":   now_ts,

        "release_date":    rd_iso,
        "is_theatrical":   True if is_theatrical else None,
        "is_upcoming":     True if is_upcoming else None,

        "url":             link or None,
        "source":          source,
        "source_domain":   source_domain,

        "ott_platform":    ott_platform,

        # hero image for cards / UI
        "thumb_url":       image_url or thumb_hint,
        "image":           image_url,
        "thumbnail":       image_url,
        "poster":          image_url,
        "media":           image_url,

        "tags":            final_tags or None,

        # debug / transparency
        "enclosures":       payload.get("enclosures") or None,
        "image_candidates": payload.get("image_candidates") or None,
        "inline_images":    payload.get("inline_images") or None,

        "payload":         payload,
    }

    # --- HANDOFF TO SANITIZER ---------------------------------------
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
# Pollers
# =====================================================================

YOUTUBE_CHANNEL_KIND = {
    # channel_id -> force kind label if you want (e.g. "ott" / "trailer")
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "ott",
    # "UCvC4D8onUfXzvjTOM-dBfEA": "trailer",
}

def youtube_rss_poll(
    channel_id: str,
    published_after: Optional[Union[str, datetime]] = None,
    max_items: int = YT_MAX_ITEMS,
) -> int:
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

        if cutoff and pub_norm and pub_norm <= cutoff:
            continue

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
            "thumb_url": None,
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
        conn.setex(mod_key, 7 * 24 * 3600, str(calendar.timegm(parsed.modified_parsed)))

    source_domain = _domain(parsed.feed.get("link") or url)

    q = Queue("events", connection=conn)
    emitted = 0

    for entry in (parsed.entries or [])[:max_items]:
        title = entry.get("title", "") or ""
        raw_link = entry.get("link") or entry.get("id") or ""
        if not raw_link:
            continue

        norm_link = to_https(abs_url(raw_link, url)) or raw_link
        src_id = _hash_link(norm_link)

        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )

        kind, _, _, _, _ = _classify(title, fallback=kind_hint)

        payload, thumb_hint, _cands = build_rss_payload(entry, url)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": thumb_hint,
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
# Manual maintenance
# =====================================================================

def backfill_repair_recent(scan: int = None) -> int:
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

        if not obj.get("ingested_at"):
            obj["ingested_at"] = obj.get("normalized_at") or now_ts
            need_save = True

        if not _has_any_image(obj):
            payload = obj.get("payload") or {}
            link = obj.get("url") or (
                payload.get("url") if isinstance(payload, dict) else None
            )
            base = link or (payload.get("feed") if isinstance(payload, dict) else "")

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

        if need_save:
            conn.lset(FEED_KEY, idx, json.dumps(obj, ensure_ascii=False))
            patched += 1
            print(f"[backfill_repair_recent] patched idx={idx} url={obj.get('url')}")

    print(f"[backfill_repair_recent] done patched={patched}")
    return patched
