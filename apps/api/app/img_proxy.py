# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional, Tuple
from urllib.parse import urlparse, unquote

import httpx
from fastapi import APIRouter, HTTPException, Query, Response
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# ------------------------------------------------------------------------------
# Tunables / safety / perf knobs
# ------------------------------------------------------------------------------

# Timeouts: stay snappy, don't hang the API worker if origin is slow
CONNECT_TIMEOUT = 3.0
READ_TIMEOUT = 10.0
TOTAL_TIMEOUT = httpx.Timeout(
    timeout=None,
    connect=CONNECT_TIMEOUT,
    read=READ_TIMEOUT,
    write=READ_TIMEOUT,
    pool=CONNECT_TIMEOUT,
)

# Don't chase infinite redirect loops
MAX_REDIRECTS = 5

# Cache aggressively at the edge/CDN (24h)
CACHE_CONTROL = "public, max-age=86400, s-maxage=86400"

# Pretend to be a normal desktop Chrome so CDNs don't serve us "bot block" JPGs
BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

# Obvious non-image traps we don't want to proxy (login pages, logout actions, etc.)
_BAD_PATH_PATTERNS = re.compile(
    r"/wp-login\.php|action=logout",
    flags=re.IGNORECASE,
)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

def _host_is_private_ip(host: str) -> bool:
    """
    SSRF guard #1: if the caller gives us a literal IP, do not allow RFC1918,
    loopback, link-local, etc.

    We intentionally DO NOT resolve DNS here. We just block direct IPs.
    """
    if not host:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        # it's a hostname, not an IP literal -> allow for now
        return False

    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
    )


def _looks_like_image(content_type: Optional[str]) -> bool:
    """
    We only stream if the upstream responded with an image/* content-type
    (or a very generic 'application/octet-stream' which a lot of CDNs use for JPGs).
    """
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return ct.startswith("image/") or ct == "application/octet-stream"


def _build_headers(host: str, alt: bool = False) -> dict[str, str]:
    """
    alt=False:
        - Realistic browser Accept + Referer=https://<host>/ to please
          WordPress/CDNs that hotlink-protect unless you "came" from them.
    alt=True:
        - Fallback headers without Referer for CDNs that 403 on spoofed referers.
    """
    if not alt:
        return {
            "User-Agent": BROWSER_UA,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"https://{host}/",
            "Connection": "keep-alive",
        }
    else:
        return {
            "User-Agent": BROWSER_UA,
            "Accept": "image/*,*/*;q=0.5",
            "Accept-Language": "en-US,en;q=0.8",
            "Connection": "keep-alive",
        }


def _parse_source_url(raw_u: str) -> Tuple[str, str, str]:
    """
    Validate & normalize ?u=...
    Returns (full_url, scheme, host) or raises HTTPException.
    """
    if not raw_u:
        raise HTTPException(status_code=422, detail="missing 'u'")

    # We expect frontend to send encodeURIComponent(url); undo that.
    full_url = unquote(raw_u).strip()
    p = urlparse(full_url)

    # Must be http(s) and absolute
    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")
    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    host = p.hostname or ""

    # SSRF guard #2: block localhost/0.0.0.0/etc. as literal hosts.
    if host in {"localhost", "localhost.localdomain"}:
        raise HTTPException(status_code=400, detail="private addresses are not allowed")
    if _host_is_private_ip(host):
        raise HTTPException(status_code=400, detail="private addresses are not allowed")

    # Drop super-obvious trap paths (login, logout, etc.). We'll just tell caller "not an image".
    if _BAD_PATH_PATTERNS.search(p.path or ""):
        raise HTTPException(status_code=404, detail="not an image")

    return full_url, p.scheme, host


# ------------------------------------------------------------------------------
# Endpoint
# ------------------------------------------------------------------------------

@router.get("/img")
async def proxy_img(
    u: str = Query(..., description="Absolute image URL, URL-encoded"),
) -> Response:
    """
    Image proxy used by the feed.

    Why it exists:
    - We rewrite thumb_url/poster_url to hit /v1/img?u=...
      so the browser only ever requests our domain → CORS-safe.
    - We attach Referer/User-Agent so hotlink-protected WordPress CDNs still serve.
    - We refuse obvious SSRF targets (localhost, 10.x.x.x, etc.).
    - We stream bytes without buffering the entire image in RAM.

    Behavior:
    - 404 for "not image", "blocked", "login" etc.
    - 502 only for true upstream errors/timeouts.
    """

    full_url, _scheme, host = _parse_source_url(u)

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(
            max_keepalive_connections=10,
            max_connections=20,
        ),
    ) as client:
        # Attempt #1: send with Referer spoofed to the origin host
        # Attempt #2: retry w/o Referer if origin 403s/401s/etc.
        for attempt in (0, 1):
            try:
                r = await client.get(full_url, headers=_build_headers(host, alt=bool(attempt)))
            except httpx.RequestError:
                # network timeout / DNS issue / refused
                if attempt == 0:
                    # retry once with alt headers
                    continue
                raise HTTPException(status_code=502, detail="upstream request failed")

            # Retry once on "forbidden" style 4xx (CDN anti-hotlinking)
            if r.status_code in (401, 403, 451) and attempt == 0:
                continue

            # Final response handling
            if r.status_code >= 500:
                raise HTTPException(status_code=502, detail=f"upstream {r.status_code}")
            if r.status_code == 404:
                raise HTTPException(status_code=404, detail="not found")
            if r.status_code >= 400:
                # For remaining 4xx: treat it as "not available"
                raise HTTPException(status_code=404, detail=f"blocked ({r.status_code})")

            ct = r.headers.get("Content-Type")
            if not _looks_like_image(ct):
                raise HTTPException(status_code=404, detail="not an image")

            # Stream the upstream body directly to client.
            resp = StreamingResponse(
                r.aiter_bytes(),
                status_code=200,
                media_type=ct.split(";", 1)[0] if ct else "application/octet-stream",
            )

            # Propagate useful headers
            if "Content-Length" in r.headers:
                resp.headers["Content-Length"] = r.headers["Content-Length"]

            # Cache hint so CDNs/browsers keep thumbnails for a day
            resp.headers["Cache-Control"] = CACHE_CONTROL

            # CORS for <img src="..."> across any origin
            resp.headers["Access-Control-Allow-Origin"] = "*"
            resp.headers["Access-Control-Allow-Credentials"] = "true"

            return resp

    # Should never get here logically, but just in case.
    raise HTTPException(status_code=502, detail="unexpected proxy failure")
