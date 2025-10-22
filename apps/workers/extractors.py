# apps/workers/extractors.py
from __future__ import annotations

import html
import os
import re
import socket
import ssl
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional, Tuple, Dict, Any
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

DEBUG_IMAGES = os.getenv("DEBUG_IMAGES", "0") not in ("0", "", "false", "False")

# Controlled, *optional* page fetch for OG images (default OFF).
OG_FETCH = os.getenv("OG_FETCH", "0") not in ("0", "", "false", "False")
OG_ALLOWED_DOMAINS = {
    d.strip().lower() for d in os.getenv("OG_ALLOWED_DOMAINS", "").split(",") if d.strip()
}
OG_TIMEOUT = float(os.getenv("OG_TIMEOUT_SEC", "4.0"))
OG_MAX_BYTES = int(os.getenv("OG_MAX_BYTES", str(600_000)))  # 600 KB cap

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp")

# ---------------------------------------------------------------------
# Small utils
# ---------------------------------------------------------------------

def _log(reason: str, data: Dict[str, Any] | None = None) -> None:
    if DEBUG_IMAGES:
        print(f"[extract] {reason} | {data or {}}")

def _abs_url(url: Optional[str], base: str) -> Optional[str]:
    if not url:
        return None
    u = urlparse(url)
    if not u.scheme:
        return urljoin(base, url)
    return url

def _to_https(url: Optional[str]) -> Optional[str]:
    if not url:
        return None
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("http://"):
        return "https://" + url[7:]
    return url

def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"

def _pick_from_srcset(srcset: str) -> Optional[str]:
    best_url, best_w = None, -1
    for part in srcset.split(","):
        tokens = part.strip().split()
        if not tokens:
            continue
        u = tokens[0]
        w = 0
        if len(tokens) > 1 and tokens[1].endswith("w"):
            try:
                w = int(re.sub(r"\D", "", tokens[1]))
            except Exception:
                w = 0
        if w >= best_w:
            best_url, best_w = u, w
    return best_url

def _first_img_from_html(html_str: Optional[str], base: str) -> Optional[str]:
    """
    Robustly pull the first usable image URL from an HTML snippet.
    Handles: <img src>, lazy-load attrs, srcset on <img>/<source>, inline OG tag.
    """
    if not html_str:
        return None

    s = html.unescape(html_str)

    # 1) Standard src=
    m = re.search(r'<img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        u = _abs_url(m.group(1), base)
        _log("img.src", {"url": u, "base": base})
        return u

    # 2) Lazy-load attributes
    for attr in ("data-src", "data-original", "data-lazy-src", "data-image"):
        m = re.search(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I)
        if m:
            u = _abs_url(m.group(1), base)
            _log(f"img.{attr}", {"url": u, "base": base})
            return u

    # 3) srcset on <img> or <source>
    m = re.search(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        pick = _pick_from_srcset(m.group(1))
        if pick:
            u = _abs_url(pick, base)
            _log("srcset", {"url": u, "base": base})
            return u

    # 4) Inline OG tag (rare in feed snippets, but cheap)
    m = re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        u = _abs_url(m.group(1), base)
        _log("og:image(snippet)", {"url": u, "base": base})
        return u

    return None

# ---------------------------------------------------------------------
# Optional Open Graph fetch (allowlisted domains only)
# ---------------------------------------------------------------------

def _http_get(url: str, timeout: float) -> Optional[bytes]:
    """
    Tiny GET with urllib (no extra deps), with basic safeguards.
    """
    try:
        req = Request(url, headers={"User-Agent": "CinePulseBot/1.0 (+https://example)"})
        ctx = ssl.create_default_context()
        with urlopen(req, timeout=timeout, context=ctx) as resp:
            if int(resp.getcode() or 200) >= 400:
                return None
            buf = resp.read(OG_MAX_BYTES + 1)
            return buf[:OG_MAX_BYTES]
    except (socket.timeout, Exception):
        return None

def _extract_og_image(html_bytes: Optional[bytes], base: str) -> Optional[str]:
    if not html_bytes:
        return None
    # work on text safely
    try:
        s = html_bytes.decode("utf-8", errors="ignore")
    except Exception:
        return None

    # og:image and twitter:image (secure_url too)
    rx = re.compile(
        r'<meta[^>]+(?:property|name)=["\'](?:og:image|og:image:secure_url|twitter:image)["\'][^>]+content=["\']([^"\']+)["\']',
        re.I,
    )
    m = rx.search(s)
    if m:
        u = _abs_url(m.group(1), base)
        _log("og:image(page)", {"url": u, "base": base})
        return u
    return None

def maybe_fetch_og_image(article_url: str) -> Optional[str]:
    if not OG_FETCH or not article_url:
        return None
    dom = _domain(article_url)
    if OG_ALLOWED_DOMAINS and dom not in OG_ALLOWED_DOMAINS:
        _log("og_fetch_skipped_not_allowlisted", {"domain": dom})
        return None
    page = _http_get(article_url, OG_TIMEOUT)
    if not page:
        _log("og_fetch_failed", {"url": article_url})
        return None
    return _extract_og_image(page, article_url)

# ---------------------------------------------------------------------
# RSS entry → adapter event
# ---------------------------------------------------------------------

def _link_thumb(entry: dict) -> Optional[str]:
    # feedparser media fields
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list) and thumbs:
        url = thumbs[0].get("url") if isinstance(thumbs[0], dict) else None
        if url:
            return url

    # media_content often holds images too
    mcont = entry.get("media_content") or entry.get("media:content")
    if isinstance(mcont, list):
        for it in mcont:
            if isinstance(it, dict):
                u = it.get("url") or it.get("href")
                if u and (it.get("type", "").lower().startswith("image/") or str(u).lower().endswith(IMG_EXTS)):
                    return u

    # enclosure links
    for l in entry.get("links") or []:
        if isinstance(l, dict) and l.get("rel") == "enclosure" and (l.get("type", "") or "").lower().startswith("image/"):
            return l.get("href")

    # simple custom fields
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str) and v.startswith(("http://", "https://")):
            return v
        if isinstance(v, dict) and v.get("href"):
            return v["href"]
    return None

def _to_rfc3339(value) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    v = str(value).strip()
    return v if v else None

def rss_entry_to_event(entry: dict, feed_url: str, kind_hint: str = "news") -> Optional[dict]:
    """
    Convert a feedparser `entry` to your AdapterEventDict for normalization.
    - Builds a strong thumb hint from media/enclosure/HTML.
    - Optionally fetches OG image from the article page (allowlisted).
    """
    title = entry.get("title", "") or ""
    link = entry.get("link") or entry.get("id") or ""
    if not link:
        return None

    source_domain = _domain(entry.get("source", {}).get("href") or feed_url)
    pub_norm = _to_rfc3339(
        entry.get("published_parsed")
        or entry.get("updated_parsed")
        or entry.get("published")
        or entry.get("updated")
    )

    # Prefer full content HTML if present, else summary/description
    content_html = ""
    content = entry.get("content")
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            content_html = first.get("value") or ""

    description_html = (
        entry.get("summary_detail", {}).get("value")
        or entry.get("summary")
        or entry.get("description")
        or ""
    )

    # Strong thumbnail hint
    base = link or feed_url
    thumb = _link_thumb(entry)

    if not thumb:
        # Try pulling from HTML blocks
        for key in ("content_html", "summary_detail", "summary", "description", "description_html"):
            s = (
                content_html if key == "content_html"
                else entry.get("summary_detail", {}).get("value") if key == "summary_detail"
                else description_html if key in ("summary", "description", "description_html")
                else None
            )
            u = _first_img_from_html(s, base)
            if u:
                thumb = u
                break

    # (Optional) OG fetch from article page
    if not thumb:
        og = maybe_fetch_og_image(link)
        if og:
            thumb = og

    # Normalize protocol and absoluteness for the hint
    thumb = _to_https(_abs_url(thumb, base)) if thumb else None

    ev = {
        "source": f"rss:{source_domain}",
        "source_event_id": "",  # fill in caller with hash if desired
        "title": title,
        "kind": kind_hint,
        "published_at": pub_norm,
        "thumb_url": thumb,
        "payload": {
            "url": link,
            "feed": feed_url,
            "content_html": content_html,
            "description_html": description_html,
            "summary": entry.get("summary") or "",
            "enclosures": entry.get("enclosures") or [],
        },
    }
    _log("rss_entry_to_event", {"title": title, "thumb": thumb, "domain": source_domain})
    return ev
