# apps/sanitizer/sanitizer.py
#
# PIPELINE ROLE (this container = the "sanitize" RQ worker):
#
#   scheduler  → polls sources and enqueues ingest jobs
#   workers    → normalize each raw item into a canonical story dict
#                 (title, summary, kind, url, thumb_url, timestamps, etc.)
#               then enqueue sanitize_story(story) onto the "sanitize" queue
#   sanitizer  → THIS FILE, running under rq worker sanitize
#               - decide if story is NEW or a DUPLICATE of something we already published
#               - only the FIRST version wins; later variants are ignored
#               - if NEW:
#                   * append story JSON into Redis FEED_KEY (newest first)
#                   * trim FEED_KEY to MAX_FEED_LEN
#                   * publish realtime fanout (pubsub + redis stream)
#                   * optionally enqueue push notification job
#
#   api        → serves /v1/feed by reading FEED_KEY
#
# IMPORTANT GUARANTEES:
# - workers no longer write to FEED_KEY directly.
# - workers no longer do dedupe.
# - sanitizer is the single gatekeeper for what hits the public feed.
#
# DEDUPE STRATEGY:
# - We compute a "signature" from the canonicalized title + canonicalized summary.
#   We strip hype words like "BREAKING", "exclusive", "trailer", etc.
#   We strip boilerplate like "follow us on insta".
# - We SHA1 that normalized text and keep it in a Redis SET (SEEN_KEY).
# - If we've already seen that signature, this story is dropped as "duplicate".
# - We do NOT upgrade/replace previous stories. First one wins permanently.
#
# RETURNS from sanitize_story():
#   "accepted"   -> went into feed
#   "duplicate"  -> dropped because same news already exists
#   "invalid"    -> dropped because we couldn't build a meaningful signature
#
# ENV VARS this relies on (see .env.example):
#   REDIS_URL
#   FEED_KEY
#   SEEN_KEY
#   MAX_FEED_LEN
#   FEED_PUBSUB
#   FEED_STREAM
#   FEED_STREAM_MAXLEN
#   ENABLE_PUSH_NOTIFICATIONS
#
# NOTE: We intentionally do not enforce industry filters, etc. here. The API can
# choose to filter when serving if you want region-specific feeds.


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
# Env / Redis config
# ------------------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed LIST that clients read via /v1/feed (newest-first).
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Redis SET of "we have already accepted this event".
# Keys are short hashes of canonical(title+summary).
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Safety bound: we trim FEED_KEY to this length after every insert.
# <=0 means "never trim".
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))

# Realtime fanout targets.
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
FEED_STREAM_MAXLEN = int(os.getenv("FEED_STREAM_MAXLEN", "5000"))

# Toggle to enqueue push notifications after we ACCEPT a story.
ENABLE_PUSH_NOTIFICATIONS = os.getenv("ENABLE_PUSH_NOTIFICATIONS", "0").lower() not in (
    "0",
    "",
    "false",
    "no",
)


def _redis() -> Redis:
    """
    Make a Redis client:
    - used for dedupe set (SEEN_KEY),
    - writing/trim of FEED_KEY,
    - pub/sub + stream fanout,
    - optional push queue enqueue context.
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # get/set str instead of bytes
    )


# ------------------------------------------------------------------------------
# Canonicalization helpers for dedupe
# ------------------------------------------------------------------------------

# Words / hype / filler we ignore when forming "meaning":
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
    "announcer",
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
}

# Footer spam / boilerplate commonly tacked onto summaries that shouldn't
# make two otherwise identical stories look "different".
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# We'll normalize by dropping everything except letters/numbers/whitespace.
# (emojis, punctuation, punctuation-like emphasis all turn into spaces)
_CLEAN_RE = re.compile(r"[^a-z0-9\s]+", re.IGNORECASE)


def _strip_noise_words(words: list[str]) -> list[str]:
    """
    Drop hype-y filler terms ("breaking", "exclusive", "watch now", etc.).
    They change style but not core meaning.
    """
    keep: list[str] = []
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
    Lowercase the title, scrub punctuation/emojis, remove hype words,
    then collapse to a single space-separated string.

    If the result is empty, we basically don't trust this story as a
    unique "event".
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: Optional[str]) -> str:
    """
    Similar to canonical_title() but for the summary/description.
    - Remove generic footer CTA lines like "follow us on insta"
    - Strip punctuation/emojis/etc.
    - Remove hype words
    - Collapse whitespace

    Returns "" if there's no meaningful body text.
    """
    if not raw_summary:
        return ""

    s = raw_summary.lower()

    # kill footer noise lines (works line-by-line because we use MULTILINE)
    for pat in _SUMMARY_FOOTER_PATTERNS:
        s = re.sub(pat, "", s, flags=re.IGNORECASE | re.MULTILINE)

    s = _CLEAN_RE.sub(" ", s)
    words = s.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def story_signature(title: str, summary: Optional[str]) -> str:
    """
    Produce a deterministic short signature string that stands for
    "this news event".

    Steps:
    - Build canonical title and summary
    - Concatenate
    - SHA1 hash -> first 16 hex chars as a stable ID

    If canonical_title is empty, we return "" to mark the story invalid.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    if not canon_t:
        return ""  # can't even identify what this is

    blob = f"title:{canon_t}||summary:{canon_s}"
    digest = hashlib.sha1(blob.encode("utf-8")).hexdigest()
    return digest[:16]


# ------------------------------------------------------------------------------
# Fanout + optional push
# ------------------------------------------------------------------------------

def _publish_realtime(conn: Redis, story: dict) -> None:
    """
    Broadcast that a NEW story was ACCEPTED.
    We send:
      - Pub/Sub message on FEED_PUBSUB
      - XADD into FEED_STREAM (capped length)
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

        # Pub/Sub notify lightweight consumers / websockets bridges / etc.
        conn.publish(FEED_PUBSUB, json.dumps(payload, ensure_ascii=False))

        # Also add a minimal event into a capped Redis Stream for dashboards / tails.
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
            # Stream problems shouldn't block ingestion
            pass

    except Exception as e:
        print(f"[sanitizer] realtime publish error: {e}")


def _enqueue_push(conn: Redis, story: dict) -> None:
    """
    Optionally schedule a push notification job into the "push" queue,
    which is processed by a separate push worker (not in this file).
    """
    if not ENABLE_PUSH_NOTIFICATIONS:
        return

    try:
        Queue("push", connection=conn).enqueue(
            "apps.workers.push.send_story_push",  # implement separately
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
    This is what the sanitizer RQ worker runs for each normalized story.

    1. Build a signature from (title, summary)
    2. If signature already in SEEN_KEY -> DUPLICATE
    3. Else:
       - add signature to SEEN_KEY
       - LPUSH story JSON to FEED_KEY (newest first)
       - LTRIM FEED_KEY to MAX_FEED_LEN
       - publish realtime fanout
       - maybe enqueue push

    We DO NOT modify past feed items. First one wins forever.

    Returns:
        "accepted"   - story published
        "duplicate"  - story dropped (already had this event)
        "invalid"    - story dropped (title too empty to fingerprint)
    """
    conn = _redis()

    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # 1. generate a dedupe signature
    sig = story_signature(raw_title, raw_summary)
    if not sig:
        # We couldn't even form a meaningful canonical title.
        print(f"[sanitizer] INVALID (no canonical title) -> {story.get('id')} | {raw_title}")
        return "invalid"

    # 2. check if we've already seen this "event"
    if conn.sismember(SEEN_KEY, sig):
        # DUPLICATE -> ignore gracefully, don't mutate the winner.
        print(f"[sanitizer] DUPLICATE -> {story.get('id')} | {raw_title}")
        return "duplicate"

    # 3. ACCEPTED path
    # Record this signature so future clones will be skipped.
    conn.sadd(SEEN_KEY, sig)

    # Make sure timestamps exist before we serialize (helps realtime consumers)
    if not story.get("normalized_at"):
        story["normalized_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if not story.get("ingested_at"):
        story["ingested_at"] = story["normalized_at"]

    # Push into public feed (LPUSH = newest-first)
    try:
        conn.lpush(FEED_KEY, json.dumps(story, ensure_ascii=False))
    except Exception as e:
        print(f"[sanitizer] ERROR LPUSH feed for {story.get('id')}: {e}")

    # Trim feed list for size control
    if MAX_FEED_LEN > 0:
        try:
            conn.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)
        except Exception as e:
            print(f"[sanitizer] ERROR LTRIM feed: {e}")

    # Realtime + optional push
    _publish_realtime(conn, story)
    _enqueue_push(conn, story)

    print(f"[sanitizer] ACCEPTED -> {story.get('id')} | {raw_title}")
    return "accepted"
