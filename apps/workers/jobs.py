# apps/workers/jobs.py
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import time as _time
from datetime import datetime, timezone
from typing import Optional, Union, TypedDict, Tuple, List, Dict, Any
from urllib.parse import urlparse

import feedparser
from redis import Redis
from rq import Queue

# Use the comprehensive extractor
from apps.workers.extractors import (
    build_rss_payload,   # (payload, thumb_hint, candidates)
    abs_url, to_https,
)

__all__ = [
    "youtube_rss_poll",
    "rss_poll",
    "normalize_event",
    "backfill_repair_recent",
]

# ============================ Redis / keys ============================

def _redis() -> Redis:
    # redis://host:port/db
    return Redis.from_url(
        os.getenv("REDIS_URL", "redis://redis:6379/0"),
        decode_responses=True,
    )

# Single source of truth for the app feed LIST key.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")   # LIST, newest-first (LPUSH)
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen")    # SET of story ids for dedupe
FEED_MAX = int(os.getenv("FEED_MAX", "1200"))

# Repair/patch settings (for items inserted pre-image-extractor)
REPAIR_IF_MISSING_IMAGE = os.getenv("REPAIR_IF_MISSING_IMAGE", "1").lower() not in ("0", "", "false", "no")
REPAIR_SCAN = int(os.getenv("REPAIR_SCAN", "250"))  # how many recent items to scan to patch
REPAIR_BY_URL = os.getenv("REPAIR_BY_URL", "1").lower() not in ("0", "", "false", "no")

# Per-poller defaults
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

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)

# OTT providers (used in title classification and body detection)
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
    re.I
)

RELEASE_VERBS_RE = re.compile(
    r"\b(release[sd]?|releasing|releases|to\s+release|set\s+to\s+release|slated\s+to\s+release|opens?|opening|hits?)\b",
    re.I
)
COMING_SOON_RE = re.compile(r"\bcoming\s+soon\b", re.I)

_MONTHS = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
    "nov": 11, "november": 11, "dec": 12, "december": 12,
}
_MN = r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
DAY_MON_YR = re.compile(rf"\b(\d{{1,2}})\s+({_MN})\s*(\d{{2,4}})?\b", re.I)
MON_DAY_YR = re.compile(rf"\b({_MN})\s+(\d{{1,2}})(?:,\s*(\d{{2,4}}))?\b", re.I)
MON_YR     = re.compile(rf"\b({_MN})\s+(\d{{4}})\b", re.I)

SUMMARY_TARGET = int(os.getenv("SUMMARY_TARGET_WORDS", "85"))
SUMMARY_MIN    = int(os.getenv("SUMMARY_MIN_WORDS", "60"))
SUMMARY_MAX    = int(os.getenv("SUMMARY_MAX_WORDS", "110"))
PASSTHROUGH_MAX_WORDS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_WORDS", "120"))
PASSTHROUGH_MAX_CHARS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_CHARS", "900"))

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
_AUX_TAIL_RE = re.compile(r"\b(?:has|have|had|is|are|was|were|will|can|could|should|may|might|do|does|did)\b[\.…]*\s*$", re.I)
_SENT_SPLIT_RE = re.compile(r"(?<=[\.!?])\s+")

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

def _nearest_future(year: int, month: int, day: int | None) -> datetime:
    now = datetime.now(timezone.utc)
    d = 1 if day is None else max(1, min(28, day))
    if year < 100:
        year = 1900 + year if year >= 70 else 2000 + year
    candidate = datetime(year, month, d, tzinfo=timezone.utc)
    if candidate < now:
        if day is None or len(str(year)) <= 2:
            try:
                candidate = datetime(year + 1, month, d, tzinfo=timezone.utc)
            except ValueError:
                candidate = datetime(year + 1, month, 1, tzinfo=timezone.utc)
    return candidate

def _month_to_num(m: str) -> int | None:
    return _MONTHS.get(m.lower()[:3]) or _MONTHS.get(m.lower())

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

def _strip_html(s: str) -> str:
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

def _score_sentence(title_kw: set[str], s: str) -> int:
    overlap = len(title_kw.intersection(w.lower() for w in re.findall(r"[A-Za-z0-9]+", s)))
    verb_bonus = 1 if re.search(r"\b(is|are|was|were|has|have|had|will|to|set|announc\w+|releas\w+|premier\w+|exit\w+|walk\w+|cancel\w+|delay\w+)\b", s, re.I) else 0
    return overlap * 2 + verb_bonus

def _tidy_end(s: str) -> str:
    s = _DANGLING_ELLIPSIS_RE.sub("", s).strip()
    s = _BAD_END_WORD.sub("", s).rstrip()
    if s and s[-1] not in ".!?":
        s += "."
    return s

def _select_sentences_for_summary(title: str, body_text: str) -> str:
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
        for s in sentences:
            if len(s.split()) >= 6:
                chosen = [(0, s)]
                break
    chosen.sort(key=lambda x: x[0])
    while len(chosen) > 1:
        tail = chosen[-1][1]
        if len(tail.split()) < 8 or _AUX_TAIL_RE.search(tail):
            chosen.pop()
        else:
            break
    summary = " ".join(s for _, s in chosen).strip()
    while len(summary.split()) > SUMMARY_MAX and len(chosen) > 1:
        chosen.pop()
        summary = " ".join(s for _, s in chosen).strip()
    return _tidy_end(summary)

def _detect_ott_provider(text: str) -> Optional[str]:
    m = OTT_RE.search(text or "")
    return m.group(1) if m else None

# -------------------------- Industry tagging --------------------------

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

# ------------------- Image/link normalization helpers -----------------

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
    """Local thin wrapper to reuse extractor internals without exposing them in __all__."""
    from apps.workers.extractors import _images_from_html_block as _imgs  # type: ignore
    return _imgs(html_str, base_url)

def _pick_image_from_payload(payload: dict, base: str, thumb_hint: Optional[str]) -> Optional[str]:
    """
    Backward-compatible fallback:
    - Prefer thumb_hint (from extractor)
    - Else try feed enclosures / HTML blocks
    """
    cand: list[str] = []
    if thumb_hint:
        cand.append(thumb_hint)

    for enc in (payload.get("enclosures") or []):
        url = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if url and (typ.startswith("image/") or url.lower().split("?", 1)[0].endswith((".jpg",".jpeg",".png",".webp",".gif",".avif",".bmp",".jfif",".pjpeg"))):
            cand.append(url)

    for key in ("content_html", "description_html", "summary"):
        for u, _ in _images_from_html_block(payload.get(key), base):
            cand.append(u)

    for u in cand:
        u = to_https(abs_url(u, base))
        if u:
            return u
    return None

def _has_any_image(obj: Dict[str, Any]) -> bool:
    return bool(obj.get("image") or obj.get("thumb_url") or obj.get("thumbnail") or obj.get("poster") or obj.get("media"))

# ===================== Normalizer (writes to feed) ====================

_PATCH_FIELDS = ("image", "thumb_url", "thumbnail", "poster", "media", "image_candidates", "inline_images")

def _repair_recent_list(conn: Redis, story_new: dict) -> bool:
    """
    If we already have a recent entry (matching id OR url) that lacks an image,
    patch it in place. Returns True if a patch was performed.
    """
    if not REPAIR_IF_MISSING_IMAGE:
        return False
    if not _has_any_image(story_new):
        return False

    new_id = story_new.get("id")
    new_url = story_new.get("url")
    window = conn.lrange(FEED_KEY, 0, max(REPAIR_SCAN - 1, 0))

    for idx, raw in enumerate(window):
        try:
            obj = json.loads(raw)
        except Exception:
            continue

        same = (new_id and obj.get("id") == new_id)
        if not same and REPAIR_BY_URL and new_url and obj.get("url") == new_url:
            same = True

        if not same:
            continue

        if _has_any_image(obj):
            return False  # already has an image

        patched = obj.copy()
        # keep existing ingested_at (first-seen) if present
        patched["ingested_at"] = obj.get("ingested_at") or story_new.get("ingested_at") or obj.get("normalized_at")

        for k in _PATCH_FIELDS:
            if story_new.get(k) is not None:
                patched[k] = story_new[k]

        # refresh normalized_at to mark repair time
        patched["normalized_at"] = story_new.get("normalized_at") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        conn.lset(FEED_KEY, idx, json.dumps(patched, ensure_ascii=False))
        print(f"[normalize_event] REPAIR -> {new_id or new_url} (added image, preserved ingested_at={patched.get('ingested_at')})")
        return True

    return False

def normalize_event(event: AdapterEventDict) -> dict:
    """
    Converts adapter events into the canonical feed shape and appends to the Redis LIST (newest-first).
    Dedupes on <source>:<source_event_id>. Also attempts in-place patch of duplicates missing an image.
    """
    conn = _redis()

    source = (event.get("source") or "src").strip()
    src_id = (event.get("source_event_id") or "").strip()
    story_id = f"{source}:{src_id}".strip(":")
    title = (event.get("title") or "").strip()

    base_fallback = (event.get("kind") or "news").strip()
    kind, rd_iso, provider_from_title, is_theatrical, is_upcoming = _classify(title, fallback=base_fallback)

    published_at = _to_rfc3339(event.get("published_at"))
    payload = event.get("payload") or {}

    # Build canonical link + domain + raw text
    if source == "youtube":
        link = payload.get("watch_url") or (f"https://www.youtube.com/watch?v={src_id}" if src_id else None)
        source_domain = "youtube.com"
        desc = payload.get("description") or ""
        raw_text = _strip_html(desc)
        ott_platform = provider_from_title or _detect_ott_provider(f"{title}\n{desc}")
        thumb_hint = event.get("thumb_url") or _youtube_thumb(link)
    else:
        link = payload.get("url")
        source_domain = _domain(link or source.replace("rss:", ""))
        raw_html = payload.get("content_html") or payload.get("description_html") or ""
        raw_sum = payload.get("summary") or ""
        body = raw_html or raw_sum
        raw_text = _strip_html(body)
        ott_platform = provider_from_title
        thumb_hint = event.get("thumb_url")

    # Normalize link/base
    link = to_https(abs_url(link, payload.get("feed") or link or "")) or ""
    base_for_imgs = link or (payload.get("feed") or "")

    # Resolve dependable image (prefer extractor's thumb_hint; then fallback)
    image_url = _pick_image_from_payload(payload, base_for_imgs, thumb_hint)
    if not image_url and source == "youtube":
        image_url = _youtube_thumb(link)

    summary_text = _select_sentences_for_summary(title, raw_text)
    tags = _industry_tags(source, source_domain, title, raw_text, payload)

    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    story = {
        "id": story_id,
        "kind": kind,
        "title": title,
        "summary": summary_text or None,
        "published_at": published_at,        # source publish time
        "source": source,
        "thumb_url": image_url or thumb_hint,
        "release_date": rd_iso,
        "is_theatrical": True if is_theatrical else None,
        "is_upcoming": True if is_upcoming else None,

        # NEW: first-seen time (immutable on subsequent repairs) + current normalization time
        "ingested_at": now_ts,
        "normalized_at": now_ts,

        "url": link or None,
        "source_domain": source_domain,
        "ott_platform": ott_platform,
        "tags": tags or None,
        # canonical image fields
        "image": image_url,
        "thumbnail": image_url,
        "poster": image_url,
        "media": image_url,
        # transparency
        "enclosures": payload.get("enclosures") or None,
        "image_candidates": payload.get("image_candidates") or None,
        "inline_images": payload.get("inline_images") or None,
    }

    # Deduplicate OR repair
    if conn.sadd(SEEN_KEY, story_id):
        pipe = conn.pipeline()
        pipe.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
        pipe.ltrim(FEED_KEY, 0, FEED_MAX - 1)
        pipe.execute()
        print(f"[normalize_event] NEW  -> {story_id} | {title}")
        return story

    # Duplicate: try to repair if existing lacks image (match by id or url)
    if _repair_recent_list(conn, story):
        return story

    print(f"[normalize_event] SKIP -> {story_id} (duplicate)")
    return story

# ========================== YouTube poller ===========================

YOUTUBE_CHANNEL_KIND = {
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

        ch_kind = YOUTUBE_CHANNEL_KIND.get(channel_id)
        if ch_kind:
            kind = ch_kind
        else:
            kind = "trailer" if TRAILER_RE.search(title) else "ott" if OTT_RE.search(title) else "news"

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
            "thumb_url": None,  # compute in normalize if missing
            "payload": {
                "channelId": channel_id,
                "videoId": vid,
                "description": yt_desc,
                "watch_url": watch_url,
            },
        }

        jid = _safe_job_id("normalize", ev["source"], ev["source_event_id"])
        Queue("events", connection=conn).enqueue(
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
        raw_link = entry.get("link") or entry.get("id") or ""
        if not raw_link:
            continue

        # Normalize link before hashing to unify duplicates
        norm_link = to_https(abs_url(raw_link, url)) or raw_link
        src_id = _hash_link(norm_link)

        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )

        # classify with hint as fallback
        kind, _, _, _, _ = _classify(title, fallback=kind_hint)

        # COMPREHENSIVE extraction (payload + thumb_hint)
        payload, thumb_hint, _cands = build_rss_payload(entry, url)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": thumb_hint,  # normalizer prefers this first
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

# ======================= Backfill/repair helper ======================

def backfill_repair_recent(scan: int = None) -> int:
    """
    Best-effort pass over recent FEED_KEY items:
    - Ensure 'ingested_at' exists (use prior normalized_at or now).
    - For entries missing an image, try to rebuild image from stored payload using extractor and patch in place.
    Returns number of patched items (image set and/or ingested_at added).
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

        # Ensure a stable first-seen timestamp
        if not obj.get("ingested_at"):
            obj["ingested_at"] = obj.get("normalized_at") or now_ts
            need_save = True

        if not _has_any_image(obj):
            payload = obj.get("payload") or {}
            link = obj.get("url") or (payload.get("url") if isinstance(payload, dict) else None)
            base = link or (payload.get("feed") if isinstance(payload, dict) else "")

            # Try extractor again with whatever we have
            if isinstance(payload, dict) and payload:
                thumb = _pick_image_from_payload(
                    payload,
                    base,
                    payload.get("image_candidates", [None])[0] if isinstance(payload.get("image_candidates"), list) else None
                )
            else:
                thumb = None

            if not thumb and link:
                # construct minimal entry to re-extract (may probe OG/AMP)
                dummy_entry = {
                    "link": link,
                    "summary": obj.get("summary") or "",
                    "description": payload.get("description_html") if isinstance(payload, dict) else "",
                    "content": [{"type": "text/html", "value": payload.get("content_html") if isinstance(payload, dict) else ""}],
                }
                new_payload, thumb_hint, _ = build_rss_payload(dummy_entry, payload.get("feed") if isinstance(payload, dict) else "")
                payload = {**payload, **new_payload} if isinstance(payload, dict) else new_payload
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
