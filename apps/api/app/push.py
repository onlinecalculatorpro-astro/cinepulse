# apps/api/app/push.py
from __future__ import annotations

import contextlib
import json
import os
import time
from typing import Iterable, Literal, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, validator
from redis.asyncio import Redis as AsyncRedis

router = APIRouter(prefix="/v1/push", tags=["push"])

# -----------------------------------------------------------------------------
# Env / Redis config
# -----------------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")

# Global set of all active tokens
PUSH_SET = os.getenv("PUSH_SET", "push:tokens")

# Hash: token -> serialized metadata
# metadata example:
# {
#   "platform": "android" | "ios" | "web",
#   "lang": "en",
#   "topics": ["all", "trailer-alerts"],
#   "ts": 1700000000
# }
PUSH_META = os.getenv("PUSH_META", "push:meta")

# Per-topic sets:
#   f"{PUSH_TOPIC_PREFIX}{topic}" -> set(tokens)
PUSH_TOPIC_PREFIX = os.getenv("PUSH_TOPIC_PREFIX", "push:topic:")

# Fallback topic if client doesn't send any
DEFAULT_TOPIC = os.getenv("PUSH_DEFAULT_TOPIC", "all")


def _redis() -> AsyncRedis:
    """
    Create a short-lived async Redis client.
    We open/close per-request instead of reusing a global connection. This
    keeps uvicorn workers isolated and avoids weird connection reuse bugs.
    """
    return AsyncRedis.from_url(
        REDIS_URL,
        decode_responses=True,
    )


# -----------------------------------------------------------------------------
# Topic normalization
# -----------------------------------------------------------------------------

def _norm_topic(t: str) -> Optional[str]:
    """
    Normalize / validate individual topic names.
    - lowercase
    - allow alnum + [ _ - : . ]
    - "" → None
    """
    if not t:
        return None
    t2 = "".join(
        ch
        for ch in t.strip().lower()
        if ch.isalnum() or ch in ("_", "-", ":", ".")
    )
    return t2 or None


def _norm_topics(topics: Iterable[str]) -> list[str]:
    """
    Deduplicate and normalize a list of topic strings.
    """
    out: list[str] = []
    for t in topics or []:
        n = _norm_topic(t)
        if n and n not in out:
            out.append(n)
    return out


# -----------------------------------------------------------------------------
# Request bodies
# -----------------------------------------------------------------------------

class RegisterBody(BaseModel):
    """
    Register (or refresh) a push token. Also sets initial topic
    subscriptions. If topics is empty, we'll auto-subscribe DEFAULT_TOPIC.

    platform is stored so push-worker can decide how to fan out.
    """
    token: str = Field(min_length=10)
    platform: Literal["android", "ios", "web"]
    lang: Optional[str] = None
    topics: list[str] = []

    @validator("topics", pre=True)
    def _v_topics(cls, v):
        return _norm_topics(v or [])


class UpdateTopicsBody(BaseModel):
    """
    Replace ALL topics for a given token.
    """
    token: str = Field(min_length=10)
    topics: list[str] = []

    @validator("topics", pre=True)
    def _v_topics(cls, v):
        return _norm_topics(v or [])


class PatchTopicsBody(BaseModel):
    """
    Add/remove topics for an existing token without replacing the entire set.
    """
    token: str = Field(min_length=10)
    add: list[str] = []
    remove: list[str] = []

    @validator("add", pre=True)
    def _v_add(cls, v):
        return _norm_topics(v or [])

    @validator("remove", pre=True)
    def _v_remove(cls, v):
        return _norm_topics(v or [])


class UnregisterBody(BaseModel):
    """
    Remove a token completely.
    If aggressive_cleanup=True and we can't read its meta, we SCAN topic keys
    to try and evict it anyway. (Heavier but helps clean up old tokens.)
    """
    token: str = Field(min_length=10)
    aggressive_cleanup: bool = False


# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

async def _load_meta(r: AsyncRedis, token: str) -> dict:
    """
    Fetch token metadata from PUSH_META. Returns {} if missing/bad JSON.
    """
    raw = await r.hget(PUSH_META, token)
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


async def _save_meta(
    r: AsyncRedis,
    token: str,
    meta: dict,
) -> None:
    """
    Store updated metadata for a token.
    """
    meta["ts"] = int(time.time())
    await r.hset(PUSH_META, token, json.dumps(meta, ensure_ascii=False))


async def _set_topics_for_token(
    r: AsyncRedis,
    token: str,
    topics: list[str],
) -> None:
    """
    Subscribe token to each topic in `topics`. Does NOT unsubscribe from old topics.
    Caller is responsible for removals.
    """
    for t in topics:
        await r.sadd(f"{PUSH_TOPIC_PREFIX}{t}", token)


async def _remove_topics_for_token(
    r: AsyncRedis,
    token: str,
    topics: list[str],
) -> None:
    """
    Unsubscribe token from given topics.
    """
    for t in topics:
        await r.srem(f"{PUSH_TOPIC_PREFIX}{t}", token)


# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

@router.post("/register")
async def register(b: RegisterBody):
    """
    Register/refresh a device token.

    - Put token in global PUSH_SET
    - Upsert metadata in PUSH_META
    - Subscribe token to provided topics (or DEFAULT_TOPIC if none)

    Response:
    {
      "ok": true,
      "token": "...",
      "topics": ["all","trailer-alerts", ...]
    }
    """
    r = _redis()
    try:
        topics = b.topics or [DEFAULT_TOPIC]

        meta = {
            "platform": b.platform,
            "lang": b.lang,
            "topics": topics,
        }

        await r.sadd(PUSH_SET, b.token)
        await _save_meta(r, b.token, meta)
        await _set_topics_for_token(r, b.token, topics)

        return {"ok": True, "token": b.token, "topics": topics}
    finally:
        await r.aclose()


@router.put("/topics")
async def replace_topics(b: UpdateTopicsBody):
    """
    Replace a token's entire topic list atomically:
    - Load old topics
    - Compute add/remove sets
    - Update per-topic membership
    - Save meta.topics

    Response:
    {
      "ok": true,
      "token": "...",
      "topics": [... new full list ...],
      "added": [...],
      "removed": [...]
    }
    """
    r = _redis()
    try:
        # must already be registered
        if not await r.sismember(PUSH_SET, b.token):
            raise HTTPException(status_code=404, detail="Unknown token")

        cur_meta = await _load_meta(r, b.token)
        old_topics = _norm_topics(cur_meta.get("topics") or [])
        new_topics = b.topics or [DEFAULT_TOPIC]

        old_set, new_set = set(old_topics), set(new_topics)
        to_add = sorted(new_set - old_set)
        to_del = sorted(old_set - new_set)

        await _set_topics_for_token(r, b.token, to_add)
        await _remove_topics_for_token(r, b.token, to_del)

        cur_meta["topics"] = new_topics
        await _save_meta(r, b.token, cur_meta)

        return {
            "ok": True,
            "token": b.token,
            "topics": new_topics,
            "added": to_add,
            "removed": to_del,
        }
    finally:
        await r.aclose()


@router.post("/topics/patch")
async def patch_topics(b: PatchTopicsBody):
    """
    Add/remove topics for this token, without blowing away the rest.

    Steps:
    - Load current meta (or create a default if missing)
    - Add 'add' topics
    - Remove 'remove' topics
    - If result becomes empty, force DEFAULT_TOPIC
    - Write meta + membership sets

    Response:
    {
      "ok": true,
      "token": "...",
      "topics": ["all","trailer-alerts", ...]
    }
    """
    r = _redis()
    try:
        if not await r.sismember(PUSH_SET, b.token):
            raise HTTPException(status_code=404, detail="Unknown token")

        cur_meta = await _load_meta(r, b.token)
        # fallback if meta disappeared:
        topics = set(_norm_topics(cur_meta.get("topics") or [])) or {DEFAULT_TOPIC}

        # add
        for t in b.add:
            topics.add(t)
        # remove
        for t in b.remove:
            topics.discard(t)

        # guarantee at least DEFAULT_TOPIC
        if not topics:
            topics.add(DEFAULT_TOPIC)

        # sync Redis topic sets
        # add set
        await _set_topics_for_token(r, b.token, list(b.add))
        # remove set
        await _remove_topics_for_token(r, b.token, list(b.remove))

        # ensure DEFAULT_TOPIC membership if we had to re-add it
        if DEFAULT_TOPIC in topics and DEFAULT_TOPIC not in cur_meta.get("topics", []):
            await r.sadd(f"{PUSH_TOPIC_PREFIX}{DEFAULT_TOPIC}", b.token)

        final_topics = sorted(topics)
        cur_meta["topics"] = final_topics
        await _save_meta(r, b.token, cur_meta)

        return {"ok": True, "token": b.token, "topics": final_topics}
    finally:
        await r.aclose()


@router.post("/unregister")
async def unregister(b: UnregisterBody):
    """
    Fully unregister a token.

    Process:
    - Remove token from PUSH_SET
    - Remove token's meta from PUSH_META
    - Remove token from each topic set:
        * We try to read topics from meta first.
        * If meta missing and aggressive_cleanup=True, SCAN all topic keys.

    Response:
    {
      "ok": true,
      "token": "...",
      "removed_topics": ["all","trailer-alerts", ...]
    }
    """
    r = _redis()
    try:
        # get current topics before delete
        cur_meta = await _load_meta(r, b.token)
        topics = _norm_topics(cur_meta.get("topics") or [])

        # remove from global + meta
        await r.srem(PUSH_SET, b.token)
        await r.hdel(PUSH_META, b.token)

        # clean up known topics
        for t in topics:
            await r.srem(f"{PUSH_TOPIC_PREFIX}{t}", b.token)

        # fallback cleanup if we didn't know the topics and caller asked for it
        if (not topics) and b.aggressive_cleanup:
            cursor = 0
            pattern = f"{PUSH_TOPIC_PREFIX}*"
            # walk a bounded number of steps to avoid a full Redis scan storm
            steps = 0
            while True:
                cursor, keys = await r.scan(cursor=cursor, match=pattern, count=200)
                for k in keys:
                    await r.srem(k, b.token)
                steps += 1
                if cursor == 0 or steps >= 50:
                    break

        return {"ok": True, "token": b.token, "removed_topics": topics}
    finally:
        await r.aclose()


@router.get("/stats")
async def stats():
    """
    Lightweight stats for dashboards / debugging.

    Returns totals and a sampled view of topic membership counts.
    We deliberately cap the scan work so this can't DOS Redis.
    """
    r = _redis()
    try:
        total_tokens = int(await r.scard(PUSH_SET))

        topic_counts: list[tuple[str, int]] = []
        cursor = 0
        pattern = f"{PUSH_TOPIC_PREFIX}*"

        rounds = 0
        while rounds < 20:
            cursor, keys = await r.scan(cursor=cursor, match=pattern, count=200)
            # We only sample each round's keys, not necessarily all keys.
            for k in keys[:200]:
                with contextlib.suppress(Exception):
                    c = int(await r.scard(k))
                    topic = k.replace(PUSH_TOPIC_PREFIX, "", 1)
                    topic_counts.append((topic, c))
            rounds += 1
            if cursor == 0:
                break

        topic_counts.sort(key=lambda x: x[1], reverse=True)
        top_sample = topic_counts[:20]

        return {
            "ok": True,
            "total_tokens": total_tokens,
            "topics_sample": top_sample,
        }
    finally:
        await r.aclose()
