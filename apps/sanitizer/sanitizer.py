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
#                 - verticals        (["entertainment"], ...)
#                 - tags             (["bollywood","box-office","ott",...])
#                 - hero art urls    (thumb_url/image/...)
#                 - timestamps
#                 - safety flags:
#                       story["is_risky"]       : True if legal/PR heat
#                       story["gossip_only"]    : True if purely off-camera gossip
#                       story["onscreen_drama"] : True if televised/streamed on-air drama
#
#   sanitizer  → THIS FILE (final gatekeeper):
#                 * BLOCK pure gossip unless it’s clearly on-air drama
#                   Rule: if gossip_only == True and onscreen_drama == False → reject
#                 * BLOCK disallowed verticals (e.g., sports) by policy
#                 * Fuzzy topic dedupe (first wins; similar follow-ups dropped)
#                 * Publish accepted story to Redis FEED_KEY (newest first)
#                 * Trim FEED_KEY, fan-out realtime, optional push
#
# HARD RULES (operational / legal):
# - workers NEVER write to FEED_KEY
# - workers NEVER dedupe
# - sanitizer is the ONLY publisher to FEED_KEY
# - DO NOT rewrite title/summary here. Attribution added upstream is legally important.
#
# DEDUPE STRATEGY:
#   Build a normalized "topic_blob" from canonicalized title+summary:
#     - lowercase, strip hype/emoji/promo, light stemming/normalization
#     - collapse known multi-word entities ("bigg boss 19" → "biggboss19")
#     - drop pure numeric money bumps so hourly BO deltas don’t fork topics
#   Compare topic_blob against a Redis HASH (SEEN_KEY). If fuzzy-similar ≥ threshold → duplicate.
#   Maintain a Redis ZSET (SEEN_INDEX_KEY) to prune oldest signatures on free tier.
#
# sanitize_story() returns one of:
#   "accepted"   | "duplicate" | "invalid"
#
# ENV:
#   REDIS_URL
#   FEED_KEY
#   SEEN_KEY
#   SEEN_INDEX_KEY
#   SEEN_MAX                       (default 5000)
#   MAX_FEED_LEN                   (default 200)
#   FEED_PUBSUB, FEED_STREAM, FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS      (0/1)
#   FALLBACK_VERTICAL              (default "entertainment")
#   DISALLOW_VERTICALS             (CSV, default "sports")
#   DUPLICATE_SIMILARITY_THRESHOLD (0.0–1.0, default 0.80)

from __future__ import annotations

import os
import re
import json
import hashlib
from datetime import datetime, timezone
from typing import Dict, Any, Literal, Optional, List, Set

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

# Redis ZSET index to prune old dedupe signatures (member=sig, score=epoch).
SEEN_INDEX_KEY = os.getenv("SEEN_INDEX_KEY", "feed:seen_index")

# Cap for dedupe memory (free-tier friendly).
SEEN_MAX = int(os.getenv("SEEN_MAX", "5000"))

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

# Policy: block these verticals outright (CSV). Default blocks "sports".
_DISALLOW_VERTICALS_RAW = os.getenv("DISALLOW_VERTICALS", "sports")
DISALLOW_VERTICALS: Set[str] = {v.strip() for v in _DISALLOW_VERTICALS_RAW.split(",") if v.strip()}

# Fuzzy duplicate threshold: 0.80 → 80% token overlap on smaller set
DUPLICATE_SIMILARITY_THRESHOLD = float(os.getenv("DUPLICATE_SIMILARITY_THRESHOLD", "0.80"))


def _redis() -> Redis:
    """Create a Redis client for dedupe/feed/fanout/push."""
    return Redis.from_url(REDIS_URL, decode_responses=True)


# =============================================================================
# Canonicalization / topic-signature helpers for dedupe
# =============================================================================

# Words that are hypey / promo / repetitive noise and shouldn't define a topic.
_STOPWORDS = {
    "breaking", "exclusive", "watch", "watchnow", "watch now",
    "teaser", "trailer", "first", "look", "first look", "firstlook",
    "revealed", "reveal", "official", "officially", "now", "just", "out",
    "finally", "drops", "dropped", "drop", "release", "released", "leak",
    "leaked", "update", "updates", "announced", "announces", "announcing",
    "confirms", "confirmed", "confirm", "big", "huge", "massive", "viral",
    "shocking", "omg", "🔥",
    # box-office hype terms that repeat daily
    "box", "office", "collection", "collections", "day", "opening", "weekend",
}

# Glue words we always toss.
_COMMON_STOPWORDS = {
    "the","a","an","this","that","and","or","but","if","so",
    "to","for","of","on","in","at","by","with","as","from",
    "about","after","before","over","under","it","its","his",
    "her","their","they","you","your","we","our","is","are",
    "was","were","be","been","being","will","can","could",
    "should","may","might","have","has","had","do","does",
    "did","not","no","yes",
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
    "announcing": "announce", "announces": "announce", "announced": "announce",
    "confirming": "confirm", "confirms": "confirm", "confirmed": "confirm",
    "revealing": "reveal",  "reveals": "reveal",  "revealed": "reveal",
    "dropping": "drop",     "drops": "drop",      "dropped": "drop",
    "releasing": "release", "releases": "release","released": "release",
    "joining": "join",      "joins": "join",      "joined": "join",
    "starring": "star",     "stars": "star",      "starred": "star",
    "streaming": "stream",  "streams": "stream",  "streamed": "stream",
    "earning": "earn",      "earns": "earn",      "earned": "earn",
    "collecting": "collect","collects": "collect","collected": "collect",
    "grossing": "gross",    "grosses": "gross",   "grossed": "gross",
    "making": "make",       "makes": "make",      "made": "make",
    # plurals
    "trailers": "trailer","teasers": "teaser","films": "film",
    "movies": "movie","shows": "show",
}

# map shorthand names / tags → canonical tokens
_NAME_NORMALIZE = {
    # Bollywood (illustrative; expand as needed)
    "salmankhan": "salman", "srk": "shahrukh", "shahrukhkhan": "shahrukh",
    "ranbirkapoor": "ranbir", "aliabhatt": "alia", "vickykaushal": "vicky",
    "ranveersingh": "ranveer", "deepikapadukone": "deepika",
    "katrinakaif": "katrina", "hrithikroshan": "hrithik",
    "priyankachopra": "priyanka", "aamirkhan": "aamir", "akshaykumar": "akshay",
    "ajaydevgn": "ajay",
}

# semantic equivalence ("teaser" == "trailer", etc.)
_SEMANTIC_EQUIV = {
    "teaser": "trailer", "promo": "trailer", "glimpse": "trailer",
    "sneak": "trailer", "peek": "trailer", "preview": "trailer",
    "ott": "streaming", "digital": "streaming", "online": "streaming",
    "theatrical": "cinema", "theater": "cinema", "theatre": "cinema",
    "earns": "collect", "grosses": "collect", "makes": "collect",
    "earnings": "collection", "gross": "collection",
}

# Franchise / recurring show buckets we want as single tokens.
_KNOWN_ENTITIES = {
    "biggboss","biggbosslive","biggbossvote",
    "pushpa","pushpa2","kgf","rrr","pathaan","jawan","dunki","animal","fighter",
    "singham","golmaal","housefull","boxoffice","ottrelease",
}

# Lightweight sports guard (policy layer; we do not ship sports).
_SPORTS_V_RE = re.compile(
    r"\b(ipl|t20|odi|test\s+match|wicket|scorecard|premier\s+league|champions\s+league|world\s+cup)\b",
    re.I,
)


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
    """Remove hype STOPWORDS like 'breaking' / 'watch now' and other filler."""
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
      - drop COMMON_STOPWORDS
      - KEEP "day5" tokens (milestones)
      - DROP raw numeric/money tokens ("120cr") to avoid hourly forked topics
      - stem verbs / normalize names / semantics
      - collapse known multi-word franchises
    """
    blob = f"{canon_title} {canon_summary}".strip()
    tokens = blob.split()

    stage1: List[str] = []
    for tok in tokens:
        t = tok.strip().lower()
        if not t:
            continue
        if t in _COMMON_STOPWORDS:
            continue
        if _DAY_TOKEN_RE.match(t):
            stage1.append(t)
            continue
        if _NUMERICY_RE.match(t):
            continue
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
    Helper for tests / debugging: short digest for a story based on TOPIC,
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
    """Synthesize minimal kind_meta if workers didn't set it."""
    if kind == "trailer":
        return {"kind": "trailer", "label": "Official Trailer", "is_breaking": True}
    if kind == "ott":
        return {"kind": "ott_drop", "platform": ott_platform, "is_breaking": True}
    if kind == "release":
        return {
            "kind": "release",
            "is_theatrical": bool(is_theatrical),
            "is_upcoming": bool(is_upcoming),
            "release_date": release_date,
        }
    return {"kind": "news", "is_breaking": False}


def _ensure_kind_meta(story: Dict[str, Any]) -> None:
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
    """Patch normalized_at/ingested_at if missing."""
    if not story.get("normalized_at"):
        story["normalized_at"] = _now_utc_iso()
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]


def _add_frontend_aliases(story: Dict[str, Any]) -> None:
    """
    Add camelCase mirrors for Flutter/web so the client doesn't need to rename.
    Also mirror safety flags (future UI badges).
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
    if "posterUrl" not in story and story.get("thumbUrl"):
        story["posterUrl"] = story["thumbUrl"]

    # safety flags (debug / future UI badges)
    if "is_risky" in story and "isRisky" not in story:
        story["isRisky"] = story["is_risky"]
    if "gossip_only" in story and "gossipOnly" not in story:
        story["gossipOnly"] = story["gossip_only"]

    # Accept either legacy 'drama_signal' (float) or new boolean 'onscreen_drama'
    on_air = story.get("onscreen_drama")
    if on_air is None:
        try:
            ds = float(story.get("drama_signal", 0.0))
            on_air = ds > 0.0
        except Exception:
            on_air = False
    story["onscreen_drama"] = bool(on_air)
    if "onScreenDrama" not in story:
        story["onScreenDrama"] = story["onscreen_drama"]


def _finalize_story_shape(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare the object we LPUSH to FEED_KEY.
    DO NOT touch story["title"] or story["summary"] content (legal attribution stays).
    """
    _ensure_verticals(story)
    _ensure_thumb_url(story)
    _ensure_kind_meta(story)
    _ensure_timestamps(story)

    # normalize tags as list[str] or None
    tags_val = story.get("tags")
    if isinstance(tags_val, list):
        story["tags"] = [t for t in tags_val if isinstance(t, str) and t.strip()] or None
    else:
        story["tags"] = None if tags_val is None else None

    _add_frontend_aliases(story)
    return story


# =============================================================================
# Realtime fanout / optional push
# =============================================================================

def _publish_realtime(conn: Redis, story: Dict[str, Any]) -> None:
    """Broadcast minimal info about a NEW story via Pub/Sub and XADD (best-effort)."""
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
        conn.publish(FEED_PUBSUB, json.dumps(payload, ensure_ascii=False))
        try:
            conn.xadd(
                FEED_STREAM,
                {"id": str(payload.get("id") or ""), "kind": str(payload.get("kind") or ""), "ts": str(payload.get("normalized_at") or "")},
                maxlen=FEED_STREAM_MAXLEN,
                approximate=True,
            )
        except Exception:
            pass  # don't block if stream append fails
    except Exception as e:
        print(f"[sanitizer] realtime publish error: {e}")


def _enqueue_push(conn: Redis, story: Dict[str, Any]) -> None:
    """Optionally enqueue downstream push notification job."""
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
# Policy / guard helpers
# =============================================================================

def _is_disallowed_vertical(story: Dict[str, Any]) -> bool:
    verts = story.get("verticals") or []
    if not isinstance(verts, list):
        return False
    return any(v in DISALLOW_VERTICALS for v in verts if isinstance(v, str))


def _looks_like_sports(title: str, summary: Optional[str]) -> bool:
    hay = f"{title or ''}\n{summary or ''}"
    return bool(_SPORTS_V_RE.search(hay))


# =============================================================================
# Dedupe index maintenance (free-tier friendly)
# =============================================================================

def _dedupe_index_remember(conn: Redis, sig: str, topic_blob: str) -> None:
    """
    Store signature in HASH and ZSET index; prune oldest if we exceed SEEN_MAX.
    """
    try:
        pipe = conn.pipeline(True)
        pipe.hset(SEEN_KEY, sig, topic_blob)
        pipe.zadd(SEEN_INDEX_KEY, {sig: datetime.now(timezone.utc).timestamp()})
        pipe.execute()
    except Exception as e:
        print(f"[sanitizer] ERROR storing signature {sig}: {e}")

    try:
        size = conn.zcard(SEEN_INDEX_KEY)
        if size and size > SEEN_MAX:
            # remove oldest extras
            remove_count = size - SEEN_MAX
            old_sigs = conn.zrange(SEEN_INDEX_KEY, 0, remove_count - 1)
            if old_sigs:
                pipe = conn.pipeline(True)
                pipe.hdel(SEEN_KEY, *old_sigs)
                pipe.zrem(SEEN_INDEX_KEY, *old_sigs)
                pipe.execute()
    except Exception as e:
        print(f"[sanitizer] ERROR pruning dedupe index: {e}")


# =============================================================================
# RQ entrypoint
# =============================================================================

def sanitize_story(story: Dict[str, Any]) -> Literal["accepted", "duplicate", "invalid"]:
    """
    Final gate. This is the ONLY code path that writes to the public feed.

    Flow:
      0. Policy gates:
           - Block disallowed verticals (e.g., sports) and sportsy content guard.
           - If gossip_only True AND onscreen_drama False → reject.
      1. Canonicalize → topic blob; ensure usable canonical title.
      2. Fuzzy dedupe vs SEEN_KEY; if similar ≥ threshold → duplicate.
      3. Else record sig in HASH+ZSET, finalize shape, LPUSH, LTRIM, fanout (+ optional push).
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # --- 0.a block disallowed verticals / sports policy -----------------------
    # We only ship entertainment. Never ship sports.
    if _is_disallowed_vertical(story) or _looks_like_sports(raw_title, raw_summary):
        print(f"[sanitizer] POLICY REJECT (disallowed vertical/sports) -> {story.get('id')} | {raw_title}")
        return "invalid"

    # --- 0.b gossip gate with on-air exception --------------------------------
    gossip_only = bool(story.get("gossip_only"))

    # accept both new boolean and legacy float 'drama_signal'
    on_air = story.get("onscreen_drama")
    if on_air is None:
        try:
            on_air = float(story.get("drama_signal", 0.0)) > 0.0
        except Exception:
            on_air = False
    on_air = bool(on_air)

    if gossip_only and not on_air:
        print(f"[sanitizer] GOSSIP_ONLY reject -> {story.get('id')} | {raw_title}")
        return "invalid"

    # --- 1. canonicalize → topic blob ----------------------------------------
    canon_t = canonical_title(raw_title)
    canon_s = canonical_summary(raw_summary)

    if not canon_t:
        print(f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}")
        return "invalid"

    topic_blob = _build_topic_signature_blob(canon_t, canon_s)
    sig = hashlib.sha1(topic_blob.encode("utf-8")).hexdigest()[:16]

    # --- 2. fuzzy dedupe ------------------------------------------------------
    try:
        existing_topics = conn.hgetall(SEEN_KEY)  # { sig: topic_blob }
    except Exception as e:
        print(f"[sanitizer] ERROR reading SEEN_KEY: {e}")
        existing_topics = {}

    # exact match fast-path
    if sig in existing_topics:
        print(f"[sanitizer] DUPLICATE (same sig {sig}) -> {story.get('id')} | {raw_title}")
        return "duplicate"

    # fuzzy match path
    for existing_sig, existing_blob in existing_topics.items():
        if _are_topics_similar(topic_blob, existing_blob):
            print(f"[sanitizer] DUPLICATE (similar to {existing_sig}) -> {story.get('id')} | {raw_title}")
            return "duplicate"

    # --- 3. accept and publish ------------------------------------------------
    _dedupe_index_remember(conn, sig, topic_blob)

    story = _finalize_story_shape(story)

    try:
        conn.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
    except Exception as e:
        print(f"[sanitizer] ERROR LPUSH feed for {story.get('id')}: {e}")

    if MAX_FEED_LEN > 0:
        try:
            conn.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)
        except Exception as e:
            print(f"[sanitizer] ERROR LTRIM feed: {e}")

    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
