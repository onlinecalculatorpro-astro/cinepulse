# apps/sanitizer/sanitizer.py
#
# ROLE IN PIPELINE (runs in the "sanitize" RQ worker):
#
#   scheduler  → polls sources and enqueues ingest jobs
#
#   workers    → normalize_event() builds a canonical story dict:
#                 - title, summary (already cleaned / professional tone ~100 words)
#                 - kind, kind_meta (trailer / release / ott / news, etc.)
#                 - verticals (["entertainment"], ["sports"], ...)
#                 - tags (industry, ott, box-office, etc.)
#                 - hero image fields (thumb_url/image/...)
#                 - timestamps
#               and enqueues sanitize_story(story) on the "sanitize" queue
#
#   sanitizer  → THIS FILE
#               - final gatekeeper for the public feed:
#                   * ROBUST dedupe with fuzzy matching (first version wins forever)
#                   * write to Redis FEED_KEY
#                   * trim FEED_KEY
#                   * broadcast realtime + optional push notification
#
#   api        → /v1/feed reads FEED_KEY (newest-first list in Redis)
#                and supports /v1/feed?vertical=sports etc. by inspecting story["verticals"]
#
# IMPORTANT PIPELINE RULES:
# - workers DO NOT write to FEED_KEY
# - workers DO NOT dedupe
# - sanitizer is the ONLY thing that can publish to FEED_KEY
#
# ENHANCED DEDUPE STRATEGY (ROBUST TOPIC SIGNATURE):
# 1. Clean title and summary (lowercase, remove hype like "BREAKING",
#    strip punctuation/emojis, drop "read more at ...").
# 2. Extract and NORMALIZE meaningful keywords:
#       - stem verbs: "announces"/"announced"/"announcing" → "announce"
#       - normalize names: "salmankhan" → "salman khan", "srk" → "shahrukh khan"
#       - collapse multi-word entities: "bigg boss 19" → "biggboss19"
#       - semantic equivalents: "teaser"/"promo" → "trailer"
#       - keep "day5"/"day-5" tokens (so Day 5 box office != Day 6)
#       - drop glue words ("the", "and", "to", etc.)
#       - drop raw numeric money tokens ("505cr", "120cr") that change hourly
# 3. Sort + dedupe those keywords → stable "topic fingerprint".
# 4. Fuzzy match against existing topics (80% token overlap = duplicate).
#
# - We store topic blobs in Redis hash SEEN_KEY (sig → topic_blob).
# - If we see a similar topic again (80%+ keyword overlap), it's "duplicate".
# - We never "upgrade" an older story in-place. First accepted story wins.
#
# sanitize_story() returns:
#   "accepted"   -> published
#   "duplicate"  -> dropped (topic already covered)
#   "invalid"    -> dropped (no canonical title / unusable)
#
# ENV VARS:
#   REDIS_URL, FEED_KEY, SEEN_KEY, MAX_FEED_LEN
#   FEED_PUBSUB, FEED_STREAM, FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS
#   FALLBACK_VERTICAL (default "entertainment")
#   DUPLICATE_SIMILARITY_THRESHOLD (default 0.80)

from __future__ import annotations

import os
import re
import json
import hashlib
from datetime import datetime, timezone
from typing import Dict, Any, Literal, Optional, List

from redis import Redis
from rq import Queue


__all__ = [
    "sanitize_story",
    "canonical_title",
    "canonical_summary",
    "story_signature",
]

# ------------------------------------------------------------------------------
# Env / Redis config
# ------------------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed LIST that /v1/feed will read newest-first.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Redis HASH of dedupe topic blobs for accepted stories (sig → topic_blob).
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Feed length cap (0 or negative means "never trim").
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))

# Realtime fanout targets.
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
FEED_STREAM_MAXLEN = int(os.getenv("FEED_STREAM_MAXLEN", "5000"))

# Optional push notifications toggle.
ENABLE_PUSH_NOTIFICATIONS = os.getenv("ENABLE_PUSH_NOTIFICATIONS", "0").lower() not in (
    "0",
    "",
    "false",
    "no",
)

# Vertical fallback (workers should already set story["verticals"], but just in case).
FALLBACK_VERTICAL = os.getenv("FALLBACK_VERTICAL", "entertainment")

# Fuzzy duplicate detection threshold (0.80 = 80% keyword overlap).
DUPLICATE_SIMILARITY_THRESHOLD = float(
    os.getenv("DUPLICATE_SIMILARITY_THRESHOLD", "0.80")
)


def _redis() -> Redis:
    """
    Redis client for:
      - dedupe hash (SEEN_KEY)
      - feed list writes
      - pub/sub + stream fanout
      - optional push enqueue
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # return str not bytes
    )


# ------------------------------------------------------------------------------
# Canonicalization + ROBUST topic-signature helpers for dedupe
# ------------------------------------------------------------------------------

# High-drama / hype / filler words that shouldn't define uniqueness.
_STOPWORDS = {
    "breaking",
    "exclusive",
    "watch",
    "watchnow",
    "watch now",
    "teaser",
    "trailer",
    "first",
    "look",
    "first look",
    "firstlook",
    "revealed",
    "reveal",
    "official",
    "officially",
    "now",
    "just",
    "out",
    "finally",
    "drops",
    "dropped",
    "drop",
    "release",
    "released",
    "leak",
    "leaked",
    "update",
    "updates",
    "announced",
    "announces",
    "announcing",
    "confirms",
    "confirmed",
    "confirm",
    "big",
    "huge",
    "massive",
    "viral",
    "shocking",
    "omg",
    "🔥",
    # box-office hype-y words that repeat every day
    "box",
    "office",
    "collection",
    "collections",
    "day",
    "opening",
    "weekend",
}

# Extremely common glue words we don't want to make two stories "different".
_COMMON_STOPWORDS = {
    "the", "a", "an", "this", "that", "and", "or", "but", "if", "so",
    "to", "for", "of", "on", "in", "at", "by", "with", "as", "from",
    "about", "after", "before", "over", "under", "it", "its", "his",
    "her", "their", "they", "you", "your", "we", "our", "is", "are",
    "was", "were", "be", "been", "being", "will", "can", "could",
    "should", "may", "might", "have", "has", "had", "do", "does",
    "did", "not", "no", "yes",
}

# Footer-ish junk to strip from summaries before hashing.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# Anything not alphanumeric / dash / whitespace → space.
_CLEAN_RE = re.compile(r"[^a-z0-9\s-]+", re.IGNORECASE)

# Tokens like "day5", "day-5", "day_5" etc.
# We WANT those to survive because "Day 5 box office" vs "Day 6 box office"
# are separate beats.
_DAY_TOKEN_RE = re.compile(r"^day[-_]?(\d{1,2})$", re.I)

# Tokens that are basically just numbers / money / raw numeric.
# We DROP these so tiny ₹ deltas don't create new topics, unless it's a dayN token.
_NUMERICY_RE = re.compile(r"^\d+[a-z]*$", re.I)

# ------------------------------------------------------------------------------
# NORMALIZATION DICTIONARIES (verb stemming, name normalization, semantic equiv)
# ------------------------------------------------------------------------------

# Simple verb/noun stemming rules for entertainment/sports news
_VERB_STEMS = {
    # action verbs
    "announcing": "announce",
    "announces": "announce",
    "announced": "announce",
    "confirming": "confirm",
    "confirms": "confirm",
    "confirmed": "confirm",
    "revealing": "reveal",
    "reveals": "reveal",
    "revealed": "reveal",
    "dropping": "drop",
    "drops": "drop",
    "dropped": "drop",
    "releasing": "release",
    "releases": "release",
    "released": "release",
    "joining": "join",
    "joins": "join",
    "joined": "join",
    "starring": "star",
    "stars": "star",
    "starred": "star",
    "streaming": "stream",
    "streams": "stream",
    "streamed": "stream",
    "earning": "earn",
    "earns": "earn",
    "earned": "earn",
    "collecting": "collect",
    "collects": "collect",
    "collected": "collect",
    "grossing": "gross",
    "grosses": "gross",
    "grossed": "gross",
    "making": "make",
    "makes": "make",
    "made": "make",
    # common plurals
    "trailers": "trailer",
    "teasers": "teaser",
    "films": "film",
    "movies": "movie",
    "shows": "show",
}

# Common name variations in entertainment/sports
_NAME_NORMALIZE = {
    # Bollywood
    "salmankhan": "salman",
    "srk": "shahrukh",
    "shahrukhkhan": "shahrukh",
    "ranbir": "ranbir",
    "ranbirkapoor": "ranbir",
    "alia": "alia",
    "aliabhatt": "alia",
    "vicky": "vicky",
    "vickykaushal": "vicky",
    "ranveer": "ranveer",
    "ranveersingh": "ranveer",
    "deepika": "deepika",
    "deepikapadukone": "deepika",
    "katrina": "katrina",
    "katrinakaif": "katrina",
    "hrithik": "hrithik",
    "hrithikroshan": "hrithik",
    "priyanka": "priyanka",
    "priyankachopra": "priyanka",
    "aamir": "aamir",
    "aamirkhan": "aamir",
    "akshay": "akshay",
    "akshaykumar": "akshay",
    "ajay": "ajay",
    "ajaydevgn": "ajay",
    # Sports
    "virat": "virat",
    "viratkohli": "virat",
    "dhoni": "dhoni",
    "msdhoni": "dhoni",
    "rohit": "rohit",
    "rohitsharma": "rohit",
    "sachin": "sachin",
    "sachintendulkar": "sachin",
    # IPL teams
    "rcb": "bangalore",
    "csk": "chennai",
    "mi": "mumbai",
    "kkr": "kolkata",
    "dc": "delhi",
    "rr": "rajasthan",
    "pbks": "punjab",
    "srh": "hyderabad",
    "gt": "gujarat",
    "lsg": "lucknow",
}

# Words that mean the same thing in context
_SEMANTIC_EQUIV = {
    "teaser": "trailer",
    "promo": "trailer",
    "glimpse": "trailer",
    "sneak": "trailer",
    "peek": "trailer",
    "preview": "trailer",
    "ott": "streaming",
    "digital": "streaming",
    "online": "streaming",
    "theatrical": "cinema",
    "theater": "cinema",
    "theatre": "cinema",
    "earns": "collect",
    "grosses": "collect",
    "makes": "collect",
    "earnings": "collection",
    "gross": "collection",
}

# Known multi-word entities to collapse
_KNOWN_ENTITIES = {
    "biggboss",
    "lovewar",
    "pushpa",
    "kgf",
    "rrr",
    "pathaan",
    "jawan",
    "dunki",
    "animal",
    "fighter",
    "badeميyan",
    "chhotemiyan",
    "singham",
    "golmaal",
    "housefull",
    "racetrack",
    "boxoffice",
    "ottrelease",
    "primeminister",
}


def _stem_token(word: str) -> str:
    """Normalize verb tenses and common plurals."""
    return _VERB_STEMS.get(word.lower(), word.lower())


def _normalize_name(word: str) -> str:
    """Expand/normalize common name abbreviations."""
    return _NAME_NORMALIZE.get(word.lower(), word.lower())


def _semantic_normalize(word: str) -> str:
    """Map semantically equivalent words to canonical form."""
    return _SEMANTIC_EQUIV.get(word.lower(), word.lower())


def _collapse_multi_word_entities(tokens: List[str]) -> List[str]:
    """
    Merge adjacent tokens that form known entities.
    "bigg boss 19" → "biggboss19"
    "love and war" → "lovewar"
    "pushpa 2" → "pushpa2"
    """
    result = []
    i = 0
    while i < len(tokens):
        # Check for "word1 word2 number" pattern (show/movie with season/part)
        if i + 2 < len(tokens) and tokens[i + 2].isdigit():
            two_word = tokens[i] + tokens[i + 1]
            if two_word in _KNOWN_ENTITIES:
                entity = two_word + tokens[i + 2]
                result.append(entity)
                i += 3
                continue

        # Check for "word1 word2" pattern (2-word names/titles)
        if i + 1 < len(tokens):
            two_word = tokens[i] + tokens[i + 1]
            if two_word in _KNOWN_ENTITIES:
                result.append(two_word)
                i += 2
                continue

        result.append(tokens[i])
        i += 1

    return result


def _strip_noise_words(words: List[str]) -> List[str]:
    """
    Remove hype/filler/CTA-ish words from a token list.
    """
    keep: List[str] = []
    for w in words:
        lw = w.strip().lower()
        if not lw:
            continue
        if lw in _STOPWORDS:
            continue
        keep.append(lw)
    return keep


def canonical_title(raw_title: str) -> str:
    """
    Lowercase, remove punctuation/emojis, drop hype-y STOPWORDS, collapse whitespace.
    If this ends up empty, we treat story as not uniquely identifiable.
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: Optional[str]) -> str:
    """
    Clean summary:
    - Strip "read full story..." style tails.
    - Lowercase.
    - Remove punctuation/emojis.
    - Drop hype/filler STOPWORDS.
    - Collapse whitespace.
    """
    if not raw_summary:
        return ""

    s = raw_summary.lower()

    for pat in _SUMMARY_FOOTER_PATTERNS:
        s = re.sub(pat, "", s, flags=re.IGNORECASE | re.MULTILINE)

    s = _CLEAN_RE.sub(" ", s)
    words = s.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def _keywords_for_signature(canon_title: str, canon_summary: str) -> List[str]:
    """
    Turn cleaned title+summary into NORMALIZED bag of keywords.

    Improvements over basic approach:
    - Stem verbs: "announces"/"announced"/"announcing" → "announce"
    - Normalize names: "salmankhan" → "salman", "srk" → "shahrukh"
    - Collapse multi-word entities: "bigg boss 19" → "biggboss19"
    - Map semantic equivalents: "teaser"/"promo" → "trailer"
    - Keep "day5" tokens (Day 5 vs Day 6 are different)
    - Drop pure numbers and glue words
    """
    blob = f"{canon_title} {canon_summary}".strip()
    tokens = blob.split()

    # Phase 1: Basic filtering + normalization
    normalized = []
    for tok in tokens:
        t = tok.strip().lower()
        if not t:
            continue

        # Drop glue words
        if t in _COMMON_STOPWORDS:
            continue

        # Always keep day tokens
        if _DAY_TOKEN_RE.match(t):
            normalized.append(t)
            continue

        # Drop pure numbers
        if _NUMERICY_RE.match(t):
            continue

        # Apply all normalizations
        t = _stem_token(t)
        t = _normalize_name(t)
        t = _semantic_normalize(t)

        normalized.append(t)

    # Phase 2: Collapse multi-word entities
    collapsed = _collapse_multi_word_entities(normalized)

    return collapsed


def _build_topic_signature_blob(canon_title: str, canon_summary: str) -> str:
    """
    Build a "topic fingerprint" string:
      - extract filtered + normalized keywords
      - dedupe them
      - sort them alphabetically so word order changes don't matter
    """
    kw = _keywords_for_signature(canon_title, canon_summary)

    if not kw:
        # Fallback to canonical text itself if we got nothing useful.
        base = f"title:{canon_title}||summary:{canon_summary}".strip()
        return base

    uniq_sorted = sorted(set(kw))
    return " ".join(uniq_sorted).strip()


def _are_topics_similar(topic_blob1: str, topic_blob2: str) -> bool:
    """
    Check if two topic blobs are similar enough to be considered duplicates.
    Uses token overlap ratio (Jaccard similarity).

    Returns True if overlap >= DUPLICATE_SIMILARITY_THRESHOLD (default 80%).
    """
    tokens1 = set(topic_blob1.split())
    tokens2 = set(topic_blob2.split())

    if not tokens1 or not tokens2:
        return False

    overlap = len(tokens1 & tokens2)
    smaller = min(len(tokens1), len(tokens2))

    if smaller == 0:
        return False

    similarity = overlap / smaller
    return similarity >= DUPLICATE_SIMILARITY_THRESHOLD


def story_signature(title: str, summary: Optional[str]) -> str:
    """
    Produce a short deterministic signature for dedupe based on TOPIC,
    not exact wording.

    Steps:
      1. canonicalize title + summary (remove hype, junk)
      2. extract + normalize topic keywords (stem, name normalize, etc.)
      3. sort + dedupe keywords into a stable blob
      4. sha1(blob)[0:16]

    If canonical title is empty, return "" → invalid story.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    if not canon_t:
        return ""

    topic_blob = _build_topic_signature_blob(canon_t, canon_s)
    digest = hashlib.sha1(topic_blob.encode("utf-8")).hexdigest()
    return digest[:16]


# ------------------------------------------------------------------------------
# Helpers to finalize the story object before we publish
# ------------------------------------------------------------------------------


def _now_utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_verticals(story: Dict[str, Any]) -> None:
    """
    Workers should already attach something like ["entertainment"] or ["sports"].
    If it's missing or empty, fall back so /v1/feed?vertical= still works.
    Also normalize to list[str] of non-empty slugs.
    """
    verts = story.get("verticals")
    if not isinstance(verts, list):
        verts = []
    verts = [v.strip() for v in verts if isinstance(v, str) and v.strip()]
    if not verts:
        verts = [FALLBACK_VERTICAL]
    story["verticals"] = verts


def _ensure_thumb_url(story: Dict[str, Any]) -> None:
    """
    Frontend expects a hero image. Workers try to pick one, but in case
    thumb_url is missing, fall back to any of the known artwork keys.
    """
    if story.get("thumb_url"):
        return
    for k in ("image", "poster", "thumbnail", "media", "poster_url"):
        v = story.get(k)
        if v:
            story["thumb_url"] = v
            return


def _build_kind_meta_fallback(
    kind: str,
    ott_platform: Optional[str],
    is_theatrical: Any,
    is_upcoming: Any,
    release_date: Optional[str],
) -> Dict[str, Any]:
    """
    Workers SHOULD send story["kind_meta"], but if they somehow didn't,
    create a minimal structure so the frontend has badges/chips.
    """
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
            "release_date": release_date,
        }

    return {
        "kind": "news",
        "is_breaking": False,
    }


def _ensure_kind_meta(story: Dict[str, Any]) -> None:
    """
    Guarantee story["kind_meta"] exists.
    """
    if story.get("kind_meta"):
        return

    story["kind_meta"] = _build_kind_meta_fallback(
        kind=story.get("kind", "news"),
        ott_platform=story.get("ott_platform"),
        is_theatrical=story.get("is_theatrical"),
        is_upcoming=story.get("is_upcoming"),
        release_date=story.get("release_date"),
    )


def _ensure_timestamps(story: Dict[str, Any]) -> None:
    """
    We want normalized_at and ingested_at for clients / realtime fanout.
    If workers forgot them, patch them here.
    """
    if not story.get("normalized_at"):
        story["normalized_at"] = _now_utc_iso()
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]


def _add_frontend_aliases(story: Dict[str, Any]) -> None:
    """
    Duplicate important snake_case fields into camelCase keys that
    the Flutter app expects. We do this before LPUSH so Redis already
    stores an app-ready object.

    Frontend cares about:
      publishedAt / ingestedAt / normalizedAt
      releaseDate / isTheatrical / isUpcoming
      ottPlatform / sourceDomain
      thumbUrl / posterUrl
    """
    # timestamps
    if "published_at" in story and "publishedAt" not in story:
        story["publishedAt"] = story["published_at"]
    if "ingested_at" in story and "ingestedAt" not in story:
        story["ingestedAt"] = story["ingested_at"]
    if "normalized_at" in story and "normalizedAt" not in story:
        story["normalizedAt"] = story["normalized_at"]

    # release info
    if "release_date" in story and "releaseDate" not in story:
        story["releaseDate"] = story["release_date"]
    if "is_theatrical" in story and "isTheatrical" not in story:
        story["isTheatrical"] = story["is_theatrical"]
    if "is_upcoming" in story and "isUpcoming" not in story:
        story["isUpcoming"] = story["is_upcoming"]

    # OTT / platform info
    if "ott_platform" in story and "ottPlatform" not in story:
        story["ottPlatform"] = story["ott_platform"]

    # source domain
    if "source_domain" in story and "sourceDomain" not in story:
        story["sourceDomain"] = story["source_domain"]

    # hero art
    # workers populate thumb_url & poster_url; alias them so Flutter can
    # read story.posterUrl / story.thumbUrl directly.
    if "thumb_url" in story and "thumbUrl" not in story:
        story["thumbUrl"] = story["thumb_url"]
    if "poster_url" in story and "posterUrl" not in story:
        story["posterUrl"] = story["poster_url"]
    # Safety: if posterUrl is still missing but we have thumbUrl, mirror it
    if "posterUrl" not in story and story.get("thumbUrl"):
        story["posterUrl"] = story["thumbUrl"]


def _finalize_story_shape(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Mutates + returns story.
    This is exactly what we LPUSH to Redis and broadcast.
    """
    _ensure_verticals(story)
    _ensure_thumb_url(story)
    _ensure_kind_meta(story)
    _ensure_timestamps(story)

    # normalize tags to list[str] OR None
    tags_val = story.get("tags")
    if isinstance(tags_val, list):
        story["tags"] = [t for t in tags_val if isinstance(t, str) and t.strip()] or None
    elif tags_val is None:
        story["tags"] = None
    else:
        story["tags"] = None

    # add camelCase mirrors so Flutter can bind directly
    _add_frontend_aliases(story)

    return story


# ------------------------------------------------------------------------------
# Realtime fanout + optional push
# ------------------------------------------------------------------------------


def _publish_realtime(conn: Redis, story: Dict[str, Any]) -> None:
    """
    Broadcast minimal info about a NEW story to downstream listeners.
    We send:
      - Pub/Sub payload (JSON)
      - XADD append into FEED_STREAM (capped length) for dashboards/logging
    """
    try:
        payload = {
            "id": story.get("id"),
            "kind": story.get("kind"),
            "verticals": story.get("verticals"),
            "normalized_at": story.get("normalized_at"),
            "ingested_at": story.get("ingested_at"),
            "title": story.get("title"),
            "source": story.get("source"),
            "source_domain": story.get("source_domain"),
            "url": story.get("url"),
            "thumb_url": story.get("thumb_url"),
        }

        # Pub/Sub for websockets or live dashboards
        conn.publish(FEED_PUBSUB, json.dumps(payload, ensure_ascii=False))

        # Capped stream for tailing / dashboards
        try:
            conn.xadd(
                FEED_STREAM,
                {
                    "id": str(payload.get("id") or ""),
                    "kind": str(payload.get("kind") or ""),
                    "ts": str(payload.get("normalized_at") or ""),
                },
                maxlen=FEED_STREAM_MAXLEN,
                approximate=True,
            )
        except Exception:
            # Stream failure shouldn't block publish
            pass

    except Exception as e:
        print(f"[sanitizer] realtime publish error: {e}")


def _enqueue_push(conn: Redis, story: Dict[str, Any]) -> None:
    """
    Optionally enqueue a downstream push notification job.
    That worker is out-of-scope here.
    """
    if not ENABLE_PUSH_NOTIFICATIONS:
        return

    try:
        Queue("push", connection=conn).enqueue(
            "apps.workers.push.send_story_push",
            story,
            ttl=600,
            result_ttl=60,
            failure_ttl=600,
            job_timeout=30,
        )
    except Exception as e:
        print(f"[sanitizer] push enqueue error: {e}")


# ------------------------------------------------------------------------------
# RQ job entrypoint
# ------------------------------------------------------------------------------


def sanitize_story(
    story: Dict[str, Any]
) -> Literal["accepted", "duplicate", "invalid"]:
    """
    Runs inside the "sanitize" queue worker.

    Flow:
      1. Build NORMALIZED topic-based signature from (title, summary).
      2. Check fuzzy similarity against all existing topics in Redis.
      3. If 80%+ similar to any existing topic -> "duplicate".
      4. Else:
           - store topic blob in Redis hash (so future dupes get caught),
           - finalize the story (verticals, thumb, timestamps, aliases),
           - LPUSH to FEED_KEY,
           - TRIM FEED_KEY,
           - broadcast realtime,
           - maybe push.
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # 1. Build canonical + topic signature
    canon_t = canonical_title(raw_title)
    canon_s = canonical_summary(raw_summary)

    if not canon_t:
        print(
            f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}"
        )
        return "invalid"

    topic_blob = _build_topic_signature_blob(canon_t, canon_s)
    sig = hashlib.sha1(topic_blob.encode("utf-8")).hexdigest()[:16]

    # 2. Fuzzy dedupe check against existing topics
    try:
        existing_topics = conn.hgetall(SEEN_KEY)  # hash: sig → topic_blob
    except Exception as e:
        print(f"[sanitizer] ERROR reading SEEN_KEY: {e}")
        existing_topics = {}

    for existing_sig, existing_blob in existing_topics.items():
        if _are_topics_similar(topic_blob, existing_blob):
            print(
                f"[sanitizer] DUPLICATE (
                f"[sanitizer] DUPLICATE (similar to {existing_sig}) -> {story.get('id')} | {raw_title}"
            )
            return "duplicate"

    # 3a. Mark topic blob so future duplicates are caught
    try:
        conn.hset(SEEN_KEY, sig, topic_blob)
    except Exception as e:
        print(f"[sanitizer] ERROR storing signature {sig}: {e}")

    # 3b. Finalize story shape so feed/api get consistent + Flutter-ready fields
    story = _finalize_story_shape(story)

    # 3c. LPUSH newest-first story JSON into the public feed list
    try:
        conn.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
    except Exception as e:
        print(f"[sanitizer] ERROR LPUSH feed for {story.get('id')}: {e}")

    # 3d. Trim feed length cap
    if MAX_FEED_LEN > 0:
        try:
            conn.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)
        except Exception as e:
            print(f"[sanitizer] ERROR LTRIM feed: {e}")

    # 4. Broadcast + maybe push
    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"


                
