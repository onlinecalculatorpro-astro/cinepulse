# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional
from urllib.parse import urlparse, unquote

import httpx
from fastapi import APIRouter, HTTPException, Query, Response
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# --------- Settings ----------
CONNECT_TIMEOUT = 3.0
READ_TIMEOUT = 10.0
TOTAL_TIMEOUT = httpx.Timeout(
    timeout=None,
    connect=CONNECT_TIMEOUT,
    read=READ_TIMEOUT,
    write=READ_TIMEOUT,
    pool=CONNECT_TIMEOUT,
)
MAX_REDIRECTS = 5
CACHE_CONTROL = "public, max-age=86400, s-maxage=86400"

# A realistic desktop Chrome UA. Helps with WordPress/CDNs that block bots.
CHROME_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

# Quick denylist patterns that are definitely not images
BAD_PATH_PATTERNS = (
    r"/wp-login\.php",
    r"action=logout",
)

_bad_path_re = re.compile("|".join(BAD_PATH_PATTERNS), re.IGNORECASE)


# --------- Helpers ----------

def _is_private_ip(host: str) -> bool:
    """
    Cheap SSRF guard: block obvious private/loopback hosts if a user
    ever passes a raw IP (we do not resolve DNS here).
    """
    try:
        ip = ipaddress.ip_address(host)
        return ip.is_private or ip.is_loopback or ip.is_reserved or ip.is_link_local
    except ValueError:
        # not an IP literal => allow (DNS resolution happens in httpx)
        return False


def _validate_and_parse(raw: str) -> tuple[str, str, str]:
    if not raw:
        raise HTTPException(status_code=422, detail="missing 'u'")

    u = unquote(raw).strip()
    p = urlparse(u)

    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")

    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    if _is_private_ip(p.hostname or ""):
        raise HTTPException(status_code=400, detail="private addresses are not allowed")

    if _bad_path_re.search(p.path or ""):
        # A lot of sources hotlink-trap by redirecting to login/logout endpoints;
        # short-circuit those so we don't return 502s that look like errors.
        raise HTTPException(status_code=404, detail="not an image")

    return u, p.scheme, p.hostname or ""


def _make_headers(host: str, alt: bool = False) -> dict[str, str]:
    """
    alt=False: normal browser-like request with per-host Referer.
    alt=True: fallback headers (no referer, different Accept) for picky CDNs.
    """
    if not alt:
        return {
            "User-Agent": CHROME_UA,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"https://{host}/",
            "Connection": "keep-alive",
        }
    else:
        return {
            "User-Agent": CHROME_UA,
            "Accept": "image/*,*/*;q=0.5",
            "Accept-Language": "en-US,en;q=0.8",
            # some sites dislike referers; drop it on fallback
            "Connection": "keep-alive",
        }


def _looks_like_image(content_type: Optional[str]) -> bool:
    if not content_type:
        return False
    ct = content_type.lower().split(";")[0].strip()
    return ct.startswith("image/") or ct in {"application/octet-stream"}


# --------- Endpoint ----------

@router.get("/img")
async def proxy_img(
    u: str = Query(..., description="Absolute image URL, URL-encoded"),
) -> Response:
    """
    Stream a remote image with sane headers/timeouts.
    - 404 for obvious hotlink/login traps
    - 502 only when the remote server is failing/blocked after retries
    """

    url, scheme, host = _validate_and_parse(u)

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
        max_redirects=MAX_REDIRECTS,
    ) as client:
        # Try normal browser-like request first
        for attempt in (0, 1):
            try:
                headers = _make_headers(host, alt=bool(attempt))
                r = await client.get(url, headers=headers)
            except httpx.RequestError:
                # Network/timeout => try the alt header set (or fail after 2nd try)
                if attempt == 0:
                    continue
                raise HTTPException(status_code=502, detail="upstream request failed")

            # Picky CDNs: if 403/401/451 etc, retry once with alt headers
            if r.status_code >= 400 and attempt == 0:
                continue

            # Final status handling
            if r.status_code >= 500:
                raise HTTPException(status_code=502, detail=f"upstream {r.status_code}")
            if r.status_code == 404:
                raise HTTPException(status_code=404, detail="not found")
            if r.status_code >= 400:
                # treat remaining 4xx as a miss (don’t spam 502s)
                raise HTTPException(status_code=404, detail=f"blocked ({r.status_code})")

            ct = r.headers.get("Content-Type")
            if not _looks_like_image(ct):
                # We fetched HTML or something non-image; treat as not found
                raise HTTPException(status_code=404, detail="not an image")

            # Stream bytes to client with image headers
            resp = StreamingResponse(
                r.aiter_bytes(),
                status_code=200,
                media_type=ct.split(";")[0] if ct else "application/octet-stream",
            )

            # Propagate size if known + caching
            if "Content-Length" in r.headers:
                resp.headers["Content-Length"] = r.headers["Content-Length"]
            resp.headers["Cache-Control"] = CACHE_CONTROL

            # Allow cross-origin <img> usage (CORS middleware usually covers this,
            # but adding here is harmless and explicit)
            resp.headers["Access-Control-Allow-Origin"] = "*"
            resp.headers["Access-Control-Allow-Credentials"] = "true"

            return resp

    # Should never hit here due to returns/raises above
    raise HTTPException(status_code=502, detail="unexpected proxy failure")
