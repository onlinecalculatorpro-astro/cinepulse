# apps/workers/push.py
#
# ROLE (push worker):
#   - Runs in the dedicated RQ worker queue "push".
#   - Called by sanitizer.sanitize_story() *after* a story is accepted
#     into the public feed (only if ENABLE_PUSH_NOTIFICATIONS is on).
#
#   The sanitizer does:
#       Queue("push").enqueue(
#           "apps.workers.push.send_story_push",
#           story,
#           ...
#       )
#
#   This worker:
#     1. Figures out which push "topics" this story is relevant to.
#        Examples:
#           story.verticals  -> ["entertainment"]
#           story.tags       -> ["trailer", "now-streaming"]
#           DEFAULT_TOPIC    -> "all"
#
#     2. Looks up all device tokens subscribed to ANY of those topics in Redis.
#
#     3. Builds a compact notification payload from the story
#        (title, summary teaser, URL, image, etc.).
#
#     4. Sends a push per token using _send_platform_push().
#
# IMPORTANT BEHAVIOR:
#   - If you never run the "push" worker, feed quality is still fine.
#     You still ingest, dedupe, expose /v1/feed, etc.
#
#   - PUSH_ENABLED can hard-disable fanout even if sanitizer enqueues us.
#
#   - MAX_TOKENS_PER_STORY prevents a single story from blasting millions
#     of pushes at once. Tweak with PUSH_MAX_TOKENS_PER_STORY.
#
#   - _send_platform_push() is the only part you need to replace to
#     integrate FCM/APNs/Expo/OneSignal/etc. Everything else is vendor-agnostic.
#
# REDIS CONTRACT (same data model as apps/api/app/push.py):
#
#   PUSH_SET             (SET)
#       all known tokens
#
#   PUSH_META            (HASH)
#       key: <token>
#       val: JSON like:
#           {
#             "platform": "android" | "ios" | "web",
#             "lang": "en" | "hi" | ... | null,
#             "topics": ["entertainment","trailer","all"],
#             "ts": 1730000000  (last updated unix timestamp)
#           }
#
#   PUSH_TOPIC_PREFIX + <topic>    (SET)
#       every device token that opted into that topic
#
#   DEFAULT_TOPIC
#       fallback broadcast bucket ("all")
#
# TOPIC SELECTION FOR A STORY:
#   We'll push to union(topics from story.verticals, story.tags, DEFAULT_TOPIC).
#
#   Example story:
#       {
#          "id": "rss:koimoi.com:abcd123",
#          "title": "James Gunn calls X best Spider-Man ever",
#          "summary": "James Gunn once praised ...",
#          "verticals": ["entertainment"],
#          "tags": ["hollywood", "trailer"],
#          "thumb_url": "https://api.../v1/img?u=...",
#          "url": "https://www.koimoi.com/.../when-james-gunn-...",
#          "kind": "news",
#          ...
#       }
#
#   -> topics_to_notify might become:
#          ["entertainment", "hollywood", "trailer", "all"]
#
# NOTIFICATION PAYLOAD WE BUILD PER STORY:
#   {
#     "title": "James Gunn calls X best Spider-Man ever",
#     "body": "James Gunn once praised ...",
#     "url": "https://www.koimoi.com/.../when-james-gunn-...",
#     "image": "https://api.../v1/img?u=...",
#     "story_id": "rss:koimoi.com:abcd123",
#     "kind": "news",
#     "ts": 1730000000
#   }
#
#   That dict is passed to _send_platform_push(platform, token, notif, meta)
#   for each token. By default we just print it; replace that function to do
#   actual delivery (FCM/APNs/etc.).
#

from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from redis import Redis

__all__ = ["send_story_push"]


# =============================================================================
# Environment / Redis config
# =============================================================================

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# MUST match apps/api/app/push.py
PUSH_SET = os.getenv("PUSH_SET", "push:tokens")                  # SET of all tokens
PUSH_META = os.getenv("PUSH_META", "push:meta")                  # HASH token -> json(meta)
PUSH_TOPIC_PREFIX = os.getenv("PUSH_TOPIC_PREFIX", "push:topic:")# prefix for per-topic sets
DEFAULT_TOPIC = os.getenv("PUSH_DEFAULT_TOPIC", "all")           # fallback broadcast topic

# Runtime kill switch (lets you pause push fanout without redeploying sanitizer)
PUSH_ENABLED = os.getenv("PUSH_ENABLED", "1").lower() not in (
    "0",
    "false",
    "no",
    "",
)

# Safety cap: if a story routes to way too many tokens,
# we only take the first N for this job run.
MAX_TOKENS_PER_STORY = int(os.getenv("PUSH_MAX_TOKENS_PER_STORY", "5000"))

# The notification "body" is built from story["summary"] but clipped
# so it fits common push preview lengths.
PUSH_BODY_MAX_CHARS = int(os.getenv("PUSH_BODY_MAX_CHARS", "180"))


def _redis() -> Redis:
    """
    Get a decode_responses=True Redis handle so we get str objects
    not bytes.
    """
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,
    )


# =============================================================================
# Topic helpers
# =============================================================================

# allowed chars for topics: lowercase alnum + _-:.
_VALID_TOPIC_CHAR_RE = re.compile(r"[a-z0-9_\-:\.]")

def _norm_topic(topic: str) -> Optional[str]:
    """
    Normalize a single topic to safe lowercase: keep only [a-z0-9_\-:.].
    Returns None if the result is empty.
    """
    if not topic:
        return None
    t = topic.strip().lower()
    cleaned = "".join(ch for ch in t if _VALID_TOPIC_CHAR_RE.match(ch))
    return cleaned or None


def _dedupe_norm_topics(values: Iterable[str]) -> List[str]:
    """
    Take a list of raw topics and return a unique, normalized list.
    Order is stable: first time we see it wins.
    """
    out: List[str] = []
    seen: Set[str] = set()
    for v in values:
        n = _norm_topic(v)
        if n and n not in seen:
            seen.add(n)
            out.append(n)
    return out


def _topics_for_story(story: Dict[str, Any]) -> List[str]:
    """
    Decide which push-topic buckets get notified for this story.

    We include:
      - story["verticals"] (e.g. ["entertainment", "sports"])
      - story["tags"] (e.g. ["trailer", "box-office", "now-streaming"])
      - DEFAULT_TOPIC (usually "all")

    We do NOT include story["kind"] automatically because "kind"
    (e.g. "release", "news", "trailer") is often already duplicated
    inside tags like "trailer".
    If you want to blast based on kind, add it here.
    """
    verts = story.get("verticals") or []
    tags = story.get("tags") or []

    raw_topics: List[str] = []
    if isinstance(verts, list):
        raw_topics.extend(str(v) for v in verts)
    if isinstance(tags, list):
        raw_topics.extend(str(t) for t in tags)

    # Always include global broadcast bucket.
    raw_topics.append(DEFAULT_TOPIC)

    return _dedupe_norm_topics(raw_topics)


# =============================================================================
# Notification shaping
# =============================================================================

def _truncate_preview(text: str, limit: int) -> str:
    """
    Cap text at 'limit' characters and add an ellipsis if truncated.
    """
    if not text:
        return ""
    s = text.strip()
    if len(s) <= limit:
        return s
    return (s[: max(0, limit - 1)].rstrip() + "…").strip()


def _build_notification_payload(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert a story dict (as produced by workers.jobs.normalize_event,
    then lightly massaged by sanitizer) into a generic push payload.

    This result is platform-agnostic. _send_platform_push() can adapt it
    for iOS/Android/Web if you integrate a real push vendor.
    """
    title = (story.get("title") or "").strip()
    body_raw = (story.get("summary") or "").strip()
    body = _truncate_preview(body_raw, PUSH_BODY_MAX_CHARS)

    # Pick a hero image (the API will usually proxy this through /v1/img already).
    img = (
        story.get("thumb_url")
        or story.get("image")
        or story.get("thumbnail")
        or story.get("poster")
        or story.get("media")
        or None
    )

    return {
        "title": title,
        "body": body,
        "url": story.get("url"),
        "image": img,
        "story_id": story.get("id"),
        "kind": story.get("kind"),
        "ts": int(time.time()),
    }


# =============================================================================
# Delivery stub (replace this with FCM/APNs/etc.)
# =============================================================================

def _send_platform_push(platform: str, token: str, notif: Dict[str, Any], meta: Dict[str, Any]) -> bool:
    """
    Send one push to one device token.

    RIGHT NOW:
      - We just print() and pretend success.
      - We mask most of the token so logs aren't full of secrets.

    EXTEND FOR REAL PUSH:
      - Use 'platform' to branch to the right provider:
            "android" => FCM
            "ios"     => APNs
            "web"     => Web Push / VAPID
      - The 'meta' dict includes 'lang' so you can localize.
      - The 'notif' dict is the generic payload we built above.
    """
    try:
        token_preview = token[:12] + "…" if len(token) > 12 else token
        print(
            "[push] deliver",
            json.dumps(
                {
                    "platform": platform,
                    "token": token_preview,
                    "notif": notif,
                },
                ensure_ascii=False,
            ),
        )
        return True
    except Exception as e:
        print(f"[push] ERROR sending to {platform} token={token[:12]}… -> {e}")
        return False


# =============================================================================
# RQ entrypoint
# =============================================================================

def send_story_push(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    RQ job entrypoint called by sanitizer.

    What we do:
      1. Bail out early if PUSH_ENABLED is false (runtime kill switch).
      2. Compute a set of relevant topics using _topics_for_story().
      3. Union all subscriber tokens from those per-topic Redis sets.
      4. Build a single notification payload for this story.
      5. For each token:
            - Look up device meta in PUSH_META
            - Call _send_platform_push(platform, token, notif, meta)
      6. Return stats for logs / debugging.

    We *don't* raise exceptions for individual send failures.
    We try everyone we can, then return summary stats.

    Returns:
        {
          "ok": True,
          "story_id": "...",
          "topics": [...],
          "tokens_considered": 123,
          "sent": 120,
          "skipped": 3,
          "disabled": False,
        }
    """
    stats = {
        "ok": True,
        "story_id": story.get("id"),
        "topics": [],
        "tokens_considered": 0,
        "sent": 0,
        "skipped": 0,
        "disabled": False,
    }

    # Kill switch
    if not PUSH_ENABLED:
        stats["disabled"] = True
        print(f"[push] PUSH_ENABLED=0, skipping push for story {story.get('id')}")
        return stats

    # Figure out which topics get pinged
    topics = _topics_for_story(story)
    stats["topics"] = topics

    if not topics:
        # It's valid for a story to have no tags/verticals, but then we still
        # have DEFAULT_TOPIC so this shouldn't happen. If it does, abort cleanly.
        print(f"[push] no topics for story {story.get('id')}, skipping fanout")
        return stats

    r = _redis()
    try:
        # Collect unique tokens across all topics
        tokens: Set[str] = set()
        for t in topics:
            try:
                key = f"{PUSH_TOPIC_PREFIX}{t}"
                members = r.smembers(key) or []
                for tok in members:
                    if tok:
                        tokens.add(tok)
            except Exception as e:
                print(f"[push] WARN smembers({t}) failed: {e}")

        # Enforce blast radius cap
        token_list = list(tokens)[:MAX_TOKENS_PER_STORY]
        stats["tokens_considered"] = len(token_list)

        if not token_list:
            print(f"[push] no subscribers for topics={topics}")
            return stats

        # Build the notification for this story once
        notif = _build_notification_payload(story)

        # For each token, read its metadata from PUSH_META (HASH)
        for tok in token_list:
            raw_meta = r.hget(PUSH_META, tok)
            if not raw_meta:
                # token appears in topic set but we have no metadata -> skip it
                stats["skipped"] += 1
                continue

            try:
                meta = json.loads(raw_meta)
            except Exception:
                meta = {}

            platform = (meta.get("platform") or "").strip().lower()
            if platform not in ("android", "ios", "web"):
                # ignore unknown platforms instead of crashing
                stats["skipped"] += 1
                continue

            delivered = _send_platform_push(platform, tok, notif, meta)
            if delivered:
                stats["sent"] += 1
            else:
                stats["skipped"] += 1

        print(
            "[push] done",
            json.dumps(
                {
                    "story_id": story.get("id"),
                    "topics": topics,
                    "attempted": stats["tokens_considered"],
                    "sent": stats["sent"],
                    "skipped": stats["skipped"],
                },
                ensure_ascii=False,
            ),
        )

        return stats

    finally:
        # Don't leave hanging TCP connections in long-lived RQ workers
        try:
            r.close()
        except Exception:
            pass
