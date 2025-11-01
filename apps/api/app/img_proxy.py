# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional, Tuple
from urllib.parse import urlparse, urlunparse, unquote

import httpx
from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# ────────────────────────────────────────────────────────────────────────────
# Tunables
# ────────────────────────────────────────────────────────────────────────────

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
_TRAILING_COLON_NUM = re.compile(r":\d+$")

_BLOCKED_HOSTS = {
    "api.nutshellnewsapp.com",  # avoid recursion
    "api",                      # docker svc name
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}

# CDN host → ordered list of referers to try (publisher then CDN self)
_CDN_REFERERS: dict[str, list[str]] = {
    # NDTV
    "c.ndtvimg.com": ["https://www.ndtv.com/", "https://c.ndtvimg.com/"],
    "i.ndtvimg.com": ["https://www.ndtv.com/", "https://i.ndtvimg.com/"],
    # HT / Mint
    "i.hindustantimes.com": ["https://www.hindustantimes.com/", "https://i.hindustantimes.com/"],
    "images.hindustantimes.com": ["https://www.hindustantimes.com/", "https://images.hindustantimes.com/"],
    "images.livemint.com": ["https://www.livemint.com/", "https://images.livemint.com/"],
    # TOI / ET
    "static.toiimg.com": ["https://timesofindia.indiatimes.com/", "https://static.toiimg.com/"],
    "img.etimg.com": ["https://economictimes.indiatimes.com/", "https://img.etimg.com/"],
    "img.etb2bimg.com": ["https://economictimes.indiatimes.com/", "https://img.etb2bimg.com/"],
    # The Hindu
    "th-i.thgim.com": ["https://www.thehindu.com/", "https://th-i.thgim.com/"],
    # Indian Express
    "images.indianexpress.com": ["https://indianexpress.com/", "https://images.indianexpress.com/"],
    "images.newindianexpress.com": ["https://www.newindianexpress.com/", "https://images.newindianexpress.com/"],
    # India Today / TossHub
    "akm-img-a-in.tosshub.com": ["https://www.indiatoday.in/", "https://akm-img-a-in.tosshub.com/"],
    # Business Standard
    "bsmedia.business-standard.com": ["https://www.business-standard.com/", "https://bsmedia.business-standard.com/"],
}

# ────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────

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
    return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast

def _looks_like_image(content_type: Optional[str]) -> bool:
    if not content_type:
        return False
    ct = content_type.lower().split(";", 1)[0].strip()
    return ct.startswith("image/") or ct == "application/octet-stream"

def _first_path_segment(path: str) -> str:
    if not path.startswith("/"):
        return ""
    parts = path.split("/")
    return parts[1] if len(parts) > 1 and parts[1] else ""

def _referers_for(host: str, path: str) -> list[str]:
    host = host.lower()
    # exact/suffix match to configured CDNs
    for cdn_host, refs in _CDN_REFERERS.items():
        if host == cdn_host or host.endswith("." + cdn_host):
            return refs
    # default: try host/first-seg then host/
    seg = _first_path_segment(path)
    host_only = f"https://{host}/"
    host_with_seg = f"https://{host}/{seg}/" if seg else host_only
    return [host_with_seg, host_only]

def _headers_with_referer(ref: str) -> dict[str, str]:
    return {
        "User-Agent": BROWSER_UA,
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Referer": ref,
        "Origin": ref.rstrip("/"),
        "Sec-Fetch-Dest": "image",
        "Sec-Fetch-Mode": "no-cors",
        "Sec-Fetch-Site": "cross-site",
        "Connection": "keep-alive",
    }

_NO_REF_HEADERS = {
    "User-Agent": BROWSER_UA,
    "Accept": "image/*,*/*;q=0.5",
    "Accept-Language": "en-US,en;q=0.8",
    "Sec-Fetch-Dest": "image",
    "Sec-Fetch-Mode": "no-cors",
    "Sec-Fetch-Site": "cross-site",
    "Connection": "keep-alive",
}

def _sanitize_tail_colon(full_url: str) -> str:
    p = urlparse(full_url)
    new_path = _TRAILING_COLON_NUM.sub("", p.path or "")
    if new_path != p.path:
        p = p._replace(path=new_path)
        return urlunparse(p)
    return full_url

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
    if _BAD_PATH_PATTERNS.search(path):
        raise HTTPException(status_code=404, detail="not an image")
    sanitized_full = _sanitize_tail_colon(orig_full)
    return orig_full, sanitized_full, host, path

# ────────────────────────────────────────────────────────────────────────────
# Endpoint
# ────────────────────────────────────────────────────────────────────────────

@router.api_route("/img", methods=["GET", "HEAD", "OPTIONS"])
async def proxy_img(
    request: Request,
    u: Optional[str] = Query(None, description="Absolute image URL (URL-encoded)"),
    url: Optional[str] = Query(None, description="Alias for 'u'"),
):
    # Preflight
    if request.method == "OPTIONS":
        return Response(status_code=204, headers=_cors_headers())

    raw = u or url
    orig_url, sani_url, host, path = _parse_source_url(raw or "")

    # Build attempt matrix: for each URL variant, try multiple Referers then no-Referer
    candidate_urls = [orig_url]
    if sani_url != orig_url:
        candidate_urls.append(sani_url)

    attempts: list[tuple[str, dict[str, str]]] = []
    refs = _referers_for(host, path)
    for cu in candidate_urls:
        for ref in refs:
            attempts.append((cu, _headers_with_referer(ref)))
        attempts.append((cu, _NO_REF_HEADERS))  # last resort

    winner: Optional[httpx.Response] = None
    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    ) as client:
        for full_url, headers in attempts:
            try:
                r = await client.get(full_url, headers=headers)
            except httpx.RequestError:
                continue
            # Ignore hotlink-protection 4xx; keep trying
            if r.status_code in (401, 403, 404, 451):
                continue
            if r.status_code >= 500:
                raise HTTPException(status_code=502, detail=f"upstream {r.status_code}")
            if r.status_code < 400:
                winner = r
                break

    if winner is None:
        raise HTTPException(status_code=404, detail="not found")

    ct = winner.headers.get("Content-Type", "")
    if not _looks_like_image(ct):
        raise HTTPException(status_code=404, detail="not an image")

    media_type = ct.split(";", 1)[0] if ct else "application/octet-stream"
    headers = _cors_headers()
    headers["Content-Type"] = media_type
    headers["Content-Disposition"] = 'inline; filename="proxy-image"'
    if "Content-Length" in winner.headers:
        headers["Content-Length"] = winner.headers["Content-Length"]

    if request.method == "HEAD":
        return Response(status_code=200, headers=headers)

    return StreamingResponse(
        winner.aiter_bytes(),
        status_code=200,
        media_type=media_type,
        headers=headers,
    )
