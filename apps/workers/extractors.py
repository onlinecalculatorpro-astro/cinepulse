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
    "choose_best_image",          # pick best from candidate URLs (heuristic)
    "abs_url",
    "to_https",
]

# ============================== Config ===============================

EXTRACT_DEBUG = os.getenv("EXTRACT_DEBUG", "0").lower() not in ("0", "", "false", "no")

# Optional network fetch to page for richer discovery
OG_FETCH = os.getenv("OG_FETCH", "1").lower() not in ("0", "", "false", "no")
# Allow-list of domains we are OK probing (comma-separated, suffix match)
OG_ALLOWED_DOMAINS = {
    d.strip().lower()
    for d in os.getenv("OG_ALLOWED_DOMAINS",
                       "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com,deadline.com,indiewire.com,slashfilm.com").split(",")
    if d.strip()
}
# Also try AMP page if present (link[rel=amphtml])
AMP_FETCH = os.getenv("AMP_FETCH", "1").lower() not in ("0", "", "false", "no")
# Optionally HEAD-probe non-extension URLs to ensure image/* (guarded)
HEAD_PROBE = os.getenv("HEAD_PROBE", "0").lower() not in ("0", "", "false", "no")

OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv(
    "FETCH_UA",
    "Mozilla/5.0 (compatible; CinePulseBot/1.1; +https://example.com/bot)"
)

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".jfif", ".pjpeg")  # (svg excluded for thumbs)

# ============================== Helpers ==============================

def dlog(msg: str, *kv: Any) -> None:
    if EXTRACT_DEBUG:
        details = " | ".join(repr(k) for k in kv) if kv else ""
        print(f"[extract] {msg}{(' ' + details) if details else ''}")

def abs_url(url: Optional[str], base: str) -> Optional[str]:
    if not url:
        return None
    # unescape entities like &amp;
    url = html.unescape(url.strip())
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

def _looks_image_like(url: str) -> bool:
    """Accept typical extensions OR obvious 'image' cue paths even without extension."""
    base = url.split("?", 1)[0].lower()
    if base.endswith(IMG_EXTS):
        return True
    return bool(re.search(r"(og|open[-_]?graph|image|thumb|thumbnail|poster|photo|hero)", base))

def _fetch_text(url: str) -> Optional[str]:
    try:
        try:
            import requests  # type: ignore
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if r.status_code >= 400:
                return None
            return r.text
        except Exception:
            from urllib.request import Request, urlopen
            req = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=OG_TIMEOUT) as resp:  # nosec - guarded by allowlist
                return resp.read().decode("utf-8", "ignore")
    except Exception:
        return None

def _head_is_image(url: str) -> bool:
    if not HEAD_PROBE:
        return False
    try:
        import requests  # type: ignore
        h = requests.head(url, headers={"User-Agent": USER_AGENT}, timeout=min(OG_TIMEOUT, 2.5), allow_redirects=True)
        ct = (h.headers.get("Content-Type") or "").lower()
        return ct.startswith("image/")
    except Exception:
        return False

def _maybe_fetch(url: str) -> Optional[str]:
    host = urlparse(url).netloc.lower().replace("www.", "")
    if OG_ALLOWED_DOMAINS and not any(host.endswith(d) for d in OG_ALLOWED_DOMAINS):
        return None
    return _fetch_text(url)

def _extract_base_href(s: str, fallback: str) -> str:
    m = re.search(r'<base[^>]+href=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        return to_https(m.group(1)) or fallback
    return fallback

def _choose_from_srcset(srcset: str) -> Optional[str]:
    """Choose largest width from srcset."""
    best, wbest = None, -1
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
        if w >= wbest:
            best, wbest = u, w
    return best

# Candidate with score -------------------------------------------------

def _numeric_size_hint(u: str) -> int:
    """
    Extract width/height hints embedded in URLs: 1200x630, -2048, _1080 etc.
    Return an approximate 'size' number to boost ranking.
    """
    size = 0
    m = re.search(r'(\d{3,5})[xX_ -](\d{3,5})', u)
    if m:
        try:
            a, b = int(m.group(1)), int(m.group(2))
            size = max(a, b)
        except Exception:
            pass
    else:
        m = re.search(r'[^0-9](\d{3,5})(?:p|w|h|)(?!\d)', u)
        if m:
            try:
                size = int(m.group(1))
            except Exception:
                pass
    return size

def _score_image_url(u: str, bias: int = 0) -> int:
    score = bias
    # prefer bigger
    score += _numeric_size_hint(u)
    # OG/hero cues
    if re.search(r"(og|open[-_]?graph|hero|share|feature|original|full)", u, re.I):
        score += 400
    # downscore tiny/thumb/amp placeholders
    if re.search(r"(sprite|icon|logo-|favicon|amp/)", u, re.I):
        score -= 200
    if re.search(r"(thumb|thumbnail|small|mini|tiny)", u, re.I):
        score -= 60
    return score

def choose_best_image(candidates: Iterable[str]) -> Optional[str]:
    best, s_best = None, -10**9
    for u in candidates:
        s = _score_image_url(u)
        if s > s_best:
            best, s_best = u, s
    return best

# ===================== HTML extraction (no fetch) =====================

def _images_from_html_block(html_str: Optional[str], base_url: str) -> List[Tuple[str, int]]:
    """Return [(normalized_url, score_bias), ...] from a snippet."""
    if not html_str:
        return []
    s = html.unescape(html_str)

    out: List[Tuple[str, int]] = []

    # <img src="...">
    for m in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 120))

    # lazy-load attributes (popular variants)
    for attr in ("data-src", "data-original", "data-lazy-src", "data-image", "data-srcset"):
        for m in re.finditer(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), 110))

    # srcset on <img>/<source>
    for m in re.finditer(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 160))

    # AMP <amp-img ...>
    for m in re.finditer(r'<amp-img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 150))
    for m in re.finditer(r'<amp-img[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 165))

    # <noscript> with <img>
    for m in re.finditer(r'<noscript[^>]*>(.*?)</noscript>', s, flags=re.I | re.S):
        sub = m.group(1)
        for m2 in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', sub, flags=re.I):
            out.append((m2.group(1), 130))

    # CSS background-image: url("...")
    for m in re.finditer(r'background-image\s*:\s*url\((["\']?)([^)]+?)\1\)', s, flags=re.I):
        out.append((m.group(2), 90))
    # data-background / data-bg
    for attr in ("data-background", "data-background-image", "data-bg", "data-bg-url"):
        for m in re.finditer(fr'(?:<\w+[^>]+{attr}=["\']([^"\']+)["\'])', s, flags=re.I):
            out.append((m.group(1), 90))

    # <meta> OpenGraph/Twitter/itemprop variants
    meta_pairs = [
        (r'property=["\']og:image["\']', 400),
        (r'property=["\']og:image:url["\']', 395),
        (r'property=["\']og:image:secure_url["\']', 395),
        (r'name=["\']twitter:image(?::src)?["\']', 380),
        (r'itemprop=["\']image["\']', 360),
    ]
    for sel, bias in meta_pairs:
        for m in re.finditer(rf'<meta[^>]+{sel}[^>]+content=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), bias))

    # <link rel="image_src" ...>, <link rel="preload" as="image" href="...">
    for m in re.finditer(r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 320))
    for m in re.finditer(r'<link[^>]+rel=["\']preload["\'][^>]+as=["\']image["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 300))

    # JSON-LD blocks: image / thumbnailUrl / contentUrl / primaryImageOfPage / associatedMedia / logo
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', s, flags=re.I | re.S):
        try:
            data = json.loads(m.group(1).strip())
        except Exception:
            continue
        objs = data if isinstance(data, list) else [data]
        for obj in objs:
            # nested helper
            def collect_from_ld(val: Any, bias: int) -> None:
                if isinstance(val, str):
                    out.append((val, bias))
                elif isinstance(val, dict):
                    if val.get("url"):
                        out.append((val["url"], bias))
                    if val.get("@type") == "ImageObject":
                        for k in ("url", "contentUrl", "thumbnail", "thumbnailUrl"):
                            if val.get(k):
                                out.append((val[k], bias))
                elif isinstance(val, list):
                    for it in val:
                        collect_from_ld(it, bias)

            for k, bias in (
                ("image", 360),
                ("thumbnailUrl", 350),
                ("contentUrl", 350),
                ("primaryImageOfPage", 370),
                ("associatedMedia", 340),
                ("logo", 200),
            ):
                v = obj.get(k)
                if v:
                    collect_from_ld(v, bias)

    # Normalize & filter
    results: List[Tuple[str, int]] = []
    seen = set()
    for raw, bias in out:
        u = _norm(raw, base_url)
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            if u not in seen:
                seen.add(u)
                results.append((u, bias))
    return results

# ===================== Feed entry extraction ==========================

def _enclosures_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    urls: List[Tuple[str, int]] = []
    for enc in entry.get("enclosures") or []:
        u = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
            urls.append((_norm(u, base_url) or u, 260))
    for l in entry.get("links") or []:
        if isinstance(l, dict) and l.get("rel") == "enclosure":
            u = l.get("href")
            typ = (l.get("type") or "").lower()
            if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
                urls.append((_norm(u, base_url) or u, 255))
    return [(u, b) for (u, b) in urls if u]

def _media_fields_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    urls: List[Tuple[str, int]] = []
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list):
        for t in thumbs:
            if isinstance(t, dict) and t.get("url"):
                urls.append((_norm(t["url"], base_url) or t["url"], 280))
    mcont = entry.get("media_content") or entry.get("media:content")
    if isinstance(mcont, list):
        for it in mcont:
            if not isinstance(it, dict):
                continue
            u = it.get("url") or it.get("href")
            typ = (it.get("type") or "").lower()
            if u and (typ.startswith("image/") or u.lower().split("?", 1)[0].endswith(IMG_EXTS)):
                urls.append((_norm(u, base_url) or u, 275))
    # simple custom fields
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str):
            urls.append((_norm(v, base_url) or v, 220))
        elif isinstance(v, dict) and v.get("href"):
            urls.append((_norm(v["href"], base_url) or v["href"], 220))
    return [(u, b) for (u, b) in urls if u]

def _collect_all_candidates(entry: Dict[str, Any], feed_url: str, link_url: str) -> List[Tuple[str, int]]:
    base = link_url or feed_url
    cand: List[Tuple[str, int]] = []

    # feed-level media/enclosure/custom fields
    cand += _media_fields_from_entry(entry, base)
    cand += _enclosures_from_entry(entry, base)

    # from HTML blocks in feed
    content_html = ""
    content = entry.get("content")
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            content_html = first.get("value") or ""

    summary_html = entry.get("summary_detail", {}).get("value") or entry.get("summary") or entry.get("description") or ""

    cand += _images_from_html_block(content_html, base)
    cand += _images_from_html_block(summary_html, base)

    # unique, keep best bias if duplicates
    best_bias: Dict[str, int] = {}
    for u, b in cand:
        if not u:
            continue
        if u not in best_bias or b > best_bias[u]:
            best_bias[u] = b
    return [(u, best_bias[u]) for u in best_bias.keys()]

# ===================== Optional page probing (OG/AMP) =================

def _extract_amp_link(s: str, base: str) -> Optional[str]:
    m = re.search(r'<link[^>]+rel=["\']amphtml["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        return _norm(m.group(1), base)
    return None

def _page_discover_images(page_html: str, page_url: str) -> List[Tuple[str, int]]:
    page_base = _extract_base_href(page_html, page_url)
    # Prefer OG/Twitter first (high bias), then everything else.
    cands = _images_from_html_block(page_html, page_base)
    return cands

def _maybe_probe_page_for_images(url: str) -> List[Tuple[str, int]]:
    html_text = _maybe_fetch(url)
    if not html_text:
        return []
    base = _extract_base_href(html_text, url)
    out = _page_discover_images(html_text, base)

    # Optionally probe AMP page
    if AMP_FETCH:
        amp = _extract_amp_link(html_text, base)
        if amp and amp != url:
            amp_html = _maybe_fetch(amp)
            if amp_html:
                out += _page_discover_images(amp_html, amp)

    return out

# ============================ Main entry =============================

def build_rss_payload(entry: Dict[str, Any], feed_url: str) -> Tuple[Dict[str, Any], Optional[str], List[str]]:
    """
    Build a comprehensive payload from a feed entry.
    Returns: (payload_dict, thumb_hint, image_candidates)
    """
    link = entry.get("link") or entry.get("id") or ""
    link = to_https(abs_url(link, feed_url)) or link

    # Collect from feed fields and HTML
    cands = _collect_all_candidates(entry, feed_url, link)

    # If none (or only very weak), probe article page(s)
    if OG_FETCH and (not cands or max((b for _, b in cands), default=0) < 300) and link:
        cands += _maybe_probe_page_for_images(link)

    # Normalize + unique + sort by score
    merged: Dict[str, int] = {}
    for u, b in cands:
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            merged[u] = max(merged.get(u, -10**9), b + _score_image_url(u))

    # Order by score
    ordered = sorted(merged.items(), key=lambda x: x[1], reverse=True)
    candidates = [u for u, _ in ordered]

    thumb_hint = candidates[0] if candidates else None

    # Build payload expected by normalizer (+ useful extras)
    # Prefer full content if present
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

    # gather inline imgs (first few) for transparency/debug
    inline_imgs = [u for u, _ in _images_from_html_block(content_html, link)[:3]]
    if not inline_imgs:
        inline_imgs = [u for u, _ in _images_from_html_block(description_html, link)[:3]]

    payload: Dict[str, Any] = {
        "url": link,
        "feed": feed_url,
        "content_html": content_html or "",
        "description_html": description_html or "",
        "summary": entry.get("summary") or "",
        "enclosures": entry.get("enclosures") or [],
        # extras (not required, but useful)
        "inline_images": inline_imgs or None,
        "image_candidates": candidates or None,
    }

    dlog("payload", {"url": link, "thumb_hint": thumb_hint, "top_candidates": candidates[:3]})
    return payload, thumb_hint, candidates
