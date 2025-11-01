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

# obvious "don't proxy this" traps
_BAD_PATH_PATTERNS = re.compile(r"/wp-login\.php|action=logout", re.IGNORECASE)

# Chrome sometimes appends :1 to image URLs. Strip that.
_TRAILING_COLON_NUM = re.compile(r":\d+$")

# never allow hitting ourselves / localhost / private IP literal / internal svc
_BLOCKED_HOSTS = {
    "api.nutshellnewsapp.com",  # our own API (avoid recursion)
    "api",                      # docker service name (internal)
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}

# CDN host → expected publisher Referer
# (endswith match; add more as needed)
_PUBLISHER_REFERERS: list[tuple[str, str]] = [
    ("c.ndtvimg.com",                 "https://www.ndtv.com/"),
    ("i.ndtvimg.com",                 "https://www.ndtv.com/"),
    ("i.hindustantimes.com",          "https://www.hindustantimes.com/"),
    ("images.hindustantimes.com",     "https://www.hindustantimes.com/"),
    ("images.livemint.com",           "https://www.livemint.com/"),
    ("static.toiimg.com",             "https://timesofindia.indiatimes.com/"),
    ("img.etimg.com",                 "https://economictimes.indiatimes.com/"),
    ("th-i.thgim.com",                "https://www.thehindu.com/"),
    ("images.indianexpress.com",      "https://indianexpress.com/"),
    ("images.newindianexpress.com",   "https://www.newindianexpress.com/"),
    ("akm-img-a-in.tosshub.com",      "https://www.indiatoday.in/"),
    ("bsmedia.business-standard.com", "https://www.business-standard.com/"),
    ("img.etb2bimg.com",              "https://economictimes.indiatimes.com/"),
]

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
    """
    If caller passes a literal IP, block RFC1918 / loopback / etc.
    We don't do DNS resolution here (intentionally).
    """
    if not host:
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        # it's a hostname, not an IP literal
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


def _first_path_segment(path: str) -> str:
    """
    For '/newspaper/wp-content/uploads/x.jpg' -> 'newspaper'.
    For '/' or '' -> ''.
    """
    if not path.startswith("/"):
        return ""
    parts = path.split("/")
    if len(parts) > 1 and parts[1]:
        return parts[1]
    return ""


def _publisher_referer_for(host: str, path: str) -> str:
    """
    If the CDN host is a known one, return its publisher-site Referer.
    Else fall back to host[/first-seg]/.
    """
    h = host.lower()
    for suffix, ref in _PUBLISHER_REFERERS:
        if h.endswith(suffix):
            return ref
    seg = _first_path_segment(path)
    return f"https://{host}/{seg}/" if seg else f"https://{host}/"


def _build_headers(origin_host: str, origin_path: str, *, alt: bool) -> dict[str, str]:
    """
    alt = False  -> send publisher Referer (or host[/first-seg]/ if unknown)
    alt = True   -> no Referer (some CDNs dislike spoofing)
    Also set Origin to the same site as Referer for stricter CDNs.
    """
    if not alt:
        referer_base = _publisher_referer_for(origin_host, origin_path)
        return {
            "User-Agent": BROWSER_UA,
            "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": referer_base,
            "Origin": referer_base.rstrip("/"),
            "Connection": "keep-alive",
        }
    # alt headers (no Referer)
    return {
        "User-Agent": BROWSER_UA,
        "Accept": "image/*,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.8",
        "Connection": "keep-alive",
    }


def _sanitize_tail_colon(full_url: str) -> str:
    """
    Strip a trailing :<digits> from the *path* portion.
    e.g. .../couple.jpg:1 -> .../couple.jpg
    """
    p = urlparse(full_url)
    new_path = _TRAILING_COLON_NUM.sub("", p.path or "")
    if new_path != p.path:
        p = p._replace(path=new_path)
        return urlunparse(p)
    return full_url


def _parse_source_url(raw_u: str) -> Tuple[str, str, str, str]:
    """
    Decode ?u=..., validate scheme/host/path, block SSRF.
    Return (original_full_url, sanitized_full_url, host, path).
    """
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

    # SSRF guard 1: block obviously sensitive hosts
    if host in _BLOCKED_HOSTS or any(host.endswith("." + b) for b in _BLOCKED_HOSTS):
        raise HTTPException(status_code=400, detail="forbidden host")

    # SSRF guard 2: block literal private IPs
    if _host_is_private_ip_literal(host):
        raise HTTPException(status_code=400, detail="forbidden host")

    # Kill obvious login/logout bait
    if _BAD_PATH_PATTERNS.search(path):
        raise HTTPException(status_code=404, detail="not an image")

    sanitized_full = _sanitize_tail_colon(orig_full)
    return orig_full, sanitized_full, host, path


async def _try_fetch(
    client: httpx.AsyncClient,
    full_url: str,
    host: str,
    path: str,
    alt: bool,
) -> Optional[httpx.Response]:
    """
    alt=False -> with Referer
    alt=True  -> without Referer
    Return Response if it's a good candidate, else None to indicate "try next".
    """
    try:
        r = await client.get(full_url, headers=_build_headers(host, path, alt=alt))
    except httpx.RequestError:
        # DNS/TLS/timeout/etc -> treat as "keep trying"
        return None

    # Many WordPress/CDNs hotlink-protect with fake 4xx;
    # accept only success-ish here.
    if r.status_code in (401, 403, 404, 451):
        return None

    if r.status_code >= 500:
        # hard upstream failure -> surface as 502 immediately
        raise HTTPException(status_code=502, detail=f"upstream {r.status_code}")

    if r.status_code >= 400:
        # other 4xx after we've tried all tricks -> we'll treat as 404 later
        return r

    return r

# ────────────────────────────────────────────────────────────────────────────
# Endpoint
# ────────────────────────────────────────────────────────────────────────────

@router.api_route("/img", methods=["GET", "HEAD", "OPTIONS"])
async def proxy_img(
    request: Request,
    u: Optional[str] = Query(None, description="Absolute image URL (URL-encoded)"),
    url: Optional[str] = Query(None, description="Alias for 'u'"),
):
    """
    CORS-safe image proxy for thumbnails/posters.

    Strategy:
      1) Build up to 4 attempts:
         a) original URL + publisher Referer
         b) original URL + no Referer
         c) sanitized URL (strip :1) + publisher Referer
         d) sanitized URL + no Referer
      2) First response <400 wins.
      3) If final response is still 4xx, return 404.
      4) Stream only if Content-Type looks like image/*.
    """
    # CORS preflight
    if request.method == "OPTIONS":
        return Response(status_code=204, headers=_cors_headers())

    raw = u or url
    orig_url, sani_url, host, path = _parse_source_url(raw or "")

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    ) as client:
        attempts: list[tuple[str, bool]] = [
            (orig_url, False),
            (orig_url, True),
        ]
        if sani_url != orig_url:
            attempts.extend([(sani_url, False), (sani_url, True)])

        winner: Optional[httpx.Response] = None
        for full_url, alt in attempts:
            r = await _try_fetch(client, full_url, host, path, alt)
            if r is None:
                continue
            winner = r
            break

        if winner is None:
            # everything was 401/403/404/451 or network error → "not found"
            raise HTTPException(status_code=404, detail="not found")

        # At this point winner.status_code could still be 4xx (other than those fakes)
        if winner.status_code >= 400:
            raise HTTPException(status_code=404, detail=f"blocked ({winner.status_code})")

        ct = winner.headers.get("Content-Type", "")
        if not _looks_like_image(ct):
            raise HTTPException(status_code=404, detail="not an image")

        headers = _cors_headers()
        # Preserve origin Content-Length when present
        if "Content-Length" in winner.headers:
            headers["Content-Length"] = winner.headers["Content-Length"]
        # Be explicit about the media type (strip params)
        media_type = ct.split(";", 1)[0] if ct else "application/octet-stream"
        headers["Content-Type"] = media_type
        headers["Content-Disposition"] = 'inline; filename="proxy-image"'

        # HEAD should return headers only
        if request.method == "HEAD":
            return Response(status_code=200, headers=headers)

        return StreamingResponse(
            winner.aiter_bytes(),
            status_code=200,
            media_type=media_type,
            headers=headers,
        )
