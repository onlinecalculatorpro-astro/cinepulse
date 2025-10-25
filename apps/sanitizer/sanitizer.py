# apps/sanitizer/sanitizer.py
from __future__ import annotations

import os
import re
import json
import hashlib
from datetime import datetime, timezone
from typing import Dict, Any, Literal, Optional

from redis import Redis
from rq import Queue

__all__ = [
    "sanitize_story",
    "canonical_title",
    "canonical_summary",
    "story_signature",
]

# ------------------------------------------------------------------------------
# Environment / Redis config
# ------------------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed LIST that the API serves via /v1/feed.
# This list is append-only (newest first) and trimmed to MAX_FEED_LEN.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Set of already-seen story signatures (semantic dedupe memory).
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Max length of FEED_KEY list. 0 or negative disables trimming.
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))

# Realtime fanout targets
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
FEED_STREAM_MAXLEN = int(os.getenv("FEED_STREAM_MAXLEN", "5000"))

# Push toggle
ENABLE_PUSH_NOTIFICATIONS = os.getenv("ENABLE_PUSH_NOTIFICATIONS", "0").lower() not in ("0", "", "false", "no")


def _redis() -> Redis:
    """
    Shared Redis connection for:
    - dedupe memory (SEEN_KEY)
    - writing the feed list (FEED_KEY)
    - pub/sub + stream fanout
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # work with str not bytes
    )


# ------------------------------------------------------------------------------
# Text normalization for signature generation
# ------------------------------------------------------------------------------

# Words / hype / filler we don't want to affect uniqueness.
_STOPWORDS = {
    "breaking",
    "exclusive",
    "watch",
    "watchnow",
    "watchnow!",
    "watchnow!!",
    "watch now",
    "teaser",
    "trailer",
    "first",
    "look",
    "firstlook",
    "first look",
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
    "confirms",
    "confirmed",
    "confirm",
    "big",
    "huge",
    "massive",
    "viral",
    "shocking",
    "omg",
    "omgg",
    "omggg",
    "🔥",
    "🔥🔥",
    "🔥🔥🔥",
}

# Summary boilerplate / footer spam we don't want to count toward meaning.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# Map any non [a-z0-9 whitespace] to space.
_CLEAN_RE = re.compile(r"[^a-z0-9\s]+", re.IGNORECASE)


def _strip_noise_words(words: list[str]) -> list[str]:
    """
    Remove cheap hype words like 'breaking', 'exclusive', etc.
    These don't change the factual identity of the story.
    """
    kept: list[str] = []
    for w in words:
        lw = w.strip().lower()
        if not lw:
            continue
        if lw in _STOPWORDS:
            continue
        kept.append(lw)
    return kept


def canonical_title(raw_title: str) -> str:
    """
    Produce a normalized "meaning text" from the story title:
    - lowercase
    - strip punctuation / emojis / symbols
    - remove hype/filler words
    - collapse whitespace
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: Optional[str]) -> str:
    """
    Produce a normalized "meaning text" from the story summary/description:
    - lowercase
    - remove footer spam like "follow us on instagram"
    - strip punctuation / emojis / symbols
    - remove hype/filler words
    - collapse whitespace

    May return "" if summary is useless or missing.
    """
    if not raw_summary:
        return ""

    s = raw_summary.lower()

    # strip boilerplate tails like "follow us", "click here", etc.
    for pat in _SUMMARY_FOOTER_PATTERNS:
        s = re.sub(pat, "", s, flags=re.IGNORECASE)

    s = _CLEAN_RE.sub(" ", s)
    words = s.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def story_signature(title: str, summary: Optional[str]) -> str:
    """
    Build a short signature representing the "news event" this story is about.

    We derive a canonical_title and canonical_summary, then hash them together.
    - If two different publishers describe the same event in different wording,
      their canonical forms should still collide -> same signature.
    - If they're actually different events (box office vs teaser drop),
      canonical forms should differ -> different signature.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    if not canon_t:
        return ""  # can't classify without any meaningful title core

    combo = f"title:{canon_t}||summary:{canon_s}"
    digest = hashlib.sha1(combo.encode("utf-8")).hexdigest()
    return digest[:16]  # short stable ID for Redis


# ------------------------------------------------------------------------------
# Realtime fanout + optional push enqueue
# ------------------------------------------------------------------------------

def _publish_realtime(conn: Redis, story: dict) -> None:
    """
    Tell interested consumers that a NEW (ACCEPTED) story just landed.
    We fan out two ways:
    - Pub/Sub channel FEED_PUBSUB
    - Redis stream FEED_STREAM (capped length)
    """
    try:
        payload = {
            "id": story.get("id"),
            "kind": story.get("kind"),
            "normalized_at": story.get("normalized_at"),
            "ingested_at": story.get("ingested_at"),
            "title": story.get("title"),
            "source": story.get("source"),
            "source_domain": story.get("source_domain"),
            "url": story.get("url"),
            "thumb_url": story.get("thumb_url"),
        }

        # Fire-and-forget Pub/Sub
        conn.publish(FEED_PUBSUB, json.dumps(payload, ensure_ascii=False))

        # Append to capped stream for dashboards / live clients
        try:
            conn.xadd(
                FEED_STREAM,
                {
                    "id": payload["id"] or "",
                    "kind": payload["kind"] or "",
                    "ts": payload["normalized_at"] or "",
                },
                maxlen=FEED_STREAM_MAXLEN,
                approximate=True,
            )
        except Exception:
            pass

    except Exception as e:
        print(f"[sanitizer] realtime publish error: {e}")


def _enqueue_push(conn: Redis, story: dict) -> None:
    """
    Enqueue a push notification job in the 'push' queue (handled by a separate
    push worker if you run one). We only do this for ACCEPTED stories.
    """
    if not ENABLE_PUSH_NOTIFICATIONS:
        return

    try:
        Queue("push", connection=conn).enqueue(
            "apps.workers.push.send_story_push",  # job function to implement elsewhere
            story,
            ttl=600,
            result_ttl=60,
            failure_ttl=600,
            job_timeout=30,
        )
    except Exception as e:
        print(f"[sanitizer] push enqueue error: {e}")


# ------------------------------------------------------------------------------
# Main job entrypoint for the sanitizer container
# ------------------------------------------------------------------------------

def sanitize_story(story: Dict[str, Any]) -> Literal["accepted", "duplicate", "invalid"]:
    """
    This is the function that the 'sanitizer' RQ worker runs for each job.

    Input:
        story (dict)  - A fully normalized story produced by workers.normalize_event().
                        Expected fields include:
                        - id
                        - title
                        - summary
                        - kind
                        - thumb_url / image
                        - source / source_domain
                        - ingested_at / normalized_at
                        - url
                        etc.

    Behavior:
      1. Build signature from story.title + story.summary.
      2. Check Redis SET (SEEN_KEY):
         - If signature already seen -> DUPLICATE -> drop.
         - If new -> accept:
             a. Record signature in SEEN_KEY.
             b. Push story JSON into FEED_KEY list (newest-first).
             c. Trim FEED_KEY to MAX_FEED_LEN.
             d. Publish realtime fanout.
             e. Optionally enqueue push job.

      3. We DO NOT go back and "upgrade" or "replace" older stories.
         First story wins. All later rewrites of same event are ignored.
         That is intentional.

    Returns:
        "accepted"  -> story published to feed
        "duplicate" -> story ignored (already covered that event)
        "invalid"   -> story missing meaningful title core
    """

    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # Compute signature
    sig = story_signature(raw_title, raw_summary)
    if not sig:
        # missing usable title core means we can't classify this story at all
        print(f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}")
        return "invalid"

    # Check if we've already covered this "news event"
    if conn.sismember(SEEN_KEY, sig):
        # DUPLICATE:
        # We've already approved a story with essentially this meaning.
        # Do not publish again. Do not modify the original.
        print(f"[sanitizer] DUPLICATE -> {story.get('id')} | {raw_title}")
        return "duplicate"

    # ACCEPTED path:
    # 1. Mark signature as seen so future clones are dropped.
    conn.sadd(SEEN_KEY, sig)

    # 2. Insert into public feed list (newest first).
    #    We store the raw story dict as JSON.
    try:
        conn.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
    except Exception as e:
        print(f"[sanitizer] ERROR LPUSH feed for {story.get('id')}: {e}")

    # 3. Trim feed list for memory hygiene.
    if MAX_FEED_LEN > 0:
        try:
            conn.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)
        except Exception as e:
            print(f"[sanitizer] ERROR LTRIM feed: {e}")

    # 4. Broadcast realtime + enqueue optional push.
    #    We timestamp here just in case workers somehow didn't set normalized_at.
    if not story.get("normalized_at"):
        story["normalized_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]

    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
