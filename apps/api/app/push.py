# apps/api/app/push.py
from __future__ import annotations

import json
import os
import time
import contextlib
from typing import Literal, Optional, Iterable

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, validator
from redis.asyncio import Redis as AsyncRedis

router = APIRouter(prefix="/v1/push", tags=["push"])

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
PUSH_SET = os.getenv("PUSH_SET", "push:tokens")               # SET of all tokens
PUSH_META = os.getenv("PUSH_META", "push:meta")               # HASH token -> json(meta)
PUSH_TOPIC_PREFIX = os.getenv("PUSH_TOPIC_PREFIX", "push:topic:")
DEFAULT_TOPIC = os.getenv("PUSH_DEFAULT_TOPIC", "all")


def _redis() -> AsyncRedis:
    return AsyncRedis.from_url(REDIS_URL, decode_responses=True)


def _norm_topic(t: str) -> Optional[str]:
    """Normalize/validate topic names: lowercase, allow a-z0-9:_-. """
    if not t:
        return None
    t2 = "".join(ch for ch in t.strip().lower() if ch.isalnum() or ch in ("_", "-", ":", "."))
    return t2 or None


def _norm_topics(topics: Iterable[str]) -> list[str]:
    out: list[str] = []
    for t in topics or []:
        n = _norm_topic(t)
        if n and n not in out:
            out.append(n)
    return out


class RegisterBody(BaseModel):
    token: str = Field(min_length=10)
    platform: Literal["android", "ios", "web"]
    lang: Optional[str] = None
    topics: list[str] = []

    @validator("topics", pre=True)
    def _v_topics(cls, v):
        return _norm_topics(v or [])


class UpdateTopicsBody(BaseModel):
    token: str = Field(min_length=10)
    topics: list[str] = []

    @validator("topics", pre=True)
    def _v_topics(cls, v):
        return _norm_topics(v or [])


class PatchTopicsBody(BaseModel):
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
    token: str = Field(min_length=10)
    aggressive_cleanup: bool = False  # scan all topic keys if meta missing


@router.post("/register")
async def register(b: RegisterBody):
    """
    Register/refresh a device token, upsert metadata and join topics.
    """
    r = _redis()
    try:
        topics = b.topics or [DEFAULT_TOPIC]
        meta = {"platform": b.platform, "lang": b.lang, "topics": topics, "ts": int(time.time())}

        await r.sadd(PUSH_SET, b.token)
        await r.hset(PUSH_META, b.token, json.dumps(meta, ensure_ascii=False))
        if topics:
            await r.sadd(*(f"{PUSH_TOPIC_PREFIX}{t}" for t in topics), b.token) if len(topics) > 1 else await r.sadd(f"{PUSH_TOPIC_PREFIX}{topics[0]}", b.token)

        return {"ok": True, "token": b.token, "topics": topics}
    finally:
        await r.aclose()


@router.put("/topics")
async def replace_topics(b: UpdateTopicsBody):
    """
    Replace token's topic set atomically (unsubscribe old, subscribe new).
    """
    r = _redis()
    try:
        # Ensure token is known
        if not await r.sismember(PUSH_SET, b.token):
            raise HTTPException(status_code=404, detail="Unknown token")

        # Load current meta
        raw = await r.hget(PUSH_META, b.token)
        cur = json.loads(raw) if raw else {}
        old_topics: list[str] = _norm_topics(cur.get("topics") or [])
        new_topics: list[str] = b.topics or [DEFAULT_TOPIC]

        # Compute diffs
        old_set, new_set = set(old_topics), set(new_topics)
        to_add = list(new_set - old_set)
        to_del = list(old_set - new_set)

        # Update per-topic membership
        for t in to_add:
            await r.sadd(f"{PUSH_TOPIC_PREFIX}{t}", b.token)
        for t in to_del:
            await r.srem(f"{PUSH_TOPIC_PREFIX}{t}", b.token)

        # Save meta
        cur.update({"topics": new_topics, "ts": int(time.time())})
        await r.hset(PUSH_META, b.token, json.dumps(cur, ensure_ascii=False))

        return {"ok": True, "token": b.token, "topics": new_topics, "added": to_add, "removed": to_del}
    finally:
        await r.aclose()


@router.post("/topics/patch")
async def patch_topics(b: PatchTopicsBody):
    """
    Add/remove topics without replacing the entire list.
    """
    r = _redis()
    try:
        if not await r.sismember(PUSH_SET, b.token):
            raise HTTPException(status_code=404, detail="Unknown token")

        raw = await r.hget(PUSH_META, b.token)
        cur = json.loads(raw) if raw else {"topics": [DEFAULT_TOPIC]}
        topics = set(_norm_topics(cur.get("topics") or []))

        # Apply patch
        for t in b.add:
            topics.add(t)
            await r.sadd(f"{PUSH_TOPIC_PREFIX}{t}", b.token)
        for t in b.remove:
            topics.discard(t)
            await r.srem(f"{PUSH_TOPIC_PREFIX}{t}", b.token)

        # Ensure at least DEFAULT_TOPIC
        if not topics:
            topics.add(DEFAULT_TOPIC)
            await r.sadd(f"{PUSH_TOPIC_PREFIX}{DEFAULT_TOPIC}", b.token)

        cur.update({"topics": sorted(topics), "ts": int(time.time())})
        await r.hset(PUSH_META, b.token, json.dumps(cur, ensure_ascii=False))

        return {"ok": True, "token": b.token, "topics": cur["topics"]}
    finally:
        await r.aclose()


@router.post("/unregister")
async def unregister(b: UnregisterBody):
    """
    Unregister a token: remove from global set, meta, and topic memberships.
    If meta is missing and aggressive_cleanup=True, SCAN all topic keys to SREM.
    """
    r = _redis()
    try:
        # Remove from meta and get topics (if present)
        raw = await r.hget(PUSH_META, b.token)
        topics = []
        if raw:
            with contextlib.suppress(Exception):
                topics = _norm_topics((json.loads(raw) or {}).get("topics") or [])

        await r.srem(PUSH_SET, b.token)
        await r.hdel(PUSH_META, b.token)

        # Best-effort topic cleanup
        for t in topics:
            await r.srem(f"{PUSH_TOPIC_PREFIX}{t}", b.token)

        if not topics and b.aggressive_cleanup:
            # Fallback: scan topic keys and try to SREM
            cursor = 0
            pattern = f"{PUSH_TOPIC_PREFIX}*"
            while True:
                cursor, keys = await r.scan(cursor=cursor, match=pattern, count=200)
                if keys:
                    for k in keys:
                        await r.srem(k, b.token)
                if cursor == 0:
                    break

        return {"ok": True, "token": b.token, "removed_topics": topics}
    finally:
        await r.aclose()


@router.get("/stats")
async def stats():
    """
    Lightweight stats: total tokens and top N topics by membership.
    """
    r = _redis()
    try:
        total = int(await r.scard(PUSH_SET))
        # Sample topics via SCAN (best-effort)
        cursor = 0
        topic_counts: list[tuple[str, int]] = []
        pattern = f"{PUSH_TOPIC_PREFIX}*"
        # limit the scan work to avoid heavy calls
        rounds = 0
        while rounds < 20:
            cursor, keys = await r.scan(cursor=cursor, match=pattern, count=200)
            for k in keys[:200]:
                with contextlib.suppress(Exception):
                    c = int(await r.scard(k))
                    topic = k.replace(PUSH_TOPIC_PREFIX, "", 1)
                    topic_counts.append((topic, c))
            rounds += 1
            if cursor == 0:
                break
        # sort and cap
        topic_counts.sort(key=lambda x: x[1], reverse=True)
        top = topic_counts[:20]
        return {"ok": True, "total_tokens": total, "topics_sample": top}
    finally:
        await r.aclose()
