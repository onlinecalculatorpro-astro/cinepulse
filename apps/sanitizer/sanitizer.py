# apps/workers/sanitizer.py
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

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Public feed list that infra-api-1 serves via /v1/feed.
# This should already exist in your system.
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# NEW: Redis set for signatures we've already accepted.
# This prevents duplicates.
SEEN_KEY = os.getenv("SEEN_KEY", "feed:seen_signatures")

# Safety: keep feed list bounded so it doesn't grow forever.
# 0 or negative disables trimming.
MAX_FEED_LEN = int(os.getenv("MAX_FEED_LEN", "200"))


def _redis() -> Redis:
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,  # store/read strings, not bytes
    )


# ------------------------------------------------------------------------------
# Text normalization helpers
# ------------------------------------------------------------------------------

# Words/phrases we consider "hype noise" or boilerplate that shouldn't
# make two stories look "different".
_STOPWORDS = {
    "breaking",
    "exclusive",
    "watch",
    "watch now",
    "watchnow",
    "teaser",
    "trailer",
    "first",
    "look",
    "first look",
    "revealed",
    "official",
    "officially",
    "now",
    "just",
    "out",
    "finally",
    "drops",
    "dropped",
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
    "big",
    "huge",
    "massive",
    "viral",
    "shocking",
    "omg",
    "🔥",
    "🔥🔥",
}

# Phrases commonly found in RSS summaries / footers that don't describe the
# actual story content and would create fake differences between sources.
_SUMMARY_FOOTER_PATTERNS = [
    r"read (the )?full story.*$",
    r"click here.*$",
    r"for more updates.*$",
    r"follow us on.*$",
    r"stay tuned.*$",
    r"all rights reserved.*$",
]

# Regex to strip punctuation, emojis, symbols → turn into spaces.
# We keep only letters, numbers, whitespace.
_CLEAN_RE = re.compile(r"[^a-z0-9\s]+", re.IGNORECASE)


def _strip_noise_words(words: list[str]) -> list[str]:
    """Remove filler like 'breaking', 'exclusive', 'watch now', etc."""
    kept = []
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
    Normalize the story title down to its meaning:
    - lowercase
    - strip punctuation/emojis
    - remove filler / hype words
    - collapse spaces

    If this ends up empty, caller should treat story as invalid.
    """
    t = (raw_title or "").lower()
    t = _ CLEAN_RE.sub(" ", t)
    words = t.split()
    words = _strip_noise_words(words)
    return " ".join(words).strip()


def canonical_summary(raw_summary: str | None) -> str:
    """
    Normalize the summary / description so we capture the factual core:
    - lowercase
    - strip punctuation/emojis
    - remove boilerplate like "follow us on insta"
    - remove filler / hype words
    - collapse spaces

    Can return "" if there's nothing useful.
    """
    if not raw_summary:
        return ""

    s = raw_summary.lower()

    # kill boilerplate footer lines we don't care about
    for pat in _SUMMARY_FOOTER_PATTERNS:
        s
