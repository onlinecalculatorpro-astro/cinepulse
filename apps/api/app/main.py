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

from apps.api.app.config import settings  # central env/config (redis_url, feed_key, etc.)

# ------------------------------------------------------------------------------
# Redis
# ------------------------------------------------------------------------------

try:
    import redis  # type: ignore
except Exception as e:  # pragma: no cover
    raise RuntimeError("redis package is required") from e

# Runtime knobs (all overridable via env, no code change needed)
MAX_SCAN = int(os.getenv("MAX_SCAN", "400"))          # how deep feed/search/detail can look
BATCH_SIZE = int(os.getenv("BATCH_SIZE", "200"))      # lrange chunk size per scan

# Per-IP per-minute rate limits
RL_FEED_PER_MIN = int(os.getenv("RL_FEED_PER_MIN", "120"))
RL_SEARCH_PER_MIN = int(os.getenv("RL_SEARCH_PER_MIN", "90"))
RL_STORY_PER_MIN = int(os.getenv("RL_STORY_PER_MIN", "240"))

# Public API base, used when rewriting image URLs to our /v1/img proxy
API_PUBLIC_BASE_URL = os.getenv(
    "API_PUBLIC_BASE_URL",
    "https://api.onlinecalculatorpro.org",
).strip().rstrip("/")

# Redis client (shared w/ workers/sanitizer)
_redis_client = redis.from_url(
    settings.redis_url,
    decode_responses=True,  # get str not bytes
    socket_timeout=float(os.getenv("REDIS_SOCKET_TIMEOUT", "2.0")),
    socket_connect_timeout=float(os.getenv("REDIS_CONNECT_TIMEOUT", "2.0")),
)

FEED_KEY = settings.feed_key  # LIST newest-first (sanitizer LPUSH's here)


# ------------------------------------------------------------------------------
# Routers (realtime / push / img proxy)
#  - realtime: /v1/realtime/ws, /v1/realtime/stream
#  - push:     /v1/push/*
#  - img:      /v1/img?u=... (public image proxy)
# ------------------------------------------------------------------------------

from apps.api.app.realtime import router as realtime_router  # noqa: E402

try:
    from apps.api.app.push import router as push_router
except Exception:
    push_router = None  # push is optional / can be stubbed

try:
    from apps.api.app.img_proxy import router as img_proxy_router
except Exception:
    img_proxy_router = None  # img proxy becomes optional during bootstrap


# ------------------------------------------------------------------------------
# Pydantic response models
# ------------------------------------------------------------------------------

class Story(BaseModel):
    # core
    id: str
    kind: str
    title: str
    summary: Optional[str] = None
    published_at: Optional[str] = None  # RFC3339 UTC
    source: Optional[str] = None
    thumb_url: Optional[str] = None

    # pipeline timestamps
    ingested_at: Optional[str] = None
    normalized_at: Optional[str] = None

    # classification / feed filters
    verticals: Optional[List[str]] = None        # ["entertainment"] / ["sports"] etc.
    kind_meta: Optional[dict] = None             # {"kind":"release","release_date":...}
    tags: Optional[List[str]] = None             # free-form tags

    # link + source domain
    url: Optional[str] = None
    source_domain: Optional[str] = None

    # release-ish metadata
    release_date: Optional[str] = None           # YYYY-MM-DD or RFC3339
    is_theatrical: Optional[bool] = None
    is_upcoming: Optional[bool] = None
    ott_platform: Optional[str] = None

    # visuals
    poster_url: Optional[str] = None             # canonical poster / hero art


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


# ------------------------------------------------------------------------------
# FastAPI app + CORS
# ------------------------------------------------------------------------------

app = FastAPI(
    title="CinePulse API",
    version="0.5.0",
    description=(
        "Public CinePulse feed API.\n"
        "- /v1/feed (cursor pagination + vertical/tab filters)\n"
        "- /v1/search\n"
        "- /v1/story/{id}\n"
        "- /v1/img image proxy for safe thumbnails\n"
        "- /v1/realtime/* (WebSocket/SSE)\n"
    ),
)

# CORS behavior:
# - We MUST explicitly allow cinepusle.netlify.app (web client) and our API origin,
#   because the client sends a custom header X-CinePulse-Client which triggers
#   a preflight. '*' won't satisfy that in modern Chrome.
#
# - You can still override via CORS_ORIGINS env
#   e.g. "https://cinepusle.netlify.app,https://api.onlinecalculatorpro.org"
_env_origins = os.getenv("CORS_ORIGINS", "").strip()

if _env_origins:
    allow_list = [o.strip() for o in _env_origins.split(",") if o.strip()]
else:
    allow_list = [
        "https://cinepusle.netlify.app",
        "https://cinepulse.netlify.app",           # in case you typo'd in one deploy :)
        "https://api.onlinecalculatorpro.org",
    ]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_list,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=[
        "*",
        "x-cinepulse-client",   # Flutter client sends this
    ],
)

# Mount subrouters
app.include_router(realtime_router)          # /v1/realtime/*
if push_router is not None:
    app.include_router(push_router)          # /v1/push/*
if img_proxy_router is not None:
    app.include_router(img_proxy_router)     # /v1/img?u=...


# ------------------------------------------------------------------------------
# Error handlers (uniform JSON for errors)
# ------------------------------------------------------------------------------

def _json_error(status_code: int, err: str, msg: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=ErrorBody(
            status=status_code,
            error=err,
            message=msg,
        ).model_dump(),
    )


@app.exception_handler(HTTPException)
async def http_exc_handler(_: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    return _json_error(exc.status_code, "http_error", detail)


@app.exception_handler(RequestValidationError)
async def validation_exc_handler(_: Request, exc: RequestValidationError):
    return _json_error(422, "validation_error", repr(exc.errors()))


@app.exception_handler(Exception)
async def unhandled_exc_handler(_: Request, exc: Exception):
    # We deliberately do NOT leak stack traces to clients.
    return _json_error(500, exc.__class__.__name__, "Internal server error")


# ------------------------------------------------------------------------------
# Rate limiting helpers
# ------------------------------------------------------------------------------

def _client_ip(req: Request) -> str:
    # honor x-forwarded-for from nginx first
    xff = req.headers.get("x-forwarded-for", "")
    if xff:
        return xff.split(",")[0].strip()
    return req.client.host if req.client else "unknown"


def limiter(route: str, limit_per_min: int) -> Callable:
    """
    Cheap per-IP token bucket in Redis.
    Key is `rl:<route>:<ip>:<minute-bucket>`.
    - Allow traffic while Redis is up.
    - If Redis explodes, we "soft allow" instead of killing feed.
    """

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
            # If rate-limit storage is unavailable, we let the request pass.
            return

    return _limit_dep


# ------------------------------------------------------------------------------
# Feed filtering / adaptation helpers
# ------------------------------------------------------------------------------

TRAILER_KINDS = {"trailer", "teaser", "clip", "featurette", "song", "poster"}
OTT_ALIGNED_KINDS = {"release-ott", "ott", "acquisition"}
THEATRICAL_KINDS = {"release-theatrical", "schedule-change", "re-release", "boxoffice"}


def _parse_iso(s: Optional[str]) -> Optional[datetime]:
    if not s:
        return None
    try:
        # Accept both "...Z" and offset forms
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
        raise HTTPException(
            status_code=503,
            detail=f"Redis unavailable: {type(e).__name__}",
        ) from e


def _iter_feed(max_items: int = MAX_SCAN) -> Iterable[dict]:
    """
    Iterate over the most recent ~MAX_SCAN raw feed entries (newest-ish first).
    Used by /v1/search and /v1/story/{id}, which don't need cursor paging.
    """
    raw = _redis_lrange(FEED_KEY, 0, max(0, max_items - 1))
    for s in raw:
        try:
            yield json.loads(s)
        except Exception:
            continue


def _matches_vertical(item: dict, vertical: Optional[str]) -> bool:
    """
    True if:
      - no vertical requested, OR
      - the story's verticals contain that slug (case-insensitive match)
    """
    if not vertical:
        return True
    verts = item.get("verticals") or []
    if not isinstance(verts, list):
        return False
    want = vertical.strip().lower()
    return any(isinstance(v, str) and v.strip().lower() == want for v in verts)


def _matches_tab(item: dict, tab: FeedTab) -> bool:
    """
    Legacy home tabs. Product can eventually kill this.
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

    # default allow
    return True


def _best_dt(item: dict) -> Optional[datetime]:
    """
    "Effective" timestamp for sort/order and since-filtering:
    normalized_at > published_at > release_date
    """
    for fld in ("normalized_at", "published_at", "release_date"):
        dt = _parse_iso(item.get(fld))
        if dt:
            return dt
    return None


def _is_since(item: dict, since_iso: Optional[str]) -> bool:
    """
    Keep only items that are >= since_iso in effective timestamp.
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
    Rewrites any absolute http(s) image URL into our proxy:
    https://api.onlinecalculatorpro.org/v1/img?u=<encoded>
    so the web client never has to load 3rd-party origins directly.
    We skip if it's already proxied or it's a relative path we trust.
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
    Take a raw entry from sanitizer and normalize shape for the public API:
      - poster_url fallback
      - thumb_url fallback
      - normalized_at fallback
      - CORS-safe proxy rewrite for images
      - force tags to list[str] or None
    """
    obj = dict(it)

    # poster fallback
    if not obj.get("poster_url") and obj.get("poster"):
        obj["poster_url"] = obj.get("poster")

    # thumb fallback
    if not obj.get("thumb_url"):
        obj["thumb_url"] = (
            obj.get("image")
            or obj.get("thumbnail")
            or obj.get("media")
            or None
        )

    # timestamp fallback
    if not obj.get("normalized_at"):
        obj["normalized_at"] = obj.get("ingested_at")

    # proxy image URLs
    obj["thumb_url"] = _to_proxy(obj.get("thumb_url"))
    obj["poster_url"] = _to_proxy(obj.get("poster_url"))

    # tags sanity
    if not (obj.get("tags") is None or isinstance(obj.get("tags"), list)):
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
    Cursor-pagination over the Redis LIST (newest-first push).
    We:
      - scan forward in chunks,
      - filter (vertical, tab, since),
      - then sort by "effective" timestamp,
      - then return `limit` items + the next cursor index.
    """

    # Total list length so we don't read past tail
    try:
        total_len = _redis_client.llen(FEED_KEY)
    except Exception as e:
        raise HTTPException(
            status_code=503,
            detail=f"Redis unavailable: {type(e).__name__}",
        ) from e

    total_len = int(total_len or 0)
    idx = max(0, start_idx)

    collected: List[dict] = []
    scanned = 0
    # grab extra so timestamp sort has some breathing room
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


# ------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------

@app.get("/health")
def health():
    """
    Public healthcheck. Also exposes feed_len so we can verify sanitizer is alive.
    """
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
    # convenience shim so uptime monitors can hit either /health or /v1/health
    return health()


@app.get(
    "/v1/feed",
    response_model=FeedResponse,
    summary="Paginated feed",
    description=(
        "Cursor-paginated feed.\n"
        "- ?vertical=entertainment|sports filters by vertical\n"
        "- ?tab=all|trailers|ott|intheatres|comingsoon applies legacy tabs\n"
        "- ?since=RFC3339 limits to items >= that timestamp\n"
        "- ?cursor returned by previous page\n"
        "Items are sorted by effective timestamp "
        "(normalized_at > published_at > release_date)."
    ),
)
async def feed(
    request: Request,
    vertical: Optional[str] = Query(
        None,
        description="Vertical slug, e.g. 'entertainment' or 'sports'. "
                    "If omitted you get all.",
    ),
    tab: FeedTab = Query(
        FeedTab.all,
        description="Legacy tabs: all | trailers | ott | intheatres | comingsoon.",
    ),
    since: Optional[str] = Query(
        None,
        description="RFC3339 UTC. "
                    "Only include stories whose effective timestamp "
                    "is >= this time.",
    ),
    cursor: Optional[str] = Query(
        None,
        description="Opaque cursor from previous response.next_cursor. "
                    "Omit for first page.",
    ),
    limit: int = Query(
        default=settings.default_page_size,
        ge=1,
        le=settings.max_page_size,
        description="Max number of stories to return.",
    ),
    _=Depends(limiter("feed", RL_FEED_PER_MIN)),
):
    # Pre-validate 'since' so we don't silently return empty
    if since is not None and _parse_iso(since) is None:
        raise HTTPException(
            status_code=422,
            detail="Invalid 'since' (use RFC3339, e.g. 2025-01-01T00:00:00Z)",
        )

    # decode cursor -> starting list index
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
    summary="Naive substring search over recent titles/summaries",
)
async def search(
    request: Request,
    q: str = Query(..., min_length=1),
    limit: int = Query(10, ge=1, le=50),
    _=Depends(limiter("search", RL_SEARCH_PER_MIN)),
):
    """
    Lowercase substring match on title+summary across ~MAX_SCAN most
    recent stories in Redis. No vertical/tab filtering here (for now).
    """
    ql = q.lower()
    out: list[dict] = []
    scanned = 0

    for it in _iter_feed():
        scanned += 1
        hay = f"{it.get('title','')} {(it.get('summary') or '')}".lower()
        if ql in hay:
            out.append(_adapt_for_response(it))
            if len(out) >= limit:
                break
        if scanned >= MAX_SCAN:
            break

    return SearchResponse(
        q=q,
        items=[Story(**it) for it in out],
    )


@app.get(
    "/v1/story/{story_id}",
    response_model=Story,
    summary="Fetch a single story by ID",
)
async def story_detail(
    request: Request,
    story_id: str,
    _=Depends(limiter("story", RL_STORY_PER_MIN)),
):
    """
    Scan recent feed items and return the first match (O(MAX_SCAN)).
    This is fine because new stories are always toward the head of FEED_KEY.
    """
    sid = unquote(story_id)
    for it in _iter_feed():
        if it.get("id") == sid:
            return Story(**_adapt_for_response(it))

    raise HTTPException(status_code=404, detail="Story not found")


@app.get("/")
def root():
    # Very lightweight sanity endpoint
    return {
        "ok": True,
        "service": "cinepulse-api",
        "env": settings.env,
        "version": "0.5.0",
    }
