# apps/workers/extractors.py
from __future__ import annotations

import html
import json
import os
import re
from typing import Iterable, Optional, Tuple, List, Dict, Any
from urllib.parse import urljoin, urlparse, urlunparse, urlencode, parse_qsl

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
    for d in os.getenv(
        "OG_ALLOWED_DOMAINS",
        # add common sites we ingest (inc. WordPress heavy ones)
        "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com,deadline.com,indiewire.com,slashfilm.com,"
        "tellyupdates.com,wordpress.com,wp.com,wordpress.org,wpengine.com,cloudfront.net,akamaized.net"
    ).split(",")
    if d.strip()
}
# Also try AMP page if present (link[rel=amphtml])
AMP_FETCH = os.getenv("AMP_FETCH", "1").lower() not in ("0", "", "false", "no")
# Optionally HEAD-probe non-extension URLs to ensure image/* (guarded)
HEAD_PROBE = os.getenv("HEAD_PROBE", "0").lower() not in ("0", "", "false", "no")

OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv("FETCH_UA", "Mozilla/5.0 (compatible; CinePulseBot/1.2; +https://example.com/bot)")

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".jfif", ".pjpeg")
IMG_HOSTS_FRIENDLY = {"i0.wp.com", "i1.wp.com", "images.ctfassets.net"}  # hotlink-friendly CDNs we can trust

# ============================== Helpers ==============================

def dlog(msg: str, *kv: Any) -> None:
    if EXTRACT_DEBUG:
        details = " | ".join(repr(k) for k in kv) if kv else ""
        print(f"[extract] {msg}{(' ' + details) if details else ''}")

def abs_url(url: Optional[str], base: str) -> Optional[str]:
    if not url:
        return None
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

def _strip_tracking_query(u: str) -> str:
    """Remove pure tracking params (utm_*, fbclid, gclid, itok) to dedupe, preserve format/width params."""
    p = urlparse(u)
    if not p.query:
        return u
    keep = []
    for k, v in parse_qsl(p.query, keep_blank_values=True):
        lk = k.lower()
        if lk.startswith("utm_") or lk in {"fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "itok"}:
            continue
        keep.append((k, v))
    new_q = urlencode(keep)
    return urlunparse((p.scheme, p.netloc, p.path, p.params, new_q, p.fragment))

def _norm(url: Optional[str], base: str) -> Optional[str]:
    u = to_https(abs_url(url, base))
    return _strip_tracking_query(u) if u else None

def _has_image_ext(path_or_url: str) -> bool:
    base = path_or_url.split("?", 1)[0].lower()
    return base.endswith(IMG_EXTS)

def _looks_image_like(url: str) -> bool:
    """
    Accept typical extensions OR obvious 'image' cues OR query-format hints even without extension.
    Also handle WordPress uploads and Cloudinary-like URLs.
    """
    l = url.lower()
    if _has_image_ext(l):
        return True

    # WordPress uploads often carry no extension at the very end due to query params or resized variants
    if "/wp-content/uploads/" in l:
        return True

    # Query string hints (format=webp|jpg|png, fm=jpg, output=webp)
    if re.search(r"([?&](?:format|fm|output)=(?:jpe?g|png|webp|avif))", l):
        return True

    # Generic cues
    if re.search(r"(og|open[-_]?graph|image|thumb|thumbnail|poster|photo|hero|share)", l):
        return True

    # Cloudinary /imgix/GraphCMS style transforms are fine
    if re.search(r"/(?:image|upload)/.*(?:/c_|/w_|/q_|/f_|/ar_|/g_)", l):
        return True

    return False

def _prefer_same_origin_score(u: str, page_url: str) -> int:
    """Small bias to images hosted on same registrable domain as the article."""
    try:
        host_img = urlparse(u).netloc.lower().removeprefix("www.")
        host_pg = urlparse(page_url).netloc.lower().removeprefix("www.")
        if host_img == host_pg:
            return 70
        if host_img in IMG_HOSTS_FRIENDLY:
            return 30
    except Exception:
        pass
    return 0

def _fetch_text(url: str) -> Optional[str]:
    try:
        try:
            import requests  # type: ignore
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if r.status_code >= 400:
                return None
            # a few sites send latin-1 incorrectly; ignore errors
            r.encoding = r.encoding or "utf-8"
            return r.text
        except Exception:
            from urllib.request import Request, urlopen
            req = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=OG_TIMEOUT) as resp:  # nosec
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
    # Extract width/height hints embedded in URLs: 1200x630, -2048, _1080 etc.
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

def _images_from_html_block(html_str: Optional[str], base_url: str, page_url: Optional[str] = None) -> List[Tuple[str, int]]:
    """Return [(normalized_url, score_bias), ...] from a snippet."""
    if not html_str:
        return []
    s = html.unescape(html_str)

    out: List[Tuple[str, int]] = []

    # <img src="...">
    for m in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 140))

    # lazy-load attributes (popular variants)
    for attr in ("data-src", "data-original", "data-lazy-src", "data-image", "data-orig-src", "data-lazyload"):
        for m in re.finditer(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), 135))

    # srcset on <img>/<source>
    for m in re.finditer(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 180))

    # <picture><source> type=image/... (already covered by srcset but keep)
    for m in re.finditer(r'<source[^>]+type=["\']image/[^"\']+["\'][^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 185))

    # AMP <amp-img ...>
    for m in re.finditer(r'<amp-img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 170))
    for m in re.finditer(r'<amp-img[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 190))

    # <noscript> with <img>
    for m in re.finditer(r'<noscript[^>]*>(.*?)</noscript>', s, flags=re.I | re.S):
        sub = m.group(1)
        for m2 in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', sub, flags=re.I):
            out.append((m2.group(1), 160))

    # CSS background-image: url("...") (cards, hero divs)
    for m in re.finditer(r'background-image\s*:\s*url\((["\']?)([^)]+?)\1\)', s, flags=re.I):
        out.append((m.group(2), 110))
    # data-background / data-bg
    for attr in ("data-background", "data-background-image", "data-bg", "data-bg-url"):
        for m in re.finditer(fr'(?:<\w+[^>]+{attr}=["\']([^"\']+)["\'])', s, flags=re.I):
            out.append((m.group(1), 110))

    # <a href="..."> directly to an image (e.g., TellyUpdates "Image:" link)
    for m in re.finditer(r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(?:\s*Image[:\s]|<img|[^<]{0,7})', s, flags=re.I):
        out.append((m.group(1), 200))
    # any <a href="*.jpg|*.webp|...">
    for m in re.finditer(r'<a[^>]+href=["\']([^"\']+\.(?:jpe?g|png|webp|gif|avif))["\']', s, flags=re.I):
        out.append((m.group(1), 195))

    # <meta> OpenGraph/Twitter/itemprop variants
    meta_pairs = [
        (r'property=["\']og:image["\']', 420),
        (r'property=["\']og:image:url["\']', 415),
        (r'property=["\']og:image:secure_url["\']', 415),
        (r'name=["\']twitter:image(?::src)?["\']', 395),
        (r'itemprop=["\']image["\']', 370),
        (r'name=["\']parsely-image-url["\']', 360),
    ]
    for sel, bias in meta_pairs:
        for m in re.finditer(rf'<meta[^>]+{sel}[^>]+content=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), bias))

    # <link rel="image_src" ...>, <link rel="preload" as="image" href="...">
    for m in re.finditer(r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 330))
    for m in re.finditer(r'<link[^>]+rel=["\']preload["\'][^>]+as=["\']image["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 310))

    # JSON-LD blocks: image / thumbnailUrl / contentUrl / primaryImageOfPage / associatedMedia / logo
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', s, flags=re.I | re.S):
        raw = m.group(1).strip()
        # some sites (Yoast/RankMath) embed multiple JSON-LD objects, possibly invalid; try best-effort
        try:
            data = json.loads(raw)
        except Exception:
            # try to unescape & fix common trailing commas
            try:
                data = json.loads(raw.replace("\n", " ").replace(", }", " }"))
            except Exception:
                continue
        objs = data if isinstance(data, list) else [data]
        for obj in objs:
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
                ("image", 380),
                ("thumbnailUrl", 360),
                ("contentUrl", 360),
                ("primaryImageOfPage", 400),
                ("associatedMedia", 345),
                ("logo", 210),
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
                # prefer same-origin slightly to avoid hotlink blocks
                if page_url:
                    bias += _prefer_same_origin_score(u, page_url)
                results.append((u, bias))
    return results

# ===================== Feed entry extraction ==========================

def _enclosures_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    urls: List[Tuple[str, int]] = []
    for enc in entry.get("enclosures") or []:
        u = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if u and (typ.startswith("image/") or _has_image_ext(u)):
            urls.append((_norm(u, base_url) or u, 265))
    for l in entry.get("links") or []:
        if isinstance(l, dict) and l.get("rel") == "enclosure":
            u = l.get("href")
            typ = (l.get("type") or "").lower()
            if u and (typ.startswith("image/") or _has_image_ext(u)):
                urls.append((_norm(u, base_url) or u, 260))
    return [(u, b) for (u, b) in urls if u]

def _media_fields_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    urls: List[Tuple[str, int]] = []
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list):
        for t in thumbs:
            if isinstance(t, dict) and t.get("url"):
                urls.append((_norm(t["url"], base_url) or t["url"], 285))
    mcont = entry.get("media_content") or entry.get("media:content")
    if isinstance(mcont, list):
        for it in mcont:
            if not isinstance(it, dict):
                continue
            u = it.get("url") or it.get("href")
            typ = (it.get("type") or "").lower()
            if u and (typ.startswith("image/") or _has_image_ext(u)):
                urls.append((_norm(u, base_url) or u, 280))
    # simple custom fields
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str):
            urls.append((_norm(v, base_url) or v, 230))
        elif isinstance(v, dict) and v.get("href"):
            urls.append((_norm(v["href"], base_url) or v["href"], 230))
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

    cand += _images_from_html_block(content_html, base, page_url=link_url or base)
    cand += _images_from_html_block(summary_html, base, page_url=link_url or base)

    # unique, keep best bias if duplicates
    best_bias: Dict[str, int] = {}
    for u, b in cand:
        if not u:
            continue
        if u not in best_bias or b > best_bias[u]:
            best_bias[u] = b
    return [(u, best_bias[u]) for u in best_bias.keys()]

# ===================== Optional page probing (OG/AMP + shims) =========

def _extract_amp_link(s: str, base: str) -> Optional[str]:
    m = re.search(r'<link[^>]+rel=["\']amphtml["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        return _norm(m.group(1), base)
    return None

def _page_discover_images(page_html: str, page_url: str) -> List[Tuple[str, int]]:
    page_base = _extract_base_href(page_html, page_url)
    cands = _images_from_html_block(page_html, page_base, page_url=page_url)

    # ---- site shims (very light-touch) ----
    host = urlparse(page_url).netloc.lower().removeprefix("www.")

    # WordPress family (including Koimoi): prefer og:image first, then first gallery/featured image
    if host.endswith(("koimoi.com", "tellyupdates.com")) or "wp-content" in page_html:
        # already captured by meta OG; bump any uploads hero by a small bias
        bumped: List[Tuple[str, int]] = []
        for u, b in cands:
            if "/wp-content/uploads/" in u:
                bumped.append((u, b + 40))
            else:
                bumped.append((u, b))
        cands = bumped

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
    top_bias = max((b for _, b in cands), default=0)
    if OG_FETCH and (not cands or top_bias < 320) and link:
        cands += _maybe_probe_page_for_images(link)

    # Normalize + unique + sort by score (+host preference)
    merged: Dict[str, int] = {}
    for u, b in cands:
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            bonus = _prefer_same_origin_score(u, link) if link else 0
            merged[u] = max(merged.get(u, -10**9), b + bonus + _score_image_url(u))

    ordered = sorted(merged.items(), key=lambda x: x[1], reverse=True)
    candidates = [u for u, _ in ordered]

    thumb_hint = candidates[0] if candidates else None

    # Build payload expected by normalizer (+ useful extras)
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
    inline_imgs = [u for u, _ in _images_from_html_block(content_html, link, page_url=link)[:3]]
    if not inline_imgs:
        inline_imgs = [u for u, _ in _images_from_html_block(description_html, link, page_url=link)[:3]]

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
