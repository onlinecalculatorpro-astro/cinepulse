# apps/sanitizer/sanitizer.py
#
# ROLE IN PIPELINE (runs in the "sanitize" RQ worker):
#
#   scheduler  → polls sources and enqueues ingest jobs
#
#   workers    → normalize_event() builds a canonical story dict and enqueues
#                 sanitize_story(story) on the "sanitize" queue.
#               worker story dict should ALREADY be safe:
#                 - title (generate_safe_title)
#                 - summary (summarize_story_safe)
#                 - kind / kind_meta (trailer / release / ott / news)
#                 - verticals (["entertainment"], ["sports"], ...)
#                 - tags (industry, ott, box-office, match-result, etc.)
#                 - hero image urls (thumb_url/image/...)
#                 - timestamps
#                 - safety flags:
#                       story["is_risky"]     -> True if legal/PR heat (raids, FIR, etc.)
#                       story["gossip_only"]  -> True if it's only personal drama
#
#   sanitizer  → THIS FILE
#               - final gatekeeper for the public feed:
#                   * reject pure gossip ("gossip_only" True) so we don't publish
#                     leaked DMs / breakup rumors with no business/release context
#                   * dedupe: topic-level fuzzy dedupe (first win is canonical)
#                     using a robust topic signature
#                   * write accepted story to Redis FEED_KEY
#                   * trim FEED_KEY
#                   * broadcast realtime
#                   * (optional) enqueue push notification
#
#   api        → /v1/feed reads FEED_KEY (newest-first Redis LIST)
#                and supports /v1/feed?vertical=sports, etc., using story["verticals"]
#
# HARD RULES:
# - workers NEVER write to FEED_KEY
# - workers NEVER dedupe
# - sanitizer is the ONLY publisher to FEED_KEY
#
# DEDUPE STRATEGY (topic signature):
# 1. Canonicalize title+summary:
#       - lowercase
#       - strip hype like "BREAKING", "WATCH NOW"
#       - strip punctuation/emojis
#       - strip promo footers ("read more at ...")
# 2. Token normalize:
#       - stem verbs ("announced"/"announces"/"announcing" → "announce")
#       - normalize common names ("srk" → "shahrukh", "salmankhan" → "salman")
#       - map teaser/promo/sneak peek → "trailer"
#       - collapse multi-word entities ("bigg boss 19" → "biggboss19")
#       - keep "day5"/"day-5" tokens (so Day 5 BO != Day 6 BO)
#       - drop noisy glue words ("the", "and", "to", ...)
#       - drop raw money/number tokens ("120cr", "505cr") so hourly box office bumps
#         don't spam new cards
# 3. Sort + dedupe those normalized tokens → "topic_blob".
# 4. Fuzzy match topic_blob against previous blobs from Redis:
#       - if ≥ DUPLICATE_SIMILARITY_THRESHOLD (default 0.80), treat as duplicate
#         and DO NOT publish again.
#
# Redis keys:
#   FEED_KEY  : Redis LIST (newest first). Each element is final story JSON dict.
#   SEEN_KEY  : Redis HASH (sig -> topic_blob) of accepted stories for dedupe.
#
# sanitize_story() returns:
#   "accepted"   -> published to feed
#   "duplicate"  -> dropped as already covered
#   "invalid"    -> dropped (gossip_only, or unusable/no canonical title)
#
# ENV VARS:
#   REDIS_URL
#   FEED_KEY
#   SEEN_KEY
#   MAX_FEED_LEN
#   FEED_PUBSUB
#   FEED_STREAM
#   FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS
#   FALLBACK_VERTICAL (default "entertainment")
#   DUPLICATE_SIMILARITY_THRESHOLD (default "0.80")

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

# =============================================================================
# Env / Redis config
# =============================================================================

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed LIST that /v1/feed reads newest-first.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Redis HASH of dedupe topic blobs for accepted stories (sig → topic_blob).
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Max number of stories we keep in FEED_KEY. <=0 means "no trim".
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

# Vertical fallback if workers forget. Keeps /v1/feed?vertical= working.
FALLBACK_VERTICAL = os.getenv("FALLBACK_VERTICAL", "entertainment")

# Fuzzy duplicate threshold: 0.80 → 80% token overlap means "same topic".
DUPLICATE_SIMILARITY_THRESHOLD = float(
    os.getenv("DUPLICATE_SIMILARITY_THRESHOLD", "0.80")
)


def _redis() -> Redis:
    """
    Create a Redis client for:
      - dedupe topic HASH (SEEN_KEY)
      - public feed LIST (FEED_KEY)
      - pub/sub + stream fanout
      - optional push enqueue
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # return str instead of bytes
    )


# =============================================================================
# Canonicalization / topic-signature helpers for dedupe
# =============================================================================

# Words that are hypey / promo / repetitive noise and shouldn't define a new topic.
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
    # box-office hype terms that repeat daily
    "box",
    "office",
    "collection",
    "collections",
    "day",
    "opening",
    "weekend",
}

# High-frequency glue words we always toss.
_COMMON_STOPWORDS = {
    "the", "a", "an", "this", "that", "and", "or", "but", "if", "so",
    "to", "for", "of", "on", "in", "at", "by", "with", "as", "from",
    "about", "after", "before", "over", "under", "it", "its", "his",
    "her", "their", "they", "you", "your", "we", "our", "is", "are",
    "was", "were", "be", "been", "being", "will", "can", "could",
    "should", "may", "might", "have", "has", "had", "do", "does",
    "did", "not", "no", "yes",
}

# Footer-ish junk in summaries that we don't want in the signature.
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

# Tokens like "day5", "day-5". We KEEP those so Day 5 BO != Day 6 BO.
_DAY_TOKEN_RE = re.compile(r"^day[-_]?(\d{1,2})$", re.I)

# Numeric / money-ish tokens like "120cr", "505cr". We DROP them so
# hourly box office bumps don't generate "new topic".
_NUMERICY_RE = re.compile(r"^\d+[a-z]*$", re.I)

# Lightweight tense/plural stemming for verbs in our domain.
_VERB_STEMS = {
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

    # plurals
    "trailers": "trailer",
    "teasers": "teaser",
    "films": "film",
    "movies": "movie",
    "shows": "show",
}

# Common name / team normalization.
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

    # Cricket etc.
    "virat": "virat",
    "viratkohli": "virat",
    "dhoni": "dhoni",
    "msdhoni": "dhoni",
    "rohit": "rohit",
    "rohitsharma": "rohit",
    "sachin": "sachin",
    "sachintendulkar": "sachin",

    # IPL shorthand → city nicknames
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

# Semantic equivalents we want to treat as the same.
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

# Known franchise / title buckets we treat as one token.
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
    """Normalize tense/plural for domain verbs."""
    return _VERB_STEMS.get(word.lower(), word.lower())


def _normalize_name(word: str) -> str:
    """Normalize shorthand for names/teams."""
    return _NAME_NORMALIZE.get(word.lower(), word.lower())


def _semantic_normalize(word: str) -> str:
    """Unify teaser/promo/etc → trailer, OTT → streaming, etc."""
    return _SEMANTIC_EQUIV.get(word.lower(), word.lower())


def _collapse_multi_word_entities(tokens: List[str]) -> List[str]:
    """
    Collapse known multi-word entities:
      "bigg boss 19" → "biggboss19"
      "love and war" → "lovewar"
      "pushpa 2"     → "pushpa2"
    """
    out: List[str] = []
    i = 0
    while i < len(tokens):
        # Try "<word1> <word2> <num>"
        if i + 2 < len(tokens) and tokens[i + 2].isdigit():
            two_word = tokens[i] + tokens[i + 1]
            if two_word in _KNOWN_ENTITIES:
                out.append(two_word + tokens[i + 2])
                i += 3
                continue

        # Try "<word1> <word2>"
        if i + 1 < len(tokens):
            two_word = tokens[i] + tokens[i + 1]
            if two_word in _KNOWN_ENTITIES:
                out.append(two_word)
                i += 2
                continue

        out.append(tokens[i])
        i += 1

    return out


def _strip_noise_words(words: List[str]) -> List[str]:
    """Remove hype + filler tokens from a word list."""
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
    Canonicalize title for dedupe:
      - lowercase
      - strip punctuation/emojis
      - drop hype STOPWORDS
      - collapse whitespace
    Returns "" if nothing usable remains.
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)

    words = t.split()
    words = _strip_noise_words(words)

    return " ".join(words).strip()


def canonical_summary(raw_summary: Optional[str]) -> str:
    """
    Canonicalize summary for dedupe:
      - strip "read full story..."-style footers
      - lowercase
      - strip punctuation/emojis
      - drop hype STOPWORDS
      - collapse whitespace
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
    Convert cleaned title+summary → normalized keyword bag:
      - drop COMMON_STOPWORDS ("the", "and", ...)
      - keep "day5" style tokens
      - drop raw numeric/money tokens
      - stem verbs ("announced"→"announce")
      - normalize names ("srk"→"shahrukh")
      - semantic unify ("teaser"/"promo"→"trailer")
      - collapse multi-word entities ("bigg boss 19"→"biggboss19")
    """
    blob = f"{canon_title} {canon_summary}".strip()
    tokens = blob.split()

    stage1: List[str] = []
    for tok in tokens:
        t = tok.strip().lower()
        if not t:
            continue

        # Drop generic glue words.
        if t in _COMMON_STOPWORDS:
            continue

        # Keep "dayN" tokens (they indicate milestones like Day 5 BO).
        if _DAY_TOKEN_RE.match(t):
            stage1.append(t)
            continue

        # Drop raw numeric/money tokens so "120cr" updates don't fork new topics.
        if _NUMERICY_RE.match(t):
            continue

        # Normalize verbs / names / semantics.
        t = _stem_token(t)
        t = _normalize_name(t)
        t = _semantic_normalize(t)

        stage1.append(t)

    collapsed = _collapse_multi_word_entities(stage1)
    return collapsed


def _build_topic_signature_blob(canon_title: str, canon_summary: str) -> str:
    """
    Build a deterministic "topic blob":
      - turn canon title+summary → normalized keywords
      - uniq + sort alphabetically (order-insensitive)
    """
    kw = _keywords_for_signature(canon_title, canon_summary)

    if not kw:
        # fallback so we still have something to hash
        base = f"title:{canon_title}||summary:{canon_summary}".strip()
        return base

    uniq_sorted = sorted(set(kw))
    return " ".join(uniq_sorted).strip()


def _are_topics_similar(topic_blob1: str, topic_blob2: str) -> bool:
    """
    Fuzzy match two topics.
    Similarity = overlap / min(len(tokens1), len(tokens2))
    If >= DUPLICATE_SIMILARITY_THRESHOLD (default 0.80) → duplicate.
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
    Helpers / tests:
    Produce a deterministic short digest for a story based on TOPIC,
    not literal wording.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    if not canon_t:
        return ""

    topic_blob = _build_topic_signature_blob(canon_t, canon_s)
    digest = hashlib.sha1(topic_blob.encode("utf-8")).hexdigest()
    return digest[:16]


# =============================================================================
# Story shaping helpers (before we publish)
# =============================================================================

def _now_utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_verticals(story: Dict[str, Any]) -> None:
    """
    story["verticals"] must be a non-empty list of slugs.
    If empty/missing, fall back so /v1/feed?vertical= still works.
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
    The card renderer expects artwork.
    If thumb_url is missing, try other known artwork fields.
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
    Workers should attach story["kind_meta"] already. If they didn't,
    synthesize a minimal structure so the frontend can render badges.
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
    """Guarantee story['kind_meta'] exists."""
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
    normalized_at and ingested_at are important for sorting,
    realtime fanout, client UI.
    Patch if workers forgot.
    """
    if not story.get("normalized_at"):
        story["normalized_at"] = _now_utc_iso()
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]


def _add_frontend_aliases(story: Dict[str, Any]) -> None:
    """
    Add camelCase mirrors for Flutter/mobile so they don't
    need their own mapping layer.
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
    if "thumb_url" in story and "thumbUrl" not in story:
        story["thumbUrl"] = story["thumb_url"]
    if "poster_url" in story and "posterUrl" not in story:
        story["posterUrl"] = story["poster_url"]
    # safety fallback: mirror thumbUrl to posterUrl if posterUrl missing
    if "posterUrl" not in story and story.get("thumbUrl"):
        story["posterUrl"] = story["thumbUrl"]

    # safety flags (useful for audit/debug)
    if "is_risky" in story and "isRisky" not in story:
        story["isRisky"] = story["is_risky"]
    if "gossip_only" in story and "gossipOnly" not in story:
        story["gossipOnly"] = story["gossip_only"]


def _finalize_story_shape(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare the story object we actually LPUSH to the feed.

    We do NOT rewrite story["title"] or story["summary"] here.
    Workers already sanitized them via:
      - generate_safe_title()
      - summarize_story_safe()
    Those functions stripped hype, attributed risky claims
    ("According to <domain>: ..."), and neutralized tone.
    """
    _ensure_verticals(story)
    _ensure_thumb_url(story)
    _ensure_kind_meta(story)
    _ensure_timestamps(story)

    # normalize tags as list[str] or None
    tags_val = story.get("tags")
    if isinstance(tags_val, list):
        story["tags"] = [t for t in tags_val if isinstance(t, str) and t.strip()] or None
    elif tags_val is None:
        story["tags"] = None
    else:
        story["tags"] = None

    # expose camelCase mirrors for the client
    _add_frontend_aliases(story)

    return story


# =============================================================================
# Realtime fanout / optional push
# =============================================================================

def _publish_realtime(conn: Redis, story: Dict[str, Any]) -> None:
    """
    Broadcast minimal info about a NEW story:
      - Publish to FEED_PUBSUB (JSON payload)
      - XADD to FEED_STREAM (capped for dashboards / logs)
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

        # Pub/Sub for live clients
        conn.publish(FEED_PUBSUB, json.dumps(payload, ensure_ascii=False))

        # Stream append for dashboards / ops (best-effort)
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
            # don't block if stream append fails
            pass

    except Exception as e:
        print(f"[sanitizer] realtime publish error: {e}")


def _enqueue_push(conn: Redis, story: Dict[str, Any]) -> None:
    """
    Optionally enqueue a downstream push notification job.
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


# =============================================================================
# RQ entrypoint
# =============================================================================

def sanitize_story(story: Dict[str, Any]) -> Literal["accepted", "duplicate", "invalid"]:
    """
    The ONLY gate that writes to the public feed.

    Flow:
      0. Hard safety gate:
           - if story["gossip_only"] is True → "invalid"
             We skip pure gossip / leaked-chat / breakup-drama posts that
             have no work/box office/OTT/release context.
      1. Build normalized topic_blob from (title, summary).
      2. Compare topic_blob to existing blobs in Redis (SEEN_KEY):
           - If fuzzy-similar (>= threshold) to any → "duplicate"
             We DO NOT publish again.
      3. Else:
           a. Record this topic blob in SEEN_KEY (so future dupes are caught)
           b. Finalize shape (verticals, thumb, timestamps, camelCase aliases)
           c. LPUSH story JSON to FEED_KEY
           d. LTRIM FEED_KEY to MAX_FEED_LEN
           e. Broadcast realtime + maybe push
           f. Return "accepted"
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # 0. reject pure gossip with no business/release angle
    if story.get("gossip_only"):
        print(f"[sanitizer] GOSSIP_ONLY reject -> {story.get('id')} | {raw_title}")
        return "invalid"

    # 1. canonicalize → topic blob
    canon_t = canonical_title(raw_title)
    canon_s = canonical_summary(raw_summary)

    if not canon_t:
        print(f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}")
        return "invalid"

    topic_blob = _build_topic_signature_blob(canon_t, canon_s)
    sig = hashlib.sha1(topic_blob.encode("utf-8")).hexdigest()[:16]

    # 2. fuzzy dedupe against previously accepted topics
    try:
        existing_topics = conn.hgetall(SEEN_KEY)  # { sig: topic_blob }
    except Exception as e:
        print(f"[sanitizer] ERROR reading SEEN_KEY: {e}")
        existing_topics = {}

    for existing_sig, existing_blob in existing_topics.items():
        if _are_topics_similar(topic_blob, existing_blob):
            print(
                f"[sanitizer] DUPLICATE (similar to {existing_sig}) "
                f"-> {story.get('id')} | {raw_title}"
            )
            return "duplicate"

    # 3a. Remember this topic so follow-ups get suppressed.
    try:
        conn.hset(SEEN_KEY, sig, topic_blob)
    except Exception as e:
        print(f"[sanitizer] ERROR storing signature {sig}: {e}")

    # 3b. finalize story so feed/api/mobile get consistent, app-ready fields
    story = _finalize_story_shape(story)

    # 3c. LPUSH newest-first into FEED_KEY
    try:
        conn.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
    except Exception as e:
        print(f"[sanitizer] ERROR LPUSH feed for {story.get('id')}: {e}")

    # 3d. trim FEED_KEY
    if MAX_FEED_LEN > 0:
        try:
            conn.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)
        except Exception as e:
            print(f"[sanitizer] ERROR LTRIM feed: {e}")

    # 4. broadcast + optional push
    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
