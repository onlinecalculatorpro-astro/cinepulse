# apps/sanitizer/sanitizer.py
from __future__ import annotations

import os
import re
import json
import hashlib
from typing import Dict, Any, Literal

from redis import Redis

__all__ = [
    "sanitize_and_publish",
    "canonical_title",
    "canonical_summary",
    "story_signature",
]

# ------------------------------------------------------------------------------
# Environment / Redis config
# ------------------------------------------------------------------------------

# Redis connection (same Redis the rest of the stack uses)
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed LIST key that infra-api-1 serves through /v1/feed.
# Must match what your API container is already reading.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# Redis SET key that tracks which story "events" we've already accepted.
# This prevents duplicates from ever getting into FEED_KEY.
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Safety: limit how long FEED_KEY can grow.
# If >0, we'll ltrim to this many newest items after each ACCEPTED insert.
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))


def _redis() -> Redis:
    """Return a Redis client using the configured REDIS_URL."""
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # get/set str instead of bytes
    )


# ------------------------------------------------------------------------------
# Text normalization helpers
# ------------------------------------------------------------------------------

# Words/phrases that add hype but not meaning. We drop these so
# two headlines with different drama still match as "same event".
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

# Boilerplate summary/footer junk we don't want to count as "meaning".
# We strip lines like "click here", "follow us on Instagram", etc.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# Regex to kill punctuation/emojis/symbols → replace with space.
# We only keep letters, numbers, whitespace.
_CLEAN_RE = re.compile(r"[^a-z0-9\s]+", re.IGNORECASE)


def _strip_noise_words(words: list[str]) -> list[str]:
    """
    Remove hype words like 'breaking', 'exclusive', 'watch now', etc.
    Return the list of meaning-carrying tokens.
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
    Normalize the story title down to its core meaning:
    - lowercase
    - strip punctuation/emojis/symbols
    - drop hype/filler words
    - collapse extra spaces

    If result is empty, the caller should consider the story invalid.
    """
    t = (raw_title or "").lower()
    t = _CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: str | None) -> str:
    """
    Normalize the story summary / description:
    - lowercase
    - remove boilerplate promo/footer lines ("follow us on ...", etc.)
    - strip punctuation/emojis/symbols
    - drop hype/filler words
    - collapse extra spaces

    Can return "" if nothing useful.
    """
    if not raw_summary:
        return ""

    s = raw_summary.lower()

    # remove boilerplate footer / CTA lines we don't want to influence matching
    for pat in _SUMMARY_FOOTER_PATTERNS:
        s = re.sub(pat, "", s, flags=re.IGNORECASE)

    s = _CLEAN_RE.sub(" ", s)
    words = s.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def story_signature(title: str, summary: str | None) -> str:
    """
    Build a stable signature representing the *event* this story talks about.

    We combine canonical_title + canonical_summary, then hash.
    If summary is missing/empty we fall back to title only.

    Stories that describe the same event (even with different spicy wording)
    should yield the same signature. Different events should not.
    """
    canon_t = canonical_title(title)
    canon_s = canonical_summary(summary)

    # If we can't even get a canonical title, we can't classify.
    if not canon_t:
        return ""

    # Combine title + summary meaning. Summary may be empty.
    combo = f"title:{canon_t}||summary:{canon_s}"

    digest = hashlib.sha1(combo.encode("utf-8")).hexdigest()
    # Shorten for Redis friendliness.
    return digest[:16]


# ------------------------------------------------------------------------------
# Main sanitizer gate
# ------------------------------------------------------------------------------

def sanitize_and_publish(story: Dict[str, Any]) -> Literal["accepted", "duplicate", "invalid"]:
    """
    Gatekeeper called by workers AFTER they've normalized a story.

    Responsibilities:
    - Build a signature from the story's meaning (title+summary).
    - Check if we've already accepted that signature.
      - If yes  -> duplicate -> drop (do not publish again).
      - If no   -> first time -> publish to feed list and record signature.
    - Never "upgrade" or "replace" an older story.
    - Keep the feed list trimmed to MAX_FEED_LEN if configured.

    Returns:
      "accepted"  -> story added to FEED_KEY
      "duplicate" -> story skipped (already covered this event)
      "invalid"   -> missing usable title/signature
    """

    # Pull basic fields worker should already have normalized.
    raw_title = (story.get("title") or "").strip()
    raw_summary = story.get("summary")

    # Build signature.
    sig = story_signature(raw_title, raw_summary)

    # If we can't form a signature at all, we consider this invalid.
    if not sig:
        return "invalid"

    r = _redis()

    # Check if we've seen this event already.
    if r.sismember(SEEN_KEY, sig):
        # We've already accepted a story with essentially this meaning.
        # Do NOT publish again.
        return "duplicate"

    # First time we've seen this event:
    # 1. Mark signature as seen so future clones get dropped.
    r.sadd(SEEN_KEY, sig)

    # 2. Publish story JSON into the public feed list.
    # LPUSH = newest first.
    r.lpush(FEED_KEY, json.dumps(story))

    # 3. Trim the list to MAX_FEED_LEN if enabled.
    if MAX_FEED_LEN > 0:
        r.ltrim(FEED_KEY, 0, MAX_FEED_LEN - 1)

    return "accepted"
