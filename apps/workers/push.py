# apps/workers/push.py
#
# ROLE:
#   This file runs in the "push" RQ worker.
#
#   The sanitizer calls:
#       Queue("push").enqueue("apps.workers.push.send_story_push", story, ...)
#
#   We:
#     - pick which topics should get this alert
#     - collect device tokens subscribed to those topics
#     - build a compact notification payload
#     - deliver one push per token (stubbed: print/debug, ready for FCM wiring)
#
# IMPORTANT:
#   - If you don't run a push worker, nothing breaks in feed delivery.
#   - ENABLE_PUSH_NOTIFICATIONS in sanitizer controls whether sanitize even
#     enqueues us.
#
# REDIS KEYS (must match apps/api/app/push.py):
#   PUSH_SET           -> SET of all known tokens
#   PUSH_META          -> HASH   token -> JSON blob {platform, lang, topics, ts}
#   PUSH_TOPIC_PREFIX  -> per-topic SET of tokens, e.g. "push:topic:entertainment"
#   PUSH_DEFAULT_TOPIC -> fallback topic (usually "all")
#
# TOPIC ROUTING:
#   We generate candidate topics from:
#     - story["verticals"]      (e.g. ["entertainment", "sports"])
#     - story["tags"]           (e.g. ["trailer", "now-streaming"])
#     - default "all"
#
#   Tokens that subscribe to any of those topics get pinged.
#
# PAYLOAD SHAPE (example):
#   {
#       "title": "Deadpool & Wolverine trailer drops",
#       "body": "Ryan Reynolds and Hugh Jackman reunite in the MCU...",
#       "url": "https://example.com/story",
#       "image": "https://api.your/api/v1/img?u=...",
#       "story_id": "rss:pinkvilla.com:abc123",
#       "kind": "trailer"
#   }
#
#   Right now we just print the payload. You can replace _send_platform_push()
#   to actually call FCM/APNs/Expo/etc.
#

from __future__ import annotations

import json
import os
import re
import time
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from redis import Redis

# -------------------------------------------------------------------
# Env / redis config
# -------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

PUSH_SET = os.getenv("PUSH_SET", "push:tokens")
PUSH_META = os.getenv("PUSH_META", "push:meta")
PUSH_TOPIC_PREFIX = os.getenv("PUSH_TOPIC_PREFIX", "push:topic:")
DEFAULT_TOPIC = os.getenv("PUSH_DEFAULT_TOPIC", "all")

# Safety valve: if you want an emergency kill-switch for pushes at runtime.
PUSH_ENABLED = os.getenv("PUSH_ENABLED", "1").lower() not in ("0", "false", "no", "")

# Basic limits so one noisy story doesn't fan out to millions at once.
MAX_TOKENS_PER_STORY = int(os.getenv("PUSH_MAX_TOKENS_PER_STORY", "5000"))

# Truncate body text for notification preview.
PUSH_BODY_MAX_CHARS = int(os.getenv("PUSH_BODY_MAX_CHARS", "180"))


def _redis() -> Redis:
    return Redis.from_url(
        REDIS_URL,
        decode_responses=True,
    )


# -------------------------------------------------------------------
# helpers: topic normalization & selection
# -------------------------------------------------------------------

_valid_topic_char = re.compile(r"[a-z0-9_\-:\.]")

def _norm_topic(t: str) -> Optional[str]:
    """
    Keep only safe lowercase chars [a-z0-9_-.:], match API behavior.
    """
    if not t:
        return None
    t = t.strip().lower()
    cleaned = "".join(ch for ch in t if _valid_topic_char.match(ch))
    return cleaned or None


def _dedupe_norm_topics(values: Iterable[str]) -> List[str]:
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
    Decide which push topic buckets this story should notify.

    We include:
      - verticals (entertainment, sports, etc.)
      - tags      (trailer, now-streaming, box-office, match-result, etc.)
      - DEFAULT_TOPIC ('all')
    """
    verts = story.get("verticals") or []
    tags = story.get("tags") or []

    raw_topics: List[str] = []
    if isinstance(verts, list):
        raw_topics.extend(str(v) for v in verts)
    if isinstance(tags, list):
        raw_topics.extend(str(t) for t in tags)

    # always include global/fallback
    raw_topics.append(DEFAULT_TOPIC)

    return _dedupe_norm_topics(raw_topics)


# -------------------------------------------------------------------
# helpers: build notification text
# -------------------------------------------------------------------

def _truncate(s: str, limit: int) -> str:
    if not s:
        return ""
    s = s.strip()
    if len(s) <= limit:
        return s
    # basic ellipsis
    return (s[: max(0, limit - 1)].rstrip() + "…").strip()


def _build_notification_payload(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    Create a platform-agnostic notification blob.
    You can adapt/transform this per-platform in _send_platform_push().
    """

    title = (story.get("title") or "").strip()
    body_raw = (story.get("summary") or "").strip()

    body = _truncate(body_raw, PUSH_BODY_MAX_CHARS)

    # choose a hero image if available
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


# -------------------------------------------------------------------
# "send" stub
# -------------------------------------------------------------------

def _send_platform_push(platform: str, token: str, notif: Dict[str, Any], meta: Dict[str, Any]) -> bool:
    """
    Deliver one push to one device token.

    RIGHT NOW:
      - We just print() and return True.
    HOW TO EXTEND:
      - If you want real pushes, this is where you call FCM/APNs/etc.
      - Use `platform` ("android" / "ios" / "web") to route.
      - Use `meta["lang"]` if you want localized titles later.
    """
    try:
        print(
            "[push] deliver",
            json.dumps(
                {
                    "platform": platform,
                    "token": token[:12] + "…",  # don't spam full token
                    "notif": notif,
                },
                ensure_ascii=False,
            ),
        )
        return True
    except Exception as e:
        print(f"[push] ERROR sending to {platform} token={token[:12]}… -> {e}")
        return False


# -------------------------------------------------------------------
# main RQ entrypoint
# -------------------------------------------------------------------

def send_story_push(story: Dict[str, Any]) -> Dict[str, Any]:
    """
    RQ job entrypoint.

    1. Figure out story topics.
    2. Collect all tokens subscribed to ANY of those topics.
    3. For each token:
         - read its meta from PUSH_META
         - send notification
    4. Return stats for logging / debugging.

    NOTE:
    - If PUSH_ENABLED is false, we no-op (but still return a result).
    - We hard-cap MAX_TOKENS_PER_STORY to avoid blast radius.
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

    if not PUSH_ENABLED:
        stats["disabled"] = True
        print(f"[push] PUSH_ENABLED=0, skipping push for story {story.get('id')}")
        return stats

    # figure out which topics we should broadcast to
    topics = _topics_for_story(story)
    stats["topics"] = topics

    if not topics:
        print(f"[push] no topics for story {story.get('id')}, skipping")
        return stats

    r = _redis()
    try:
        # collect unique tokens from all topics
        tokens: Set[str] = set()
        for t in topics:
            try:
                key = f"{PUSH_TOPIC_PREFIX}{t}"
                members = r.smembers(key) or []
                for tok in members:
                    if tok:
                        tokens.add(tok)
            except Exception as e:
                print(f"[push] WARN could not smembers({t}): {e}")

        # hard cap
        token_list = list(tokens)[:MAX_TOKENS_PER_STORY]

        stats["tokens_considered"] = len(token_list)

        if not token_list:
            print(f"[push] no subscribers for topics={topics}")
            return stats

        # build push payload once per story
        notif = _build_notification_payload(story)

        # read all token metadata in one go (pipeline-ish)
        # PUSH_META is a HASH: token -> json(meta)
        for tok in token_list:
            raw_meta = r.hget(PUSH_META, tok)
            if not raw_meta:
                # token known in topic set but no meta -> skip
                stats["skipped"] += 1
                continue

            try:
                meta = json.loads(raw_meta)
            except Exception:
                meta = {}

            platform = (meta.get("platform") or "").strip().lower()
            if platform not in ("android", "ios", "web"):
                # unknown platform -> skip
                stats["skipped"] += 1
                continue

            # send it
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
        # nothing fancy, just clean close
        try:
            r.close()
        except Exception:
            pass
