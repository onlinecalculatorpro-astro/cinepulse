# apps/api/app/main.py
from __future__ import annotations

import json
import os
import time
from enum import Enum
from datetime import datetime, timezone
from typing import Callable, Iterable, List, Optional, Tuple
from urllib.parse import quote, unquote

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from apps.api.app.config import settings  # <- central env / config

# ------------------------------ Redis ----------------------------------------

try:
    import redis  # type: ignore
except Exception as e:  # pragma: no cover
    raise RuntimeError("redis package is required") from e

# These come from env because they're runtime-tuning knobs for this API layer,
# not global pipeline config.
MAX_SCAN = int(os.getenv("MAX_SCAN", "400"))            # how deep feed/search/detail can look
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "200"))        # lrange chunk size for scans

# Rate limits (per IP)
RL_FEED_PER_MIN = int(os.getenv("RL_FEED_PER_MIN", "120"))
RL_SEARCH_PER_MIN = int(os.getenv("RL_SEARCH_PER_MIN", "90"))
RL_STORY_PER_MIN = int(os.getenv("RL_STORY_PER_MIN", "240"))

# Public URL for proxy rewriting (used by _to_proxy)
API_PUBLIC_BASE_URL = os.getenv(
    "API_PUBLIC_BASE_URL",
    "https://api.onlinecalculatorpro.org",
).strip().rstrip("/")

# Reuse the same Redis that workers/sanitizer write to.
# We pull redis_url + feed_key from pydantic settings.
_redis_client = redis.from_url(
    settings.redis_url,
    decode_responses=True,  # return str not bytes
    socket_timeout=float(os.getenv("REDIS_SOCKET_TIMEOUT", "2.0")),
    socket_connect_timeout=float(os.getenv("REDIS_CONNECT_TIMEOUT", "2.0")),
)

FEED_KEY = settings.feed_key  # LIST newest-first (LPUSH in sanitizer)


# ------------------------------ Routers (realtime / push / img) --------------

#   apps/api/app/realtime.py   -> router = APIRouter(prefix="/v1/realtime", ...)
#   apps/api/app/push.py       -> router = APIRouter(prefix="/v1/push", ...)
#   apps/api/app/img_proxy.py  -> router = APIRouter(prefix="/v1", ...)

from apps.api.app.realtime import router as realtime_router  # noqa: E402

try:
    from apps.api.app.push import router as push_router  # optional
except Exception:
    push_router = None

try:
    from apps.api.app.img_proxy import router as img_proxy_router  # optional
except Exception:
    img_proxy_router = None


# ------------------------------ Models ---------------------------------------

class Story(BaseModel):
    # core
    id: str
    kind: str
    title: str
    summary: Optional[str] = None
    published_at: Optional[str] = None  # RFC3339 (UTC)
    source: Optional[str] = None
    thumb_url: Optional[str] = None

    # timestamps from pipeline
    ingested_at: Optional[str] = None
    normalized_at: Optional[str] = None

    # story classification / feed filtering
    verticals: Optional[List[str]] = None          # ["entertainment"], ["sports"], ...
    kind_meta: Optional[dict] = None               # e.g. {kind:"release", release_date:..., ...}
    tags: Optional[List[str]] = None               # regions, industries, etc.

    # link + domain
    url: Optional[str] = None
    source_domain: Optional[str] = None

    # release-ish metadata
    release_date: Optional[str] = None             # YYYY-MM-DD or RFC3339
    is_theatrical: Optional[bool] = None
    is_upcoming: Optional[bool] = None
    ott_platform: Optional[str] = None

    # visuals
    poster_url: Optional[str] = None               # mapped from story["poster"] / etc.


class FeedResponse(BaseModel):
    vertical: Optional[str] = None
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
    version="0.5.0",
    description=(
        "Public feed API /v1/feed.\n"
        "Now supports vertical filtering (?vertical=entertainment|sports), "
        "cursor pagination, realtime fanout, and basic rate limiting."
    ),
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

# Mount routers
app.include_router(realtime_router)                 # /v1/realtime/*
if push_router is not None:
    app.include_router(push_router)                 # /v1/push/*
if img_proxy_router is not None:
    app.include_router(img_proxy_router)            # /v1/img?u=...


# ------------------------------ Error handlers -------------------------------

def _json_error(status_code: int, err: str, msg: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=ErrorBody(status=status_code, error=err, message=msg).model_dump(),
    )


@app.exception_handler(HTTPException)
async def http_exc_handler(_: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    return _json_error(exc.status_code, "http_error", detail)


@app.exception_handler(RequestValidationError)
async def validation_exc_handler(_: Request, exc: RequestValidationError):
    return _json_error(422, "validation_error", exc.errors().__repr__())


@app.exception_handler(Exception)
async def unhandled_exc_handler(_: Request, exc: Exception):
    return _json_error(500, exc.__class__.__name__, "Internal server error")


# ------------------------------ Rate limiting --------------------------------

def _client_ip(req: Request) -> str:
    xff = req.headers.get("x-forwarded-for", "")
    if xff:
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
                _redis_client.expire(key, 65)
            if n > limit_per_min:
                raise HTTPException(
                    status_code=429,
                    detail=f"Rate limit exceeded for {route}; try again shortly",
                )
        except redis.RedisError:
            # Best-effort: if Redis is unhappy for rate limit we soft-allow.
            return
    return _limit_dep


# ------------------------------ Helpers --------------------------------------

TRAILER_KINDS = {"trailer", "teaser", "clip", "featurette", "song", "poster"}
OTT_ALIGNED_KINDS = {"release-ott", "ott", "acquisition"}
THEATRICAL_KINDS = {"release-theatrical", "schedule-change", "re-release", "boxoffice"}


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
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
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {type(e).__name__}") from e


def _iter_feed(max_items: int = MAX_SCAN) -> Iterable[dict]:
    """
    Generator over recent feed items (raw JSON from Redis, newest-ish first).
    Used by /v1/search and /v1/story/{id} where we don't need cursor paging.
    """
    raw = _redis_lrange(FEED_KEY, 0, max(0, max_items - 1))
    for s in raw:
        try:
            yield json.loads(s)
        except Exception:
            continue


def _matches_vertical(item: dict, vertical: Optional[str]) -> bool:
    """
    Return True if:
      - no vertical was requested, OR
      - item.verticals contains that vertical.
    verticals is guaranteed in sanitizer to be a list[str] (at least the fallback).
    """
    if not vertical:
        return True
    verts = item.get("verticals") or []
    if not isinstance(verts, list):
        return False
    vertical_l = vertical.strip().lower()
    return any(isinstance(v, str) and v.strip().lower() == vertical_l for v in verts)


def _matches_tab(item: dict, tab: FeedTab) -> bool:
    """
    Legacy "tab" filter logic. We keep this for backward compatibility.
    Eventually, product can kill tabs and rely fully on `vertical`.
    """
    if tab == FeedTab.all:
        return True

    kind = (item.get("kind") or "").lower()

    # Trailers tab
    if tab == FeedTab.trailers:
        return kind in TRAILER_KINDS

    # OTT tab
    if tab == FeedTab.ott:
        return (
            kind in OTT_ALIGNED_KINDS
            or item.get("is_theatrical") is False
            or bool(item.get("ott_platform"))
        )

    # In Theatres tab
    if tab == FeedTab.intheatres:
        return kind in THEATRICAL_KINDS or item.get("is_theatrical") is True

    # Coming Soon tab
    if tab == FeedTab.comingsoon:
        if item.get("is_upcoming") is True:
            return True
        rd = _parse_iso(item.get("release_date"))
        return bool(rd and rd > datetime.now(timezone.utc))

    return True


def _best_dt(item: dict) -> Optional[datetime]:
    """
    Pick the "effective" timestamp for ordering: normalized_at > published_at > release_date.
    """
    for fld in ("normalized_at", "published_at", "release_date"):
        dt = _parse_iso(item.get(fld))
        if dt:
            return dt
    return None


def _is_since(item: dict, since_iso: Optional[str]) -> bool:
    """
    Filter out anything strictly older than `since`.
    """
    if not since_iso:
        return True
    since_dt = _parse_iso(since_iso)
    if not since_dt:
        return True
    dt = _best_dt(item)
    return bool(dt and dt >= since_dt)


def _to_proxy(u: Optional[str]) -> Optional[str]:
    """
    Wrap absolute external URLs so the frontend can fetch images via our
    CORS-safe proxy endpoint: /v1/img?u=...
    Avoid double-wrapping and leave relative / already-proxied URLs untouched.
    """
    if not u:
        return u
    if u.startswith("/v1/img?") or u.startswith(f"{API_PUBLIC_BASE_URL}/v1/img?"):
        return u
    if u.startswith("http://") or u.startswith("https://"):
        return f"{API_PUBLIC_BASE_URL}/v1/img?u={quote(u, safe='')}"
    return u


def _adapt_for_response(it: dict) -> dict:
    """
    Adapt raw story objects (what sanitizer wrote) into what we ship over API.
    - poster_url <- poster (if not already provided)
    - thumb_url  <- thumb_url or first of [image, thumbnail, media]
    - normalized_at fallback from ingested_at
    - proxy URL rewrite for images
    - keep verticals, kind_meta, tags, etc.
    """
    obj = dict(it)

    # poster_url fallback
    if not obj.get("poster_url") and obj.get("poster"):
        obj["poster_url"] = obj.get("poster")

    # thumbnail / image fallbacks
    if not obj.get("thumb_url"):
        obj["thumb_url"] = (
            obj.get("image")
            or obj.get("thumbnail")
            or obj.get("media")
            or None
        )

    # normalized_at fallback
    if not obj.get("normalized_at"):
        obj["normalized_at"] = obj.get("ingested_at")

    # rewrite images through proxy for CORS
    obj["thumb_url"] = _to_proxy(obj.get("thumb_url"))
    obj["poster_url"] = _to_proxy(obj.get("poster_url"))

    # verticals is already enforced in sanitizer (_ensure_verticals),
    # kind_meta is guaranteed-ish in sanitizer (_ensure_kind_meta)
    # We just leave them as-is.

    # ensure tags is either list[str] or None (sanitizer already tries this)
    tags_val = obj.get("tags")
    if not (tags_val is None or isinstance(tags_val, list)):
        obj["tags"] = None

    return obj


def _scan_with_cursor(
    start_idx: int,
    limit: int,
    vertical: Optional[str],
    tab: FeedTab,
    since: Optional[str],
) -> Tuple[List[dict], Optional[int]]:
    """
    We paginate over the Redis LIST (which is LPUSH newest-first in sanitizer).
    BUT we don't trust push order completely; we sort the collected batch by
    "effective timestamp" (normalized_at > published_at > release_date).

    Inputs:
      - start_idx: where to start scanning the Redis list
      - limit: how many results to *return*
      - vertical: optional vertical slug, e.g. "entertainment" or "sports"
      - tab: legacy tab filter
      - since: timestamp floor

    Returns:
      (page, next_cursor_int_or_None)
    """

    # total list length so we don't read past the tail
    try:
        total_len = _redis_client.llen(FEED_KEY)
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {type(e).__name__}") from e

    total_len = int(total_len or 0)
    idx = max(0, start_idx)

    collected: List[dict] = []
    scanned = 0

    # We intentionally collect more than asked so our timestamp sort is meaningful.
    target_collect = max(limit * 5, limit)

    while idx < total_len and scanned < MAX_SCAN and len(collected) < target_collect:
        batch_end = min(idx + BATCH_SIZE - 1, total_len - 1)
        raw_batch = _redis_lrange(FEED_KEY, idx, batch_end)
        if not raw_batch:
            break

        for raw in raw_batch:
            scanned += 1
            try:
                it = json.loads(raw)
            except Exception:
                continue

            if since and not _is_since(it, since):
                continue
            if vertical and not _matches_vertical(it, vertical):
                continue
            if not _matches_tab(it, tab):
                continue

            collected.append(_adapt_for_response(it))

            if scanned >= MAX_SCAN or len(collected) >= target_collect:
                break

        idx = batch_end + 1

    # newest → oldest by effective timestamp
    collected.sort(
        key=lambda d: (_best_dt(d) or datetime(1970, 1, 1, tzinfo=timezone.utc)),
        reverse=True,
    )

    page = collected[:limit]
    next_cursor = idx if idx < total_len else None
    return (page, next_cursor)


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
        "redis": settings.redis_url,
        "feed_key": FEED_KEY,
        "feed_len": feed_len,
        "redis_ok": ok,
        "error": err,
        "env": settings.env,
        "version": "0.5.0",
    }


@app.get("/v1/health", include_in_schema=False)
def v1_health():
    # Shim so both /health and /v1/health answer 200 JSON
    return health()


@app.get(
    "/v1/feed",
    response_model=FeedResponse,
    summary="Feed items",
    description=(
        "Cursor-paginated feed. "
        "Use ?vertical=entertainment|sports to filter. "
        "Results are sorted by effective timestamp (normalized_at > published_at > release_date). "
        "Use returned `next_cursor` for pagination."
    ),
)
async def feed(
    request: Request,
    vertical: Optional[str] = Query(
        None,
        description="Vertical slug to filter by (e.g. 'entertainment', 'sports'). "
                    "If omitted, returns all verticals.",
    ),
    tab: FeedTab = Query(
        FeedTab.all,
        description="Legacy tabs: all | trailers | ott | intheatres | comingsoon. "
                    "Still applied after vertical filter.",
    ),
    since: Optional[str] = Query(
        None,
        description="RFC3339 / UTC. Only include items where "
                    "(normalized_at → published_at → release_date) >= this time.",
    ),
    cursor: Optional[str] = Query(
        None,
        description="Opaque cursor from previous page; omit for first page.",
    ),
    limit: int = Query(
        default=settings.default_page_size,
        ge=1,
        le=settings.max_page_size,
        description="Max number of stories to return in this page.",
    ),
    _=Depends(limiter("feed", RL_FEED_PER_MIN)),
):
    # Validate 'since' early so we give nice 422 instead of empty feed.
    if since is not None and _parse_iso(since) is None:
        raise HTTPException(
            status_code=422,
            detail="Invalid 'since' (use RFC3339, e.g. 2025-01-01T00:00:00Z)",
        )

    # decode cursor
    start_idx = 0
    if cursor:
        try:
            start_idx = max(0, int(cursor))
        except ValueError:
            start_idx = 0

    pool, next_idx = _scan_with_cursor(start_idx, limit, vertical, tab, since)
    items = [Story(**it) for it in pool]
    next_cursor = str(next_idx) if next_idx is not None else None

    return FeedResponse(
        vertical=vertical,
        tab=tab.value,
        since=since,
        items=items,
        next_cursor=next_cursor,
    )


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
    """
    Very naive substring match across the most recent MAX_SCAN stories.
    Does NOT care about verticals, tabs, etc.
    """
    ql = q.lower()
    res: list[dict] = []
    scanned = 0
    for it in _iter_feed():
        scanned += 1
        hay = f"{it.get('title','')} {(it.get('summary') or '')}".lower()
        if ql in hay:
            res.append(_adapt_for_response(it))
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
    """
    Walk recent feed items and return the first matching story ID.
    This is O(MAX_SCAN) and is fine for now.
    """
    sid = unquote(story_id)
    for it in _iter_feed():
        if it.get("id") == sid:
            return Story(**_adapt_for_response(it))
    raise HTTPException(status_code=404, detail="Story not found")


@app.get("/")
def root():
    return {
        "ok": True,
        "service": "cinepulse-api",
        "env": settings.env,
        "version": "0.5.0",
    }
