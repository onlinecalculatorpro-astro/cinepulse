# apps/api/push.py
from __future__ import annotations
import os, json, time
from typing import Literal, Optional
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from redis.asyncio import Redis as AsyncRedis

router = APIRouter(prefix="/v1/push", tags=["push"])

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
PUSH_SET = os.getenv("PUSH_SET", "push:tokens")           # SET of tokens
PUSH_META = os.getenv("PUSH_META", "push:meta")           # HASH token -> json
PUSH_TOPIC_PREFIX = os.getenv("PUSH_TOPIC_PREFIX", "push:topic:")

def _redis() -> AsyncRedis:
    return AsyncRedis.from_url(REDIS_URL, decode_responses=True)

class RegisterBody(BaseModel):
    token: str = Field(min_length=10)
    platform: Literal["android","ios","web"]
    lang: Optional[str] = None
    topics: list[str] = []

@router.post("/register")
async def register(b: RegisterBody):
    r = _redis()
    try:
        await r.sadd(PUSH_SET, b.token)
        meta = {"platform": b.platform, "lang": b.lang, "topics": b.topics, "ts": int(time.time())}
        await r.hset(PUSH_META, b.token, json.dumps(meta))
        for t in b.topics:
            await r.sadd(f"{PUSH_TOPIC_PREFIX}{t}", b.token)
        return {"ok": True}
    finally:
