# apps/sanitizer/sanitizer.py
#
# PIPELINE ROLE (this container = the "sanitize" RQ worker):
#
#   scheduler  → polls sources and enqueues ingest jobs
#   workers    → normalize_event() builds a canonical story dict:
#                 - title, summary (already cleaned/pro)
#                 - kind, kind_meta (trailer / release / ott / news details)
#                 - verticals (["entertainment"], ["sports"], ...)
#                 - tags (industry, ott, box-office, etc.)
#                 - hero image fields (thumb_url/image/...)
#                 - timestamps
#               and enqueues sanitize_story(story) on the "sanitize" queue
#
#   sanitizer  → THIS FILE, running under rq worker "sanitize"
#               - final gatekeeper for the public feed:
#                   * dedupe
#                   * accept only the first version
#                   * push to Redis FEED_KEY
#                   * trim FEED_KEY
#                   * broadcast realtime + optional push notification
#
#   api        → /v1/feed reads FEED_KEY
#                supports /v1/feed?vertical=sports etc.
#                by filtering story["verticals"]
#
# CRUCIAL RULES:
# - workers DO NOT write to FEED_KEY
# - workers DO NOT dedupe
# - sanitizer is the ONLY thing that can publish to FEED_KEY
#
# DEDUPE STRATEGY:
# - We canonicalize (title + summary) → strip hype words / boilerplate
# - Hash that canonical text (sha1) → short signature
# - Store that signature in Redis set SEEN_KEY
# - If signature already seen → drop as "duplicate"
# - We never "upgrade" an older story in-place. First one wins permanently.
#
# sanitize_story() returns:
#   "accepted"   -> published
#   "duplicate"  -> dropped (already had essentially the same story)
#   "invalid"    -> dropped (no meaningful canonical title)
#
# ENV VARS:
#   REDIS_URL, FEED_KEY, SEEN_KEY, MAX_FEED_LEN
#   FEED_PUBSUB, FEED_STREAM, FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS
#   FALLBACK_VERTICAL (default "entertainment")
#
# NOTE:
# - We lightly "finalize" the story before pushing:
#     * ensure story["verticals"] exists
#     * ensure story["thumb_url"] isn't empty
#     * ensure story["kind_meta"] exists (in case worker was old)
#     * ensure timestamps exist
# - We don't strip debug fields like payload/image_candidates/etc.
#   because they're used by backfill_repair_recent().


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

# Redis SET of dedupe signatures for accepted stories.
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


def _redis() -> Redis:
    """
    Build a Redis client for:
      - dedupe set (SEEN_KEY)
      - feed list writes
      - pub/sub + stream fanout
      - optional push enqueue
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # return str not bytes
    )


# ------------------------------------------------------------------------------
# Canonicalization helpers for dedupe
# ------------------------------------------------------------------------------

# Words / hype / filler that shouldn't affect "is this basically the same story?"
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
    # box-office style hype words are often repeated too
    "box",
    "office",
    "collection",
    "collections",
    "day",
    "opening",
    "weekend",
}

# Footer-y junk to strip from summaries before hashing.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# Anything not alphanumeric or whitespace → space.
_CLEAN_RE = re.compile(r"[^a-z0-9\s]+", re.IGNORECASE)


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
    Lowercase, strip punctuation/emojis, drop hype words, collapse whitespace.
    If this ends up empty, we can't trust this story as uniquely identifiable.
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: Optional[str]) -> str:
    """
    Same idea for summary:
    - Strip footer CTAs
    - Lowercase, scrub noise, drop hype words
    - Collapse whitespace
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


def story_signature(title: str, summary: Optional[str]) -> str:
    """
    Produce a short deterministic signature for dedupe:
      sig = sha1( "title:<canon_title>||summary:<canon_summary>" )[0:16]
    If the canonical title is empty, return "" → invalid story.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    if not canon_t:
        return ""

    blob = f"title:{canon_t}||summary:{canon_s}"
    digest = hashlib.sha1(blob.encode("utf-8")).hexdigest()
    return digest[:16]


# ------------------------------------------------------------------------------
# Helpers to finalize the story object before we publish
# ------------------------------------------------------------------------------

def _now_utc_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_verticals(story: Dict[str, Any]) -> None:
    """
    Workers should already attach a list like ["entertainment"] or ["sports"].
    If it's missing or empty, fall back so API /v1/feed?vertical= still works.
    We also normalize to list[str] of non-empty slugs.
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
    UI depends heavily on thumb_url.
    Workers already try hard, but as a last line we fall back to any of the
    other image-like fields if thumb_url is still empty.
    """
    if story.get("thumb_url"):
        return
    for k in ("image", "poster", "thumbnail", "media"):
        v = story.get(k)
        if v:
            story["thumb_url"] = v
            return


def _build_kind_meta_fallback(kind: str,
                              ott_platform: Optional[str],
                              is_theatrical: Any,
                              is_upcoming: Any,
                              release_date: Optional[str]) -> Dict[str, Any]:
    """
    Workers should already send story["kind_meta"].
    But if they don't (older worker during rollout), build a minimal one here.
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
    Guarantee story["kind_meta"] exists and is minimally structured.
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
    If workers forgot, patch them here.
    """
    if not story.get("normalized_at"):
        story["normalized_at"] = _now_utc_iso()
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]


def _finalize_story_shape(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Mutates + returns story.
    This is the exact shape we write to Redis and broadcast.
    """
    _ensure_verticals(story)
    _ensure_thumb_url(story)
    _ensure_kind_meta(story)
    _ensure_timestamps(story)

    # tags should at least be a list or None for JSON cleanliness
    tags_val = story.get("tags")
    if isinstance(tags_val, list):
        story["tags"] = [t for t in tags_val if isinstance(t, str) and t.strip()] or None
    elif tags_val is None:
        story["tags"] = None
    else:
        # garbage -> squash
        story["tags"] = None

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
            "verticals": story.get("verticals"),  # new: expose verticals
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

        # Capped stream for tailing
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
            # Don't let stream failure block ingest
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

def sanitize_story(story: Dict[str, Any]) -> Literal["accepted", "duplicate", "invalid"]:
    """
    Runs inside the "sanitize" queue worker.

    Flow:
      1. Compute dedupe signature from (title, summary).
      2. If signature already in Redis -> "duplicate".
      3. Else mark signature as seen, finalize story fields, LPUSH to FEED_KEY.
      4. Trim FEED_KEY, broadcast realtime, optional push.

    We DO NOT mutate any previous stories in FEED_KEY.
    First accepted story about an event wins.
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # 1. signature
    sig = story_signature(raw_title, raw_summary)
    if not sig:
        print(f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}")
        return "invalid"

    # 2. dedupe check
    if conn.sismember(SEEN_KEY, sig):
        print(f"[sanitizer] DUPLICATE -> {story.get('id')} | {raw_title}")
        return "duplicate"

    # 3a. mark signature so future duplicates get dropped
    conn.sadd(SEEN_KEY, sig)

    # 3b. finalize story shape so feed+api have consistent fields
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

    # 4. broadcast + maybe push
    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
