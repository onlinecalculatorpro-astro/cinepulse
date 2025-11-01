from __future__ import annotations

import ipaddress
import json
import re
from typing import Optional, Tuple, List
from urllib.parse import urlparse, urlunparse, unquote, quote

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# Configs
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

HARD_DENY = True  # keep enabled for safety

BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

_HARD_DENY_HOST_SUFFIXES = (
    "ndtvimg.com",
    "hindustantimes.com",
    "livemint.com",
    "toiimg.com",
    "etimg.com",
    "thehindu.com",
    "indianexpress.com",
    "business-standard.com",
    "newindianexpress.com",
    "tosshub.com",
)

_BLOCKED_HOSTS = {
    "api.nutshellnewsapp.com",
    "api",
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}

def _cors_headers() -> dict[str, str]:
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Expose-Headers": "*",
        "Cache-Control": CACHE_CONTROL,
        "X-Content-Type-Options": "nosniff",
        "Cross-Origin-Resource-Policy": "cross-origin",
    }

def _host_is_private_ip_literal(host: str) -> bool:
    if not host:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
    )

def _hard_deny(host: str) -> bool:
    if not HARD_DENY:
        return False
    h = host.lower()
    return any(h.endswith(sfx) for sfx in _HARD_DENY_HOST_SUFFIXES)

def _parse_source_url(raw_u: str) -> Tuple[str, str, str, str]:
    if not raw_u:
        raise HTTPException(status_code=422, detail="missing 'u'")
    orig_full = unquote(raw_u).strip()
    p = urlparse(orig_full)

    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")
    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    host = (p.hostname or "").strip().lower()
    path = p.path or ""

    if host in _BLOCKED_HOSTS or any(host.endswith("." + b) for b in _BLOCKED_HOSTS):
        raise HTTPException(status_code=400, detail="forbidden host")

    if _host_is_private_ip_literal(host):
        raise HTTPException(status_code=400, detail="forbidden host")

    return orig_full, orig_full, host, path

# Minimal SVG placeholder (can swap for PNG if you like)
SVG_PLACEHOLDER = b'''
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="60">
    <rect width="100" height="60" fill="#dee2e6"/>
    <text x="50" y="30" font-size="14" text-anchor="middle" fill="#868e96" dy=".3em">No Image</text>
</svg>
'''

@router.api_route("/img", methods=["GET", "HEAD", "OPTIONS"])
async def proxy_img(
    request: Request,
    u: Optional[str] = Query(None, description="Absolute image URL (URL-encoded)"),
    url: Optional[str] = Query(None, description="Alias for 'u'"),
):
    if request.method == "OPTIONS":
        return Response(status_code=204, headers=_cors_headers())

    raw = u or url
    orig_url, _, host, _ = _parse_source_url(raw or "")

    # Hard-deny: immediately return fallback image
    if _hard_deny(host):
        headers = _cors_headers()
        headers.update({
            "Content-Type": "image/svg+xml",
            "Content-Disposition": 'inline; filename="placeholder.svg"',
        })
        return Response(status_code=200, headers=headers, content=SVG_PLACEHOLDER)

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    ) as client:
        try:
            r = await client.get(orig_url, headers={
                "User-Agent": BROWSER_UA,
                "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            })
        except httpx.RequestError:
            # Network issue -- show fallback
            headers = _cors_headers()
            headers.update({
                "Content-Type": "image/svg+xml",
                "Content-Disposition": 'inline; filename="placeholder.svg"',
            })
            return Response(status_code=200, headers=headers, content=SVG_PLACEHOLDER)

        ct = r.headers.get("Content-Type", "")
        if r.status_code < 400 and ct.startswith("image/"):
            headers = _cors_headers()
            if "Content-Length" in r.headers:
                headers["Content-Length"] = r.headers["Content-Length"]
            headers["Content-Type"] = ct
            headers["Content-Disposition"] = 'inline; filename="proxy-image"'
            if request.method == "HEAD":
                return Response(status_code=200, headers=headers)
            return StreamingResponse(r.aiter_bytes(), status_code=200, media_type=ct, headers=headers)
        else:
            # Serve placeholder for errors/non-image
            headers = _cors_headers()
            headers.update({
                "Content-Type": "image/svg+xml",
                "Content-Disposition": 'inline; filename="placeholder.svg"',
            })
            return Response(status_code=200, headers=headers, content=SVG_PLACEHOLDER)
