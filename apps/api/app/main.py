# apps/api/app/main.py
from __future__ import annotations

import os
import json
import time
from enum import Enum
from datetime import datetime, timezone
from typing import List, Optional, Iterable, Tuple, Callable

from fastapi import FastAPI, HTTPException, Query, Request, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel
from urllib.parse import unquote

# ------------------------------ Redis ----------------------------------------

try:
    import redis  # type: ignore
except Exception as e:  # pragma: no cover
    raise RuntimeError("redis package is required") from e

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FEED_KEY = os.getenv("FEED_KEY", "feed:items")      # LIST, index 0 = newest
MAX_SCAN = int(os.getenv("MAX_SCAN", "400"))        # how deep search/detail can look
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "200"))    # lrange chunk size for scans

# Rate limits (per IP)
RL_FEED_PER_MIN = int(os.getenv("RL_FEED_PER_MIN", "120"))
RL_SEARCH_PER_MIN = int(os.getenv("RL_SEARCH_PER_MIN", "90"))
RL_STORY_PER_MIN = int(os.getenv("RL_STORY_PER_MIN", "240"))

# small timeouts to avoid hanging requests when Redis has issues
_redis_client = redis.from_url(
    REDIS_URL,
    decode_responses=True,
    socket_timeout=float(os.getenv("REDIS_SOCKET_TIMEOUT", "2.0")),
    socket_connect_timeout=float(os.getenv("REDIS_CONNECT_TIMEOUT", "2.0")),
)

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
    release_date: Optional[str] = None            # YYYY-MM-DD when known (or RFC3339)
    is_theatrical: Optional[bool] = None
    is_upcoming: Optional[bool] = None
    ott_platform: Optional[str] = None
    tags: Optional[List[str]] = None
    normalized_at: Optional[str] = None

class FeedResponse(BaseModel):
    tab: str
    since: Optional[str] = None
    items: List[Story]
    next_cursor: Optional[str] = None

class SearchResponse(BaseModel):
    q: str
    items: List[Story]

class ErrorBody(BaseModel):
    ok: bool = False
    status: int
    error: str
    message: str

class FeedTab(str, Enum):
    all = "all"
    trailers = "trailers"
    ott = "ott"
    intheatres = "intheatres"
    comingsoon = "comingsoon"

# ------------------------------ App / CORS -----------------------------------

app = FastAPI(
    title="CinePulse API",
    version="0.3.0",
    description="Feed & story API for CinePulse with cursor pagination and basic rate limiting.",
)

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

# ------------------------------ Error handlers -------------------------------

def _json_error(status_code: int, err: str, msg: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=ErrorBody(status=status_code, error=err, message=msg).model_dump(),
    )

@app.exception_handler(HTTPException)
async def http_exc_handler(_: Request, exc: HTTPException):
    # Normalize FastAPI HTTP errors
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    return _json_error(exc.status_code, "http_error", detail)

@app.exception_handler(RequestValidationError)
async def validation_exc_handler(_: Request, exc: RequestValidationError):
    return _json_error(422, "validation_error", exc.errors().__repr__())

@app.exception_handler(Exception)
async def unhandled_exc_handler(_: Request, exc: Exception):
    # Hide internals but keep a type hint
    return _json_error(500, exc.__class__.__name__, "Internal server error")

# ------------------------------ Rate limiting --------------------------------

def _client_ip(req: Request) -> str:
    # Respect common proxy headers; fall back to client host.
    xff = req.headers.get("x-forwarded-for", "")
    if xff:
        # The first IP in the list is the original client
        return xff.split(",")[0].strip()
    return req.client.host if req.client else "unknown"

def limiter(route: str, limit_per_min: int) -> Callable:
    async def _limit_dep(req: Request):
        ip = _client_ip(req)
        now_bucket = int(time.time() // 60)
        key = f"rl:{route}:{ip}:{now_bucket}"
        try:
            n = _redis_client.incr(key)
            if n == 1:
                _redis_client.expire(key, 65)  # 1 minute + small buffer
            if n > limit_per_min:
                # 429 with uniform error body
                raise HTTPException(
                    status_code=429,
                    detail=f"Rate limit exceeded for {route}; try again shortly",
                )
        except redis.RedisError as e:
            # If Redis limiter fails, we don't block the request—best effort.
            # Optionally log e here.
            _ = e
            return
    return _limit_dep

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

def _redis_lrange(key: str, start: int, stop: int) -> list[str]:
    try:
        return _redis_client.lrange(key, start, stop)
    except Exception as e:
        # Bubble up as 503 so clients know it's transient infra
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {type(e).__name__}") from e

def _iter_feed(max_items: int = MAX_SCAN) -> Iterable[dict]:
    raw = _redis_lrange(FEED_KEY, 0, max(0, max_items - 1))
    for s in raw:
        try:
            yield json.loads(s)
        except Exception:
            continue

def _matches_tab(item: dict, tab: FeedTab) -> bool:
    """
    Tab filter:
      - all
      - trailers  (trailer|teaser|clip|featurette|song|poster)
      - ott       (release-ott|ott|acquisition OR is_theatrical == False OR has ott_platform)
      - intheatres(release-theatrical|schedule-change|re-release|boxoffice OR is_theatrical == True)
      - comingsoon(release_date in future OR is_upcoming == True)
    """
    if tab == FeedTab.all:
        return True

    kind = (item.get("kind") or "").lower()

    if tab == FeedTab.trailers:
        return kind in TRAILER_KINDS

    if tab == FeedTab.ott:
        return (
            kind in OTT_ALIGNED_KINDS
            or item.get("is_theatrical") is False
            or bool(item.get("ott_platform"))
        )

    if tab == FeedTab.intheatres:
        return (
            kind in THEATRICAL_KINDS
            or item.get("is_theatrical") is True
        )

    if tab == FeedTab.comingsoon:
        if item.get("is_upcoming") is True:
            return True
        rd = _parse_iso(item.get("release_date"))
        return bool(rd and rd > datetime.now(timezone.utc))

    return True  # fallback behaves like "all"

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

def _scan_with_cursor(
    start_idx: int,
    limit: int,
    tab: FeedTab,
    since: Optional[str],
) -> Tuple[List[dict], Optional[int]]:
    """
    Scan the Redis LIST from start_idx forward (newest-first list),
    apply filters, and collect up to `limit` items. We cap total scanned
    rows per request at MAX_SCAN for safety.

    Returns (items, next_cursor_index or None).
    Cursor is the absolute Redis list index to resume from.
    NOTE: New inserts at head may shift indices; cursors are best-effort.
    """
    try:
        total_len = _redis_client.llen(FEED_KEY)
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {type(e).__name__}") from e

    if total_len is None:
        total_len = 0

    items: List[dict] = []
    scanned = 0
    idx = max(0, start_idx)

    while len(items) < limit and idx < total_len and scanned < MAX_SCAN:
        # Read a batch
        batch_end = min(idx + BATCH_SIZE - 1, total_len - 1)
        raw_batch = _redis_lrange(FEED_KEY, idx, batch_end)
        if not raw_batch:
            break

        for offset, raw in enumerate(raw_batch):
            pos = idx + offset
            scanned += 1
            try:
                it = json.loads(raw)
            except Exception:
                continue

            if since and not _is_since(it, since):
                continue
            if not _matches_tab(it, tab):
                continue

            items.append(it)
            if len(items) >= limit:
                next_cursor = pos + 1 if (pos + 1) < total_len else None
                return (items, next_cursor)

        idx = batch_end + 1  # move to next window

        if scanned >= MAX_SCAN:
            # We reached our scan budget; indicate where to continue
            next_cursor = idx if idx < total_len else None
            return (items, next_cursor)

    # Exhausted or no more items
    next_cursor = idx if idx < total_len else None
    return (items, next_cursor)

# ------------------------------ Endpoints ------------------------------------

@app.get("/health")
def health():
    try:
        ok = _redis_client.ping()
        feed_len = _redis_client.llen(FEED_KEY)
        err = None
    except Exception as e:  # pragma: no cover
        ok = False
        feed_len = None
        err = f"{type(e).__name__}"
    return {
        "status": "ok" if ok else "degraded",
        "redis": REDIS_URL,
        "feed_key": FEED_KEY,
        "feed_len": feed_len,
        "redis_ok": ok,
        "error": err,
    }

@app.get(
    "/v1/feed",
    response_model=FeedResponse,
    summary="Feed items",
    description="Cursor-paginated feed. Newest-first (best-effort). Use the returned `next_cursor` to fetch the next page.",
)
async def feed(
    request: Request,
    tab: FeedTab = Query(
        FeedTab.all,
        description="Tabs: all | trailers | ott | intheatres | comingsoon",
    ),
    since: Optional[str] = Query(
        None, description="RFC3339; only items with date >= this time (checks release_date → published_at → normalized_at)"
    ),
    cursor: Optional[str] = Query(
        None, description="Opaque cursor returned by the previous page; start from the beginning when omitted"
    ),
    limit: int = Query(20, ge=1, le=100),
    _=Depends(limiter("feed", RL_FEED_PER_MIN)),
):
    # Validate since
    if since is not None and _parse_iso(since) is None:
        raise HTTPException(status_code=422, detail="Invalid 'since' (use RFC3339, e.g. 2025-01-01T00:00:00Z)")

    # Decode cursor (absolute list index); best-effort.
    start_idx = 0
    if cursor:
        try:
            start_idx = int(cursor)
            if start_idx < 0:
                start_idx = 0
        except ValueError:
            # Treat as invalid cursor -> start at 0
            start_idx = 0

    pool, next_idx = _scan_with_cursor(start_idx, limit, tab, since)
    items = [Story(**it) for it in pool]
    next_cursor = str(next_idx) if next_idx is not None else None

    return FeedResponse(tab=tab.value, since=since, items=items, next_cursor=next_cursor)

@app.get(
    "/v1/search",
    response_model=SearchResponse,
    summary="Substring search over title+summary",
)
async def search(
    request: Request,
    q: str = Query(..., min_length=1),
    limit: int = Query(10, ge=1, le=50),
    _=Depends(limiter("search", RL_SEARCH_PER_MIN)),
):
    ql = q.lower()
    res: list[dict] = []
    scanned = 0
    for it in _iter_feed():
        scanned += 1
        hay = f"{it.get('title','')} {(it.get('summary') or '')}".lower()
        if ql in hay:
            res.append(it)
            if len(res) >= limit:
                break
        if scanned >= MAX_SCAN:
            break
    return SearchResponse(q=q, items=[Story(**it) for it in res])

@app.get(
    "/v1/story/{story_id}",
    response_model=Story,
    summary="Story detail by ID",
)
async def story_detail(
    request: Request,
    story_id: str,
    _=Depends(limiter("story", RL_STORY_PER_MIN)),
):
    sid = unquote(story_id)
    for it in _iter_feed():
        if it.get("id") == sid:
            return Story(**it)
    raise HTTPException(status_code=404, detail="Story not found")

@app.get("/")
def root():
    return {"ok": True, "service": "cinepulse-api"}
