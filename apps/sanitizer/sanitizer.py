# apps/sanitizer/sanitizer.py
#
# ROLE IN PIPELINE (runs in the "sanitize" RQ worker):
#
#   scheduler  → polls sources and enqueues ingest jobs
#
#   workers    → normalize_event() builds a canonical story dict and enqueues
#                 sanitize_story(story) on the "sanitize" queue.
#
#               worker story dict SHOULD ALREADY BE SAFE:
#                 - title            (generate_safe_title)
#                 - summary          (summarize_story_safe)
#                 - kind / kind_meta (trailer / release / ott / news / etc.)
#                 - verticals        (["entertainment"], ["sports"], ...)
#                 - tags             (["bollywood","box-office","ott","drama",...])
#                 - hero art urls    (thumb_url/image/...)
#                 - timestamps
#                 - safety flags:
#                       story["is_risky"]        -> True if legal/PR heat
#                       story["gossip_only"]     -> True if it's ONLY personal gossip
#                                                  (breakup, "spotted with", leaked chat)
#                                                  with NO work/release/box-office context
#                       story["drama_signal"]    -> >0 if it's on-screen / show / match drama
#                                                  (Bigg Boss fight, elimination drama,
#                                                   "heated argument on live show")
#
#   sanitizer  → THIS FILE
#               - final gatekeeper for the public feed:
#                   * BLOCK pure gossip (personal-life / relationship / leaked DM)
#                     unless it's clearly on-screen / professional context.
#                     Rule:
#                        if gossip_only == True AND drama_signal <= 0 → reject
#
#                   * fuzzy topic dedupe:
#                        - first story about a topic gets published
#                        - similar follow-ups get flagged "duplicate" and dropped
#
#                   * write accepted story to Redis FEED_KEY
#                   * trim FEED_KEY
#                   * publish realtime + (optional) push
#
#   api        → /v1/feed reads FEED_KEY (Redis LIST newest-first)
#
# HARD RULES (operational / legal):
# - workers NEVER write to FEED_KEY
# - workers NEVER dedupe
# - sanitizer is the ONLY publisher to FEED_KEY
#
# - DO NOT rewrite title/summary here.
#   They already include attribution like
#   "According to <source> ..." or "YouTube video claims: ..."
#   That attribution is legally important. We keep it.
#
# DEDUPE STRATEGY (topic signature):
#   We compute a normalized "topic_blob" from title+summary:
#     1. lowercase, strip hype words, strip emojis/promo tails
#     2. normalize verbs ("announced"/"announcing"→"announce")
#     3. normalize actor/team aliases ("srk"→"shahrukh", "rcb"→"bangalore")
#     4. unify teaser/promo/glimpse/sneak-peek → "trailer"
#     5. collapse multi-word franchises ("bigg boss 19"→"biggboss19")
#     6. drop throwaway glue words ("the","and","to",...)
#     7. drop pure numeric money bumps ("120cr", "505cr") so every hourly
#        box office update doesn't spam a new card
#
#   We then compare against Redis hash SEEN_KEY which stores topic blobs from
#   previously accepted stories. If overlap similarity >= threshold, it's a dup.
#
# Redis keys:
#   FEED_KEY  : Redis LIST (newest first). Each element is final story JSON.
#   SEEN_KEY  : Redis HASH (sig -> topic_blob) of accepted stories for dedupe.
#
# sanitize_story() returns:
#   "accepted"   -> published to feed
#   "duplicate"  -> dropped (already covered topic)
#   "invalid"    -> dropped (gossip-only reject, or unusable/no canonical title)
#
# ENV:
#   REDIS_URL
#   FEED_KEY
#   SEEN_KEY
#   MAX_FEED_LEN
#   FEED_PUBSUB
#   FEED_STREAM
#   FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS
#   FALLBACK_VERTICAL
#   DUPLICATE_SIMILARITY_THRESHOLD

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

# Redis HASH of dedupe topic blobs for accepted stories (sig -> topic_blob).
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Max number of stories we keep in FEED_KEY. <=0 means "no trim".
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))

# Realtime fanout targets.
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
FEED_STREAM_MAXLEN = int(os.getenv("FEED_STREAM_MAXLEN", "5000"))

# Optional push notifications toggle.
ENABLE_PUSH_NOTIFICATIONS = os.getenv("ENABLE_PUSH_NOTIFICATIONS", "0").lower() not in (
    "0", "", "false", "no",
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

# Words that are hypey / promo / repetitive noise and shouldn't define a topic.
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

# Glue words we always toss.
_COMMON_STOPWORDS = {
    "the", "a", "an", "this", "that", "and", "or", "but", "if", "so",
    "to", "for", "of", "on", "in", "at", "by", "with", "as", "from",
    "about", "after", "before", "over", "under", "it", "its", "his",
    "her", "their", "they", "you", "your", "we", "our", "is", "are",
    "was", "were", "be", "been", "being", "will", "can", "could",
    "should", "may", "might", "have", "has", "had", "do", "does",
    "did", "not", "no", "yes",
}

# Footer-ish junk in summaries we don't want in signature.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# anything not [a-z0-9 -] → space
_CLEAN_RE = re.compile(r"[^a-z0-9\s-]+", re.IGNORECASE)

# Tokens like "day5", "day-5". KEEP (milestone context).
_DAY_TOKEN_RE = re.compile(r"^day[-_]?(\d{1,2})$", re.I)

# Raw numeric / money tokens like "120cr", "505cr". DROP so we don't explode topics.
_NUMERICY_RE = re.compile(r"^\d+[a-z]*$", re.I)

# lightweight verb/tense/plural stemmer for our domain
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

# map shorthand names / IPL team tags / etc. to canonical tokens
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

    # cricket / sports
    "viratkohli": "virat",
    "virat": "virat",
    "msdhoni": "dhoni",
    "dhoni": "dhoni",
    "rohitsharma": "rohit",
    "rohit": "rohit",
    "sachintendulkar": "sachin",
    "sachin": "sachin",

    # IPL shortcuts -> city nicknames
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

# semantic equivalence ("teaser" == "trailer", etc.)
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

# Franchise / recurring show buckets we want as single tokens.
_KNOWN_ENTITIES = {
    "biggboss",
    "biggbosslive",
    "biggbossvote",
    "pushpa",
    "pushpa2",
    "kgf",
    "rrr",
    "pathaan",
    "jawan",
    "dunki",
    "animal",
    "fighter",
    "singham",
    "golmaal",
    "housefull",
    "boxoffice",
    "ottrelease",
}


def _stem_token(w: str) -> str:
    return _VERB_STEMS.get(w.lower(), w.lower())


def _normalize_name(w: str) -> str:
    return _NAME_NORMALIZE.get(w.lower(), w.lower())


def _semantic_normalize(w: str) -> str:
    return _SEMANTIC_EQUIV.get(w.lower(), w.lower())


def _collapse_multi_word_entities(tokens: List[str]) -> List[str]:
    """
    Collapse stuff like:
      "bigg boss 19"   -> "biggboss19"
      "pushpa 2"       -> "pushpa2"
      "bigg boss live" -> "biggbosslive"
    """
    out: List[str] = []
    i = 0
    while i < len(tokens):
        # try "<word1> <word2> <num>"
        if i + 2 < len(tokens) and tokens[i + 2].isdigit():
            combo = tokens[i] + tokens[i + 1]
            if combo in _KNOWN_ENTITIES:
                out.append(combo + tokens[i + 2])
                i += 3
                continue

        # try "<word1> <word2>"
        if i + 1 < len(tokens):
            combo = tokens[i] + tokens[i + 1]
            if combo in _KNOWN_ENTITIES:
                out.append(combo)
                i += 2
                continue

        out.append(tokens[i])
        i += 1
    return out


def _strip_noise_words(words: List[str]) -> List[str]:
    """
    Remove hype STOPWORDS like "breaking" / "watch now" and other filler.
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
    Canonicalize title for dedupe:
      - lowercase
      - strip punctuation/emojis
      - remove hype STOPWORDS
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
      - cut promo footers ("read full story...")
      - lowercase
      - strip punctuation/emojis
      - remove hype STOPWORDS
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
    Convert cleaned title+summary → normalized keyword bag.
    Steps:
      - drop COMMON_STOPWORDS ("the","and","to"...)
      - KEEP "day5" style tokens (milestone context)
      - DROP raw numeric money tokens ("120cr") so hourly BO bumps don't fork topics
      - stem verbs ("announced"→"announce")
      - normalize shorthand names / IPL teams ("srk"→"shahrukh", "rcb"→"bangalore")
      - unify teaser/promo/glimpse/sneak-peek → "trailer"
      - collapse known multi-word franchises ("bigg boss 19"→"biggboss19")
    """
    blob = f"{canon_title} {canon_summary}".strip()
    tokens = blob.split()

    stage1: List[str] = []
    for tok in tokens:
        t = tok.strip().lower()
        if not t:
            continue

        # toss glue words
        if t in _COMMON_STOPWORDS:
            continue

        # keep "day5" tokens, they matter ("Day 5 box office")
        if _DAY_TOKEN_RE.match(t):
            stage1.append(t)
            continue

        # dump raw numeric/money tokens so "120cr" vs "121cr" doesn't create spam topics
        if _NUMERICY_RE.match(t):
            continue

        # normalize tense / names / semantics
        t = _stem_token(t)
        t = _normalize_name(t)
        t = _semantic_normalize(t)

        stage1.append(t)

    collapsed = _collapse_multi_word_entities(stage1)
    return collapsed


def _build_topic_signature_blob(canon_title: str, canon_summary: str) -> str:
    """
    Build deterministic "topic blob":
      - turn canon title+summary → normalized keyword list
      - uniq + sort alphabetically (order-insensitive)
    """
    kw = _keywords_for_signature(canon_title, canon_summary)

    if not kw:
        # fallback so we still have something to hash/compare
        base = f"title:{canon_title}||summary:{canon_summary}".strip()
        return base

    uniq_sorted = sorted(set(kw))
    return " ".join(uniq_sorted).strip()


def _are_topics_similar(topic_blob1: str, topic_blob2: str) -> bool:
    """
    Fuzzy match two topics.
    similarity = overlap / min(len(tokens1), len(tokens2))
    If >= DUPLICATE_SIMILARITY_THRESHOLD → treat as duplicate.
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
    Helper for tests / debugging:
    Produce a short digest for a story based on TOPIC,
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
    Workers should pass story["kind_meta"] already.
    If not, synthesize a minimal structure so the frontend can render badges.
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
    normalized_at / ingested_at are important for sort, push, realtime.
    Patch if workers forgot.
    """
    if not story.get("normalized_at"):
        story["normalized_at"] = _now_utc_iso()
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]


def _add_frontend_aliases(story: Dict[str, Any]) -> None:
    """
    Add camelCase mirrors for Flutter/web so the client doesn't need
    to rename fields.
    Also include safety/debug flags so the app *could* surface badges later.
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

    # safety flags (debug / future UI badges)
    if "is_risky" in story and "isRisky" not in story:
        story["isRisky"] = story["is_risky"]
    if "gossip_only" in story and "gossipOnly" not in story:
        story["gossipOnly"] = story["gossip_only"]
    if "drama_signal" in story and "dramaSignal" not in story:
        story["dramaSignal"] = story["drama_signal"]


def _finalize_story_shape(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare the object we LPUSH to FEED_KEY.
    We DO NOT touch story["title"] or story["summary"] content.
    (Attribution text like "According to <source>:" must stay.)
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

    # mirror camelCase keys for client convenience
    _add_frontend_aliases(story)

    return story


# =============================================================================
# Realtime fanout / optional push
# =============================================================================

def _publish_realtime(conn: Redis, story: Dict[str, Any]) -> None:
    """
    Broadcast minimal info about a NEW story:
      - Publish to FEED_PUBSUB (JSON payload)
      - XADD to FEED_STREAM (capped) for dashboards / ops
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
    Optionally enqueue downstream push notification job.
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
    Final gate. This is the ONLY code path that writes to the public feed.

    Flow:
      0. Gossip gate:
           - If story["gossip_only"] is True AND drama_signal <= 0 → reject.
             (Pure personal/relationship gossip, leaked chats, etc.)
           - If drama_signal > 0 (on-screen / professional context / match
             argument / reality-show fight), allow it. It's "content", not
             paparazzi stalking.
      1. Build normalized topic_blob from (title, summary).
      2. Compare topic_blob to existing blobs in Redis (SEEN_KEY):
           - If fuzzy-similar (>= threshold) to any → "duplicate"
      3. Else:
           a. Record this topic blob in SEEN_KEY
           b. Finalize story shape (verticals, artwork, timestamps, camelCase, etc.)
           c. LPUSH story JSON to FEED_KEY
           d. LTRIM FEED_KEY
           e. Broadcast realtime + maybe push
           f. Return "accepted"
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # 0. gossip filter with on-screen exception
    gossip_only = bool(story.get("gossip_only"))
    drama_signal = story.get("drama_signal")
    try:
        drama_val = float(drama_signal) if drama_signal is not None else 0.0
    except Exception:
        drama_val = 0.0

    if gossip_only and drama_val <= 0.0:
        print(f"[sanitizer] GOSSIP_ONLY reject -> {story.get('id')} | {raw_title}")
        return "invalid"

    # 1. canonicalize → topic blob
    canon_t = canonical_title(raw_title)
    canon_s = canonical_summary(raw_summary)

    if not canon_t:
        # If we can't canonicalize the title at all, it's unusable.
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

    # fast path: exact sig already present
    if sig in existing_topics:
        print(
            f"[sanitizer] DUPLICATE (same sig {sig}) "
            f"-> {story.get('id')} | {raw_title}"
        )
        return "duplicate"

    # fuzzy path: compare with all prior blobs
    for existing_sig, existing_blob in existing_topics.items():
        if _are_topics_similar(topic_blob, existing_blob):
            print(
                f"[sanitizer] DUPLICATE (similar to {existing_sig}) "
                f"-> {story.get('id')} | {raw_title}"
            )
            return "duplicate"

    # 3a. remember this topic blob so later repeats get dropped
    try:
        conn.hset(SEEN_KEY, sig, topic_blob)
    except Exception as e:
        print(f"[sanitizer] ERROR storing signature {sig}: {e}")

    # 3b. finalize story so the app gets consistent, app-ready fields
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

    # 4. realtime fanout + optional push
    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
