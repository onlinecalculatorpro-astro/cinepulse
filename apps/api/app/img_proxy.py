# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional, Tuple
from urllib.parse import urlparse, urlunparse, unquote

import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# ---------- Tunables ----------
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

BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/125.0.0.0 Safari/537.36"
)

_BAD_PATH_PATTERNS = re.compile(r"/wp-login\.php|action=logout", re.IGNORECASE)
_TRAILING_COLON_NUM = re.compile(r":\d+$")  # e.g. ".../image.jpg:1"

_BLOCKED_HOSTS = {
    "api.onlinecalculatorpro.org",
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}

# ---------- Helpers ----------
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

def _looks_like_image(content_type: Optional[str]) -> bool:
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return ct.startswith("image/") or ct == "application/octet-stream"

def _build_headers(origin_host: str, *, alt: bool = False) -> dict[str, str]:
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
    if not host:
        return True
    h = host.lower().strip()
    if h in _BLOCKED_HOSTS:
        return True
    return any(h.endswith("." + b) for b in _BLOCKED_HOSTS)

def _sanitize_full_url(full_url: str) -> str:
    """Strip a trailing :<digits> off the PATH (e.g., .../pic.jpg:1)."""
    p = urlparse(full_url)
    path = p.path or ""
    if _TRAILING_COLON_NUM.search(path):
        path = _TRAILING_COLON_NUM.sub("", path)
        p = p._replace(path=path)
        return urlunparse(p)
    return full_url

def _parse_source_url(raw_u: str) -> Tuple[str, str, str]:
    if not raw_u:
        raise HTTPException(status_code=422, detail="missing 'u'")

    full_url = unquote(raw_u).strip()
    p = urlparse(full_url)

    if p.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="only http/https allowed")
    if not p.netloc:
        raise HTTPException(status_code=400, detail="invalid URL")

    host = (p.hostname or "").strip()

    if _is_blocked_hostname(host) or _host_is_private_ip_literal(host):
        raise HTTPException(status_code=400, detail="forbidden host")

    if _BAD_PATH_PATTERNS.search(p.path or ""):
        raise HTTPException(status_code=404, detail="not an image")

    return full_url, p.scheme, host

# ---------- Endpoint ----------
@router.get("/img")
async def proxy_img(
    u: str = Query(..., description="Absolute image URL, URL-encoded"),
):
    """
    CORS-safe image proxy:
      - blocks SSRF
      - retries around anti-hotlink 4xx (including fake 404)
      - sanitizes accidental ':<digits>' suffixes in path
      - streams bytes back with day-long cache
    """
    original_url, _scheme, host = _parse_source_url(u)
    sanitized_url = _sanitize_full_url(original_url)

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    ) as client:

        # We'll try up to 4 attempts in worst case:
        #  1) original + referer
        #  2) original + no referer
        #  3) sanitized + referer (only if sanitized differs)
        #  4) sanitized + no referer (only if sanitized differs)
        attempts: list[tuple[str, bool]] = [
            (original_url, False),
            (original_url, True),
        ]
        if sanitized_url != original_url:
            attempts.extend([
                (sanitized_url, False),
                (sanitized_url, True),
            ])

        for idx, (url, alt_headers) in enumerate(attempts):
            try:
                r = await client.get(url, headers=_build_headers(host, alt=alt_headers))
            except httpx.RequestError:
                # DNS/TLS/timeout — keep trying remaining variants
                continue

            # If the first variant got 401/403/404/451, we'll automatically
            # keep iterating to the next strategy (no referer / sanitized).
            if r.status_code in (401, 403, 404, 451) and idx + 1 < len(attempts):
                continue

            if r.status_code >= 500:
                # treat hard 5xx as upstream failure
                raise HTTPException(status_code=502, detail=f"upstream {r.status_code}")

            if r.status_code >= 400:
                # after exhausting strategies, 4xx means "not available"
                raise HTTPException(status_code=404, detail=f"blocked ({r.status_code})")

            ct = r.headers.get("Content-Type", "")
            if not _looks_like_image(ct):
                # fetched something unexpected (HTML, etc.)
                raise HTTPException(status_code=404, detail="not an image")

            resp = StreamingResponse(
                r.aiter_bytes(),
                status_code=200,
                media_type=ct.split(";", 1)[0] if ct else "application/octet-stream",
            )

            if "Content-Length" in r.headers:
                resp.headers["Content-Length"] = r.headers["Content-Length"]

            resp.headers["Cache-Control"] = CACHE_CONTROL
            resp.headers["Access-Control-Allow-Origin"] = "*"
            resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
            resp.headers["Access-Control-Allow-Headers"] = "*"
            return resp

    # Nothing worked
    raise HTTPException(status_code=404, detail="not found")
