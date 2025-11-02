# apps/api/app/img_proxy.py
from __future__ import annotations

import ipaddress
import re
from typing import Optional, Tuple, List
from urllib.parse import urlparse, urlunparse, unquote, quote

import httpx
from fastapi import APIRouter, Query, Request, Response
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/v1", tags=["img"])

# ── Tunables ──────────────────────────────────────────────────────────────────
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

_BAD_PATH = re.compile(r"/wp-login\.php|action=logout", re.IGNORECASE)
_TRAILING_COLON_NUM = re.compile(r":\d+$")  # “…/img.jpg:1” from Chrome

# Never allow internal/loopback/our own domains (avoid recursion)
_BLOCKED_HOSTS = {
    "api.nutshellnewsapp.com",
    "app.nutshellnewsapp.com",
    "api",
    "localhost",
    "localhost.localdomain",
    "127.0.0.1",
    "0.0.0.0",
}

# Publisher → homepage Referer
_PUBLISHER_REFERERS: List[tuple[str, str]] = [
    ("ndtvimg.com",                 "https://www.ndtv.com/"),
    ("c.ndtvimg.com",               "https://www.ndtv.com/"),
    ("i.ndtvimg.com",               "https://www.ndtv.com/"),
    ("i.hindustantimes.com",        "https://www.hindustantimes.com/"),
    ("images.hindustantimes.com",   "https://www.hindustantimes.com/"),
    ("images.livemint.com",         "https://www.livemint.com/"),
    ("static.toiimg.com",           "https://timesofindia.indiatimes.com/"),
    ("img.etimg.com",               "https://economictimes.indiatimes.com/"),
    ("th-i.thgim.com",              "https://www.thehindu.com/"),
    ("images.indianexpress.com",    "https://indianexpress.com/"),
    ("images.newindianexpress.com", "https://www.newindianexpress.com/"),
    ("akm-img-a-in.tosshub.com",    "https://www.indiatoday.in/"),
    ("bsmedia.business-standard.com","https://www.business-standard.com/"),
    ("img.etb2bimg.com",            "https://economictimes.indiatimes.com/"),
    ("assets.bollywoodhungama.in",  "https://www.bollywoodhungama.com/"),
    ("staticimg.amarujala.com",     "https://www.amarujala.com/"),
    ("images.indiatvnews.com",      "https://www.indiatvnews.com/"),
    ("static-koimoi.akamaized.net", "https://www.koimoi.com/"),
    ("i.ytimg.com",                 "https://www.youtube.com/"),
]

# NDTV alternate image hosts (try before weserv)
_NDTV_ALTS = ("i.ndtvimg.com", "c.ndtvimg.com")

SVG_PLACEHOLDER = b"""<svg xmlns='http://www.w3.org/2000/svg' width='100' height='60'>
  <rect width='100' height='60' fill='#eef1f5'/>
  <text x='50' y='32' font-size='14' text-anchor='middle' fill='#8b95a7'>No Image</text>
</svg>
"""

# ── Helpers ───────────────────────────────────────────────────────────────────
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
        ip.is_private or ip.is_loopback or ip.is_link_local
        or ip.is_reserved or ip.is_multicast
    )

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

def _publisher_referer_for(host: str, path: str) -> str:
    h = host.lower()
    for suffix, ref in _PUBLISHER_REFERERS:
        if h.endswith(suffix):
            return ref
    seg = _first_path_segment(path)
    return f"https://{host}/{seg}/" if seg else f"https://{host}/"

def _headers_variant(origin_host: str, origin_path: str, mode: str, page_ref: Optional[str]) -> dict[str, str]:
    """
    modes: "page_ref" | "page_ref_no_origin" | "pub" | "pub_no_origin" | "self" | "self_no_origin" | "no_ref" | "amp"
    """
    base = {
        "User-Agent": BROWSER_UA,
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Connection": "keep-alive",
        "Accept-Encoding": "identity",  # ensure uncompressed body → avoid length mismatches
        # (Sec-Fetch-* intentionally omitted; some origins dislike them from non-browsers)
    }

    if mode.startswith("page_ref"):
        if page_ref:
            pr = urlparse(page_ref)
            if pr.scheme in ("http", "https") and pr.netloc:
                base["Referer"] = page_ref
                if mode == "page_ref":
                    base["Origin"] = f"{pr.scheme}://{pr.netloc}"
        return base

    if mode.startswith("pub"):
        ref = _publisher_referer_for(origin_host, origin_path)
    elif mode.startswith("self"):
        seg = _first_path_segment(origin_path)
        ref = f"https://{origin_host}/{seg}/" if seg else f"https://{origin_host}/"
    elif mode == "amp":
        # AMP usually works without ref/origin
        return base
    else:
        ref = ""

    if mode in ("pub", "self"):
        base["Referer"] = ref
        base["Origin"] = ref.rstrip("/")
    elif mode in ("pub_no_origin", "self_no_origin"):
        base["Referer"] = ref
    return base

def _sanitize_tail_colon(full_url: str) -> str:
    p = urlparse(full_url)
    new_path = _TRAILING_COLON_NUM.sub("", p.path or "")
    if new_path != p.path:
        p = p._replace(path=new_path)
        return urlunparse(p)
    return full_url

def _parse_source_url(raw_u: str) -> Tuple[str, str, str]:
    if not raw_u:
        return "", "", ""
    orig_full = unquote(raw_u).strip()
    p = urlparse(orig_full)
    if p.scheme not in {"http", "https"} or not p.netloc:
        return "", "", ""
    host = (p.hostname or "").strip().lower()
    path = p.path or ""
    return _sanitize_tail_colon(orig_full), host, path

def _weserv_urls(full_url: str) -> list[str]:
    """Weserv proxy (last resort)."""
    p = urlparse(full_url)
    host = p.hostname or ""
    path = quote(p.path or "", safe="/._-~%")
    query = f"?{p.query}" if p.query else ""
    hpq = f"{host}{path}{query}"
    proto = "ssl:" if p.scheme == "https" else ""
    return [f"https://images.weserv.nl/?url={proto}{hpq}&n=-1"]

def _replace_host(full_url: str, new_host: str) -> str:
    p = urlparse(full_url)
    if not p.netloc:
        return full_url
    return urlunparse(p._replace(netloc=new_host))

def _amp_urls(full_url: str, page_ref: Optional[str]) -> list[str]:
    """
    Google AMP cache relay:
      https://<site-host-with-dashes>.cdn.ampproject.org/i/s/<image-host>/<path>
    """
    try:
        img = urlparse(full_url)
        if not img.scheme or not img.netloc:
            return []
        site_host = None
        if page_ref:
            pr = urlparse(page_ref)
            if pr.netloc:
                site_host = pr.netloc
        # fallback: derive a plausible site host from image host (last two labels)
        if not site_host:
            parts = (img.hostname or "").split(".")
            if len(parts) >= 2:
                site_host = ".".join(parts[-2:])
        if not site_host:
            return []
        amp_host = f"{site_host.replace('.', '-')}.cdn.ampproject.org"
        prefix = "/i/s/" if img.scheme == "https" else "/i/"
        path = quote(img.path or "", safe="/._-~%")
        q = f"?{img.query}" if img.query else ""
        return [f"https://{amp_host}{prefix}{img.hostname}{path}{q}"]
    except Exception:
        return []

def _placeholder_response(debug: Optional[str] = None) -> Response:
    headers = _cors_headers()
    headers["Content-Type"] = "image/svg+xml"
    headers["Content-Disposition"] = 'inline; filename="placeholder.svg"'
    if debug:
        headers["X-Proxy-Attempts"] = debug
    return Response(status_code=200, headers=headers, content=SVG_PLACEHOLDER)

def _is_ndtv_img_host(host: str) -> bool:
    return host.endswith("ndtvimg.com")

# ── Endpoint ──────────────────────────────────────────────────────────────────
@router.api_route("/img", methods=["GET", "HEAD", "OPTIONS"])
async def proxy_img(
    request: Request,
    u:   Optional[str] = Query(None, description="Absolute image URL (URL-encoded)"),
    url: Optional[str] = Query(None, description="Alias for 'u'"),
    ref: Optional[str] = Query(None, description="Article/page URL used as Referer"),
    noamp: Optional[int] = Query(0, description="Skip AMP fallback if set"),
    dbg: Optional[int] = Query(0,    description="Set 1 to return X-Proxy-Attempts"),
):
    # CORS preflight
    if request.method == "OPTIONS":
        return Response(status_code=204, headers=_cors_headers())

    raw = u or url
    full_url, host, path = _parse_source_url(raw or "")

    # Reject early → placeholder (non-noisy)
    if not full_url or not host:
        return _placeholder_response()
    if host in _BLOCKED_HOSTS or any(host.endswith("." + b) for b in _BLOCKED_HOSTS):
        return _placeholder_response()
    if _host_is_private_ip_literal(host) or _BAD_PATH.search(path or ""):
        return _placeholder_response()

    # Build attempt list with NDTV-special handling
    attempts: List[tuple[str, str]] = []

    # 0) NDTV: AMP first (unless noamp=1), then alt image hosts
    if _is_ndtv_img_host(host):
        if not noamp:
            for amp in _amp_urls(full_url, ref or "https://www.ndtv.com/"):
                attempts.append((amp, "amp"))
        for alt in _NDTV_ALTS:
            if host != alt:
                attempts.append((_replace_host(full_url, alt), "pub"))

    # 1) Normal attempt modes
    modes: List[str] = []
    if ref:
        modes += ["page_ref", "page_ref_no_origin"]
    modes += ["pub", "pub_no_origin", "self", "self_no_origin", "no_ref"]
    for m in modes:
        attempts.append((full_url, m))

    # 2) Weserv last resort
    attempts += [(w, "weserv") for w in _weserv_urls(full_url)]

    debug_notes: List[str] = []
    winner: Optional[httpx.Response] = None

    async with httpx.AsyncClient(
        timeout=TOTAL_TIMEOUT,
        follow_redirects=True,
        max_redirects=MAX_REDIRECTS,
        limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
    ) as client:
        for target_url, mode in attempts:
            try:
                # NDTV cookie warm-up for page_ref modes: load the page ref first (sets cookies)
                if _is_ndtv_img_host(host) and mode.startswith("page_ref") and ref:
                    try:
                        pr = urlparse(ref)
                        if pr.scheme in ("http", "https") and pr.netloc:
                            await client.get(
                                ref,
                                headers={
                                    "User-Agent": BROWSER_UA,
                                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                                    "Accept-Language": "en-US,en;q=0.9",
                                    "Connection": "keep-alive",
                                },
                            )
                    except httpx.RequestError:
                        pass

                r = await client.get(target_url, headers=_headers_variant(host, path, mode, ref))
            except httpx.RequestError as e:
                debug_notes.append(f"{mode} neterr:{type(e).__name__}")
                continue

            ct = r.headers.get("Content-Type", "")
            cts = ct.split(";", 1)[0] if ct else ""
            debug_notes.append(f"{mode} {r.status_code} {cts or '-'}")

            if r.status_code < 400 and _looks_like_image(ct):
                winner = r
                break
            # else: try next attempt

    if winner is None:
        debug = " | ".join(debug_notes) if dbg else None
        return _placeholder_response(debug=debug)

    # Success: stream the image
    media_type = (winner.headers.get("Content-Type", "") or "application/octet-stream").split(";", 1)[0]
    headers = _cors_headers()
    if dbg:
        headers["X-Proxy-Attempts"] = " | ".join(debug_notes)
    headers["Content-Type"] = media_type
    headers["Content-Disposition"] = 'inline; filename="proxy-image"'

    if request.method == "HEAD":
        return Response(status_code=200, headers=headers)

    return StreamingResponse(
        winner.aiter_bytes(),
        status_code=200,
        media_type=media_type,
        headers=headers,
    )
