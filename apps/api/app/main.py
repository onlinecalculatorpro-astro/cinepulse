# apps/api/app/main.py
from __future__ import annotations

import os
import json
from datetime import datetime, timezone
from typing import List, Optional, Iterable

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ------------------------------ Redis ----------------------------------------

try:
    import redis  # type: ignore
except Exception as e:  # pragma: no cover
    raise RuntimeError("redis package is required") from e

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
r = redis.from_url(REDIS_URL, decode_responses=True)

FEED_KEY = os.getenv("FEED_KEY", "feed:items")  # LIST, index 0 = newest
MAX_SCAN = int(os.getenv("MAX_SCAN", "400"))    # how deep search/detail can look

# ------------------------------ Models ---------------------------------------

class Story(BaseModel):
    id: str
    kind: str
    title: str
    summary: Optional[str] = None
    published_at: Optional[str] = None  # RFC3339 (UTC)
    source: Optional[str] = None
    thumb_url: Optional[str] = None

    # --- New (enriched) optional fields exposed by the worker ---
    url: Optional[str] = None
    source_domain: Optional[str] = None
    poster_url: Optional[str] = None
    release_date: Optional[str] = None            # YYYY-MM-DD when known
    is_theatrical: Optional[bool] = None
    is_upcoming: Optional[bool] = None
    ott_platform: Optional[str] = None
    tags: Optional[List[str]] = None
    normalized_at: Optional[str] = None

class FeedResponse(BaseModel):
    tab: str
    since: Optional[str] = None
    items: List[Story]

# ------------------------------ App / CORS -----------------------------------

app = FastAPI(title="CinePulse API", version="0.2.0")

_cors = os.getenv("CORS_ORIGINS", "*").strip()
if _cors == "*":
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

# ------------------------------ Helpers --------------------------------------

# Buckets for the UI tabs
TRAILER_KINDS = {
    "trailer", "teaser", "clip", "featurette", "song", "poster",
}
OTT_ALIGNED_KINDS = {
    "release-ott", "ott", "acquisition",
}
THEATRICAL_KINDS = {
    "release-theatrical", "schedule-change", "re-release", "boxoffice",
}

def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    """Parse RFC3339/ISO8601 into UTC-aware datetime."""
    if not s:
        return None
    try:
        # allow trailing 'Z'
        if s.endswith("Z"):
            return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return None


def _load_feed_slice(n: int) -> list[dict]:
    """Return up to n newest stories as dicts; skip bad JSON."""
    raw = r.lrange(FEED_KEY, 0, max(0, n - 1))
    out: list[dict] = []
    for s in raw:
        try:
            out.append(json.loads(s))
        except Exception:
            # ignore corrupt entries
            continue
    return out


def _iter_feed(max_items: int = MAX_SCAN) -> Iterable[dict]:
    raw = r.lrange(FEED_KEY, 0, max(0, max_items - 1))
    for s in raw:
        try:
            yield json.loads(s)
        except Exception:
            continue


def _matches_tab(item: dict, tab: str) -> bool:
    """
    Tab filter:
      - all
      - trailers  (trailer|teaser|clip|featurette|song|poster)
      - ott       (release-ott|ott|acquisition OR is_theatrical == False OR has ott_platform)
      - intheatres(release-theatrical|schedule-change|re-release|boxoffice OR is_theatrical == True)
      - comingsoon(release_date in future OR is_upcoming == True)
    """
    t = (tab or "all").lower()
    if t in ("all", ""):
        return True

    kind = (item.get("kind") or "").lower()

    if t in ("trailers", "trailer"):
        return kind in TRAILER_KINDS

    if t == "ott":
        return (
            kind in OTT_ALIGNED_KINDS
            or item.get("is_theatrical") is False
            or bool(item.get("ott_platform"))
        )

    if t == "intheatres":
        return (
            kind in THEATRICAL_KINDS
            or item.get("is_theatrical") is True
        )

    if t == "comingsoon":
        # Prefer explicit is_upcoming if present, else future release_date
        if item.get("is_upcoming") is True:
            return True
        rd = _parse_iso(item.get("release_date"))
        return bool(rd and rd > datetime.now(timezone.utc))

    # Fallback: include (acts like "all")
    return True


def _is_since(item: dict, since_iso: Optional[str]) -> bool:
    if not since_iso:
        return True
    since_dt = _parse_iso(since_iso)
    if not since_dt:
        return True

    # Prefer release_date, else published_at, else normalized_at
    s = item.get("release_date") or item.get("published_at") or item.get("normalized_at")
    dt = _parse_iso(s)
    return bool(dt and dt >= since_dt)

# ------------------------------ Endpoints ------------------------------------

@app.get("/health")
def health():
    return {
        "status": "ok",
        "redis": REDIS_URL,
        "feed_key": FEED_KEY,
        "feed_len": r.llen(FEED_KEY),  # list length
    }


@app.get("/v1/feed", response_model=FeedResponse)
def feed(
    tab: str = Query(
        "all",
        description="Tabs: all | trailers | ott | intheatres | comingsoon",
    ),
    since: Optional[str] = Query(None, description="RFC3339; only items >= this time"),
    limit: int = Query(20, ge=1, le=100),
):
    # Load extra so tab/since filters don't starve results
    pool = _load_feed_slice(limit * 4)

    if since:
        pool = [it for it in pool if _is_since(it, since)]

    pool = [it for it in pool if _matches_tab(it, tab)]

    items = [Story(**it) for it in pool[:limit]]
    return FeedResponse(tab=tab, since=since, items=items)


@app.get("/v1/search")
def search(
    q: str = Query(..., min_length=1),
    limit: int = Query(10, ge=1, le=50),
):
    ql = q.lower()
    res: list[dict] = []
    for it in _iter_feed():
        hay = f"{it.get('title','')} {(it.get('summary') or '')}".lower()
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


@app.get("/")
def root():
    return {"ok": True, "service": "cinepulse-api"}
