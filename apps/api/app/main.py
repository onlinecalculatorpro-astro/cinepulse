# apps/api/app/main.py
from __future__ import annotations

import os
import json
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ---- Redis client ------------------------------------------------------------
try:
    import redis  # type: ignore
except Exception as e:  # pragma: no cover
    raise RuntimeError("redis package is required") from e

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
r = redis.from_url(REDIS_URL, decode_responses=True)

FEED_KEY = "feed:items"          # list of JSON stories, newest at index 0
MAX_SCAN = 400                   # how deep we scan for search/detail


# ---- Models ------------------------------------------------------------------
class Story(BaseModel):
    id: str
    # trailer | release | ott | bo | award (we use trailer/ott for now)
    kind: str
    title: str
    summary: Optional[str] = None
    published_at: Optional[str] = None   # RFC3339 string
    source: Optional[str] = None
    thumb_url: Optional[str] = None


class FeedResponse(BaseModel):
    tab: str
    since: Optional[str] = None
    items: List[Story]


# ---- App & CORS --------------------------------------------------------------
app = FastAPI(title="CinePulse API", version="0.1.0")

_cors = os.getenv("CORS_ORIGINS", "*")
if _cors.strip() == "*":
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip() for o in _cors.split(",") if o.strip()],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )


# ---- Helpers -----------------------------------------------------------------
def _load_feed_slice(n: int) -> list[dict]:
    """Return up to n newest stories as dicts."""
    raw = r.lrange(FEED_KEY, 0, max(0, n - 1))
    out: list[dict] = []
    for s in raw:
        try:
            out.append(json.loads(s))
        except Exception:
            continue
    return out


def _iter_feed(max_items: int = MAX_SCAN):
    raw = r.lrange(FEED_KEY, 0, max(0, max_items - 1))
    for s in raw:
        try:
            yield json.loads(s)
        except Exception:
            continue


def _matches_tab(item: dict, tab: str) -> bool:
    k = (item.get("kind") or "").lower()
    t = tab.lower()
    if t in ("all", "", None):
        return True
    if t in ("trailers", "trailer"):
        return k == "trailer"
    if t in ("ott", "release", "releases"):
        return k in ("ott", "release")
    return True


# ---- Endpoints ----------------------------------------------------------------
@app.get("/health")
def health():
    return {
        "status": "ok",
        "redis": REDIS_URL,
        "feed_len": r.llen(FEED_KEY),
    }


@app.get("/v1/feed", response_model=FeedResponse)
def feed(
    tab: str = Query("all", description="all | trailers | ott"),
    since: Optional[str] = Query(
        None, description="RFC3339 string; return newer than this"),
    limit: int = Query(20, ge=1, le=100),
):
    # Load a little extra so filtering by tab doesn't starve results
    pool = _load_feed_slice(limit * 4)
    if since:
        pool = [it for it in pool if (it.get("published_at") or "") > since]
    pool = [it for it in pool if _matches_tab(it, tab)]
    items = [Story(**it) for it in pool[:limit]]
    return FeedResponse(tab=tab, since=since, items=items)


@app.get("/v1/search")
def search(q: str = Query(..., min_length=1), limit: int = Query(10, ge=1, le=50)):
    ql = q.lower()
    res: list[dict] = []
    for it in _iter_feed():
        hay = f"{it.get('title','')} {it.get('summary','') or ''}".lower()
        if ql in hay:
            res.append(it)
            if len(res) >= limit:
                break
    return {"q": q, "items": [Story(**it) for it in res]}


@app.get("/v1/story/{story_id}", response_model=Story)
def story_detail(story_id: str):
    for it in _iter_feed():
        if it.get("id") == story_id:
            return Story(**it)
    raise HTTPException(status_code=404, detail="Story not found")
