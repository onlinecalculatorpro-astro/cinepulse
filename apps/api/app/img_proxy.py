# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional, Tuple
from urllib.parse import urlparse, unquote

import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

router = APIRouter(
    prefix="/v1",
    tags=["img"],
)

# ---------------------------------------------------------------------------
# Tunables / perf / safety
# ---------------------------------------------------------------------------

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

# Cache hint to browsers / any CDN sitting in front of us.
CACHE_CONTROL = "public, max-age=86400, s-maxage=86400"

# Pretend to be Chrome. Many celebrity/entertainment WP sites bot-block.
BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

# Paths we *never* fetch (login / logout / admin panels etc.)
_BAD_PATH_PATTERNS = re.compile(
    r"/wp-login\.php|action=logout",
    flags=re.IGNORECASE,
)

# Domains we must never SSRF into (self, localhost, etc.)
_BLOCKED_HOSTS = {
    "api.onlinecalculatorpro.org",
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _host_is_private_ip_literal(host: str) -> bool:
    """
    If `host` itself is an IP literal, block RFC1918 / loopback / link-local /
    multicast / reserved. We do NOT DNS-resolve normal hostnames here.
    """
    if not host:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False  # not an IP literal, so skip this check

    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
    )


def _looks_like_image(content_type: Optional[str]) -> bool:
    """
    We'll only stream if upstream said `image/*` *or* the infamous
    application/octet-stream (some CDNs do this for jpg/webp).
    """
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return ct.startswith("image/") or ct == "application/octet-stream"


def _build_headers_for_host(origin_host: str, *, alt: bool = False) -> dict[str, str]:
    """
    attempt 0 (alt=False):
      - Send Referer=https://<origin_host>/ (many WP installs demand this)
    attempt 1 (alt=True):
      - Drop Referer, slightly looser Accept. Some CDNs fake-404 if Referer
        doesn't match EXACTLY. Retrying w/ no Referer often works.
    """
    if not alt:
        return {
            "User-Agent": BROWSER_UA,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"https://{origin_host}/",
            "Connection": "keep-alive",
        }
    return {
        "User-Agent": BROWSER_UA,
        "Accept": "image/*,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.8",
        "Connection": "keep-alive",
    }


def _is_blocked_hostname(host: str) -> bool:
    """
    Avoid proxy loops (hitting ourselves via /v1/img?u=our_own_url),
    and avoid obvious localhost-style targets.
    """
    if not host:
        return True
    h = host.lower().strip()
    if h in _BLOCKED_HOSTS:
        return True
    # also block subdomains of blocked hosts
    for b in _BLOCKED_HOSTS:
        if h.endswith("." + b):
            return True
    return False


def _parse_and_validate_source_url(raw_u: str) -> Tuple[str, str, str]:
    """
    Decode & vet the ?u=... param.
    Returns (full_url, scheme, host) or raises HTTPException.
    """
    if not raw_u:
        raise HTTPException(status_code=422, detail="missing 'u' param")

    # Frontend uses encodeURIComponent(url); undo that.
    full_url = unquote(raw_u).strip()
    p = urlparse(full_url)

    # Must be http(s), absolute URL
    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")
    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    host = (p.hostname or "").strip()

    # SSRF hard stops
    if _is_blocked_hostname(host):
        raise HTTPException(status_code=400, detail="forbidden host")
    if _host_is_private_ip_literal(host):
        raise HTTPException(status_code=400, detail="forbidden host (private ip literal)")

    # Never fetch logins / logout actions etc.
    if _BAD_PATH_PATTERNS.search(p.path or ""):
        raise HTTPException(status_code=404, detail="not an image")

    return full_url, p.scheme, host


# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------

@router.get("/img")
async def proxy_img(
    u: str = Query(
        ...,
        description="Absolute image URL, URL-encoded with encodeURIComponent()",
    ),
):
    """
    CORS-safe image proxy for the CinePulse web client.

    What we do:
    - Browser hits *our* domain only (no mixed origins on the frontend).
    - We fetch the real image with friendly UA/Referer to bypass hotlink blocks.
    - We block private / loopback / self / localhost to avoid SSRF.
    - We stream bytes straight back, with Cache-Control + permissive CORS.

    Status codes we return:
    - 200 = image stream OK
    - 404 = not an image / blocked / genuinely missing
    - 502 = upstream totally failed (timeout, DNS, 5xx, etc.)
    """

    full_url, _scheme, host = _parse_and_validate_source_url(u)

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(
            max_keepalive_connections=10,
            max_connections=20,
        ),
    ) as client:

        # We'll try twice:
        #   1. with spoofed Referer
        #   2. without Referer
        #
        # Some WordPress/TagDiv CDNs fake-404 on the "wrong" Referer,
        # not just 403. So we retry on 401/403/404/451.
        for attempt in (0, 1):
            try:
                upstream = await client.get(
                    full_url,
                    headers=_build_headers_for_host(host, alt=bool(attempt)),
                )
            except httpx.RequestError:
                # DNS fail / timeout / TLS fail / etc.
                if attempt == 0:
                    # try alt headers once
                    continue
                raise HTTPException(status_code=502, detail="upstream request failed")

            # If origin said "go away", or "fake 404" on attempt 0,
            # retry once without Referer:
            if upstream.status_code in (401, 403, 404, 451) and attempt == 0:
                continue

            # Past this point, we treat whatever we got as final.

            if upstream.status_code >= 500:
                raise HTTPException(
                    status_code=502,
                    detail=f"upstream {upstream.status_code}",
                )

            if upstream.status_code == 404:
                raise HTTPException(status_code=404, detail="not found")

            if upstream.status_code >= 400:
                # Remaining 4xx become "image unavailable"
                raise HTTPException(
                    status_code=404,
                    detail=f"blocked ({upstream.status_code})",
                )

            ctype = upstream.headers.get("Content-Type", "")
            if not _looks_like_image(ctype):
                raise HTTPException(status_code=404, detail="not an image")

            # Stream bytes right back to the client without buffering the whole file.
            resp = StreamingResponse(
                upstream.aiter_bytes(),
                status_code=200,
                media_type=ctype.split(";", 1)[0] if ctype else "application/octet-stream",
            )

            # Pass along size hint if upstream gave us one.
            clen = upstream.headers.get("Content-Length")
            if clen:
                resp.headers["Content-Length"] = clen

            # Strong cache so we don't re-fetch the same celebrity poster 200x/min.
            resp.headers["Cache-Control"] = CACHE_CONTROL

            # CORS: allow any origin to <img src="..."> this file.
            # We do NOT set Allow-Credentials together with "*".
            resp.headers["Access-Control-Allow-Origin"] = "*"
            resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
            resp.headers["Access-Control-Allow-Headers"] = "*"

            return resp

    # Shouldn't get here, but just in case.
    raise HTTPException(status_code=502, detail="unexpected proxy failure")
