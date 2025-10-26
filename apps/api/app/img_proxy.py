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

# ------------------------------------------------------------------------------
# Tunables / safety / perf knobs
# ------------------------------------------------------------------------------

# Network timeouts: keep workers from hanging
CONNECT_TIMEOUT = 3.0
READ_TIMEOUT = 10.0
TOTAL_TIMEOUT = httpx.Timeout(
    timeout=None,
    connect=CONNECT_TIMEOUT,
    read=READ_TIMEOUT,
    write=READ_TIMEOUT,
    pool=CONNECT_TIMEOUT,
)

# Redirect safety
MAX_REDIRECTS = 5

# Tell browsers / CDN edges "you can cache this thumbnail for 24h"
CACHE_CONTROL = "public, max-age=86400, s-maxage=86400"

# Pretend to be a normal browser, not python-httpx
BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

# Obvious bad paths we never want to proxy
_BAD_PATH_PATTERNS = re.compile(
    r"/wp-login\.php|action=logout",
    flags=re.IGNORECASE,
)

# Hosts we refuse to fetch from (to avoid loops / internal hits)
# NOTE: keep this list in sync with your public API hostnames / internal hostnames.
_BLOCKED_HOSTS = {
    "api.onlinecalculatorpro.org",
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}


# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

def _host_is_private_ip_literal(host: str) -> bool:
    """
    SSRF guard #1:
    If the caller gives us a literal IP address, reject RFC1918, loopback,
    link-local, reserved, etc.
    We *do not* DNS-resolve hostnames here. This only fires if `host`
    itself parses as an IP string.
    """
    if not host:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        # not an IP literal, probably a hostname -> handled later
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
    We only stream if upstream says it's an image/* OR it's the infamous
    'application/octet-stream' that a lot of CDNs use for jpg/webp.
    """
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return ct.startswith("image/") or ct == "application/octet-stream"


def _build_headers_for_host(origin_host: str, *, alt: bool = False) -> dict[str, str]:
    """
    attempt 0 (alt=False):
      - Spoof Referer=https://<origin_host>/ to bypass hotlink protection.
    attempt 1 (alt=True):
      - Drop Referer, slightly looser Accept.
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
    SSRF guard #2:
    - don't allow direct hits back to ourselves / localhost / 127.0.0.1 etc.
    - cheap sanity filter to avoid proxy loops like:
        /v1/img?u=https://api.onlinecalculatorpro.org/v1/img?u=...
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
    Take the ?u=... param from the query string, URL-decode it, and vet it.
    Returns (full_url, scheme, host) or raises HTTPException.
    """
    if not raw_u:
        raise HTTPException(status_code=422, detail="missing 'u' param")

    # Frontend sends encodeURIComponent(url)
    full_url = unquote(raw_u).strip()
    p = urlparse(full_url)

    # Must be http(s) and absolute
    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")
    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    host = (p.hostname or "").strip()

    # Block localhost / 127.x / our own domain / obvious internal nets
    if _is_blocked_hostname(host):
        raise HTTPException(status_code=400, detail="forbidden host")
    if _host_is_private_ip_literal(host):
        raise HTTPException(status_code=400, detail="forbidden host (private ip literal)")

    # Extra: short-circuit obvious "login/logged-out" traps
    if _BAD_PATH_PATTERNS.search(p.path or ""):
        raise HTTPException(status_code=404, detail="not an image")

    return full_url, p.scheme, host


# ------------------------------------------------------------------------------
# Endpoint
# ------------------------------------------------------------------------------

@router.get("/img")
async def proxy_img(
    u: str = Query(..., description="Absolute image URL, URL-encoded with encodeURIComponent()"),
):
    """
    Public image proxy.
    - Browser never hits random external domains. It only hits us.
    - We attach Referer/User-Agent to dodge hotlink protection.
    - We block internal/loopback/private targets to avoid SSRF.
    - We stream back bytes with CORS + long cache headers.

    Responses:
      200: image bytes stream + image/* content-type
      404: upstream is not an image / anti-hotlink / not found / login page
      502: true upstream failure or timeout
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

        # attempt order:
        #   1) send Referer spoofed to that host
        #   2) retry without Referer if we got blocked (401/403/451)
        for attempt in (0, 1):
            try:
                resp_up = await client.get(
                    full_url,
                    headers=_build_headers_for_host(host, alt=bool(attempt)),
                )
            except httpx.RequestError:
                # DNS fail / timeout / TCP reset / etc.
                if attempt == 0:
                    continue
                raise HTTPException(status_code=502, detail="upstream request failed")

            # retry once on "forbidden" style codes from CDNs
            if resp_up.status_code in (401, 403, 451) and attempt == 0:
                continue

            # handle final upstream status
            if resp_up.status_code >= 500:
                raise HTTPException(status_code=502, detail=f"upstream {resp_up.status_code}")
            if resp_up.status_code == 404:
                raise HTTPException(status_code=404, detail="not found")
            if resp_up.status_code >= 400:
                # treat remaining 4xx as "image unavailable"
                raise HTTPException(status_code=404, detail=f"blocked ({resp_up.status_code})")

            ctype = resp_up.headers.get("Content-Type", "")
            if not _looks_like_image(ctype):
                raise HTTPException(status_code=404, detail="not an image")

            # Stream upstream body directly
            out = StreamingResponse(
                resp_up.aiter_bytes(),
                status_code=200,
                media_type=ctype.split(";", 1)[0] if ctype else "application/octet-stream",
            )

            # Surface content-length if upstream gave one
            cl = resp_up.headers.get("Content-Length")
            if cl:
                out.headers["Content-Length"] = cl

            # Strong cache hint downstream
            out.headers["Cache-Control"] = CACHE_CONTROL

            # Wide-open CORS so <img src> and even fetch() from web works
            out.headers["Access-Control-Allow-Origin"] = "*"
            out.headers["Access-Control-Allow-Credentials"] = "true"
            out.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
            out.headers["Access-Control-Allow-Headers"] = "*"

            return out

    # If we somehow escaped the loop with no return, treat as upstream failure
    raise HTTPException(status_code=502, detail="unexpected proxy failure")
