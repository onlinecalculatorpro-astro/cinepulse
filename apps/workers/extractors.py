# apps/workers/extractors.py
from __future__ import annotations

import html
import json
import os
import re
from typing import Iterable, Optional, Tuple, List, Dict, Any
from urllib.parse import urljoin, urlparse

__all__ = [
    "build_rss_payload",          # -> (payload: dict, thumb_hint: Optional[str], candidates: List[str])
    "choose_best_image",          # pick best from candidate URLs (largest srcset etc.)
    "abs_url",
    "to_https",
]

# ============================== Config ===============================

EXTRACT_DEBUG = os.getenv("EXTRACT_DEBUG", "0") not in ("0", "", "false", "False")

# Optional network fetch to page for OG/Twitter/JSON-LD discovery
OG_FETCH = os.getenv("OG_FETCH", "0") not in ("0", "", "false", "False")
OG_ALLOWED_DOMAINS = {
    d.strip().lower()
    for d in os.getenv("OG_ALLOWED_DOMAINS", "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com").split(",")
    if d.strip()
}
OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv(
    "FETCH_UA",
    "Mozilla/5.0 (compatible; CinePulseBot/1.0; +https://example.com/bot)"
)

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp")
# svg is excluded for thumbnails

# ============================== Helpers ==============================

def dlog(msg: str, *kv: Any) -> None:
    if EXTRACT_DEBUG:
        details = " | ".join(repr(k) for k in kv) if kv else ""
        print(f"[extract] {msg}{(' ' + details) if details else ''}")

def abs_url(url: Optional[str], base: str) -> Optional[str]:
    if not url:
        return None
    u = urlparse(url)
    if not u.scheme:
        return urljoin(base, url)
    return url

def to_https(url: Optional[str]) -> Optional[str]:
    if not url:
        return None
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("http://"):
        return "https://" + url[7:]
    return url

def _norm(url: Optional[str], base: str) -> Optional[str]:
    return to_https(abs_url(url, base))

def _looks_image(url: str) -> bool:
    u = url.lower().split("?", 1)[0]
    return u.endswith(IMG_EXTS)

def _pick_from_srcset(srcset: str) -> Optional[str]:
    # Choose largest width candidate
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

def _first_img_from_html(html_str: Optional[str], base: str) -> List[str]:
    """
    Collect image URLs embedded in HTML:
    - <img src=...> and lazy attrs (data-src, data-original, data-lazy-src, data-image)
    - srcset on <img>/<source> (largest)
    - <meta property="og:image"> in snippet
    - <link rel="image_src">
    - JSON-LD image
    Returns list of normalized URLs (may be empty).
    """
    if not html_str:
        return []
    s = html.unescape(html_str)

    out: List[str] = []

    # <img src="...">
    for m in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append(m.group(1))

    # lazy-load attributes
    for attr in ("data-src", "data-original", "data-lazy-src", "data-image"):
        for m in re.finditer(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I):
            out.append(m.group(1))

    # <img>/<source> srcset
    for m in re.finditer(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _pick_from_srcset(m.group(1))
        if pick:
            out.append(pick)

    # <meta property="og:image" content="...">
    for m in re.finditer(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']', s, flags=re.I):
        out.append(m.group(1))

    # <meta name="twitter:image" content="...">
    for m in re.finditer(r'<meta[^>]+name=["\']twitter:image(?::src)?["\'][^>]+content=["\']([^"\']+)["\']', s, flags=re.I):
        out.append(m.group(1))

    # <link rel="image_src" href="...">
    for m in re.finditer(r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append(m.group(1))

    # JSON-LD blocks with "image": "..."/["..."]
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', s, flags=re.I | re.S):
        try:
            data = json.loads(m.group(1).strip())
        except Exception:
            continue
        # handle object or list
        objs = data if isinstance(data, list) else [data]
        for obj in objs:
            img = obj.get("image")
            if isinstance(img, str):
                out.append(img)
            elif isinstance(img, list):
                for it in img:
                    if isinstance(it, str):
                        out.append(it)
                    elif isinstance(it, dict) and it.get("url"):
                        out.append(it["url"])
            elif isinstance(img, dict) and img.get("url"):
                out.append(img["url"])

    # Normalize + filter
    normed: List[str] = []
    seen = set()
    for u in out:
        u2 = _norm(u, base)
        if not u2:
            continue
        if not _looks_image(u2):
            # accept if content-type is unknown but URL hints image via path pieces
            # many sites output /og_image/… without ext; allow these if clearly image-like
            if not re.search(r"(og|thumb|image|poster|photo)", u2, re.I):
                continue
        if u2 not in seen:
            seen.add(u2)
            normed.append(u2)
    return normed

def _enclosures_from_entry(entry: Dict[str, Any]) -> List[str]:
    urls: List[str] = []
    # feedparser puts both entry.enclosures and links rel=enclosure
    for enc in entry.get("enclosures") or []:
        u = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
            urls.append(u)
    for l in entry.get("links") or []:
        if isinstance(l, dict) and l.get("rel") == "enclosure":
            u = l.get("href")
            typ = (l.get("type") or "").lower()
            if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
                urls.append(u)
    return urls

def _media_fields_from_entry(entry: Dict[str, Any]) -> List[str]:
    urls: List[str] = []
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list):
        for t in thumbs:
            if isinstance(t, dict) and t.get("url"):
                urls.append(t["url"])
    mcont = entry.get("media_content") or entry.get("media:content")
    if isinstance(mcont, list):
        for it in mcont:
            if not isinstance(it, dict):
                continue
            u = it.get("url") or it.get("href")
            typ = (it.get("type") or "").lower()
            if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
                urls.append(u)
    # simple custom fields
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str):
            urls.append(v)
        elif isinstance(v, dict) and v.get("href"):
            urls.append(v["href"])
    return urls

def _maybe_fetch_og(url: str) -> List[str]:
    if not OG_FETCH:
        return []
    host = urlparse(url).netloc.lower().replace("www.", "")
    if OG_ALLOWED_DOMAINS and not any(host.endswith(d) for d in OG_ALLOWED_DOMAINS):
        return []
    try:
        try:
            import requests  # type: ignore
            resp = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if resp.status_code >= 400:
                return []
            html_text = resp.text
        except Exception:
            # urllib fallback
            from urllib.request import Request, urlopen
            req = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=OG_TIMEOUT) as r:  # nosec - controlled by allowlist
                html_text = r.read().decode("utf-8", "ignore")
    except Exception:
        return []

    base = url
    found = _first_img_from_html(html_text, base)
    dlog("OG_FETCH", url, found[:3])
    return found

def _score_image_url(u: str) -> int:
    """
    Heuristic score: prefer larger-looking URLs (via srcset choice already),
    and deprioritize tiny/thumb/amp placeholders.
    """
    score = 0
    # higher score for larger hints (1200, 1600, 2048 etc.)
    for n in (4096, 3840, 2560, 2048, 1600, 1200, 1080, 1024, 800, 640):
        if re.search(fr"[^0-9]{n}[^0-9]", u):
            score += n // 100
            break
    # bumps for og/image keywords
    if re.search(r"(og|open[-_]?graph|hero|feature|large|full|original)", u, re.I):
        score += 50
    if re.search(r"(thumb|thumbnail|small|mini|amp)", u, re.I):
        score -= 40
    return score

def choose_best_image(candidates: Iterable[str]) -> Optional[str]:
    best = None
    best_score = -1 << 30
    for u in candidates:
        sc = _score_image_url(u)
        if sc > best_score:
            best, best_score = u, sc
    return best

# ============================ Main entry =============================

def build_rss_payload(entry: Dict[str, Any], feed_url: str) -> Tuple[Dict[str, Any], Optional[str], List[str]]:
    """
    Build a comprehensive payload from a feed entry.
    Returns: (payload_dict, thumb_hint, image_candidates)
    The payload matches what your normalize() expects, plus extra fields that
    you can ignore or log:
      - content_html / description_html / summary (raw)
      - enclosures (pass-through)
      - inline_images (from HTML blocks)
      - og_image (if OG_FETCH enabled and page probe used)
      - image_candidates (union of all sources; not required downstream)
    """
    # URL and HTML fields
    link = entry.get("link") or entry.get("id") or ""
    summary_html = entry.get("summary_detail", {}).get("value") or entry.get("summary") or entry.get("description") or ""
    content_html = ""
    content = entry.get("content")
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            content_html = first.get("value") or ""

    # Collect candidates from various sources
    cands: List[str] = []
    base = link or feed_url

    # media_* blocks and custom fields
    for u in _media_fields_from_entry(entry):
        u2 = _norm(u, base)
        if u2:
            cands.append(u2)

    # enclosures and rel=enclosure links
    for u in _enclosures_from_entry(entry):
        u2 = _norm(u, base)
        if u2:
            cands.append(u2)

    # from HTML blocks
    inline_imgs: List[str] = []
    for html_block in (content_html, summary_html):
        inline_imgs += _first_img_from_html(html_block, base)
    for u in inline_imgs:
        u2 = _norm(u, base)
        if u2:
            cands.append(u2)

    # normalize, unique, and filter to images
    uniq: List[str] = []
    seen = set()
    for u in cands:
        if not u:
            continue
        if u.lower().split("?", 1)[0].endswith(IMG_EXTS) or re.search(r"(og|thumb|image|poster|photo)", u, re.I):
            if u not in seen:
                uniq.append(u); seen.add(u)

    # Optional OG fetch if still empty
    og_image: Optional[str] = None
    if not uniq and OG_FETCH and link:
        page_imgs = _maybe_fetch_og(to_https(link) or link)
        for u in page_imgs:
            u2 = _norm(u, base)
            if u2 and (u2 not in seen):
                uniq.append(u2); seen.add(u2)
        if page_imgs:
            og_image = page_imgs[0]

    # Thumb hint = best candidate
    thumb_hint = choose_best_image(uniq) if uniq else None

    payload: Dict[str, Any] = {
        "url": to_https(abs_url(link, feed_url)) or link,
        "feed": feed_url,
        "content_html": content_html or "",
        "description_html": summary_html or "",
        "summary": entry.get("summary") or "",
        "enclosures": entry.get("enclosures") or [],
        # extras (not required by downstream, useful for audits)
        "inline_images": inline_imgs or None,
        "og_image": og_image,
        "image_candidates": uniq or None,
    }

    dlog("built_payload", {"url": payload["url"], "thumb_hint": thumb_hint, "candidates": (uniq[:3] if uniq else [])})
    return payload, thumb_hint, uniq
