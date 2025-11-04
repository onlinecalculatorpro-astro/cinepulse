from __future__ import annotations
"""
Extractor layer
---------------
Pulls structured fields from a feed entry and aggressively discovers a good
hero/thumbnail image. This file **does not** classify verticals/tags; that
happens later in normalize_event().

Public API:
    build_rss_payload(entry, feed_url)
        -> (payload: dict, thumb_hint: Optional[str], candidates: List[str])
    choose_best_image(candidates)
    abs_url(), to_https()
"""

import calendar
import html
import json
import os
import re
from typing import Iterable, Optional, Tuple, List, Dict, Any
from urllib.parse import (
    urljoin, urlparse, urlunparse, urlencode, parse_qsl
)

__all__ = [
    "build_rss_payload",
    "choose_best_image",
    "abs_url",
    "to_https",
]

# ============================== Config ===============================

EXTRACT_DEBUG = os.getenv("EXTRACT_DEBUG", "0").lower() not in ("0", "", "false", "no")

# Optional network fetch to page for richer discovery (og:image, JSON-LD, AMP)
OG_FETCH = os.getenv("OG_FETCH", "1").lower() not in ("0", "", "false", "no")

# Keep page-fetching restricted to common publishers/CDNs we ingest.
OG_ALLOWED_DOMAINS = {
    d.strip().lower()
    for d in os.getenv(
        "OG_ALLOWED_DOMAINS",
        (
            "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com,"
            "deadline.com,indiewire.com,slashfilm.com,vulture.com,"
            "tellyupdates.com,wordpress.com,wp.com,wordpress.org,wpengine.com,"
            "cloudfront.net,akamaized.net,images.ctfassets.net"
        ),
    ).split(",")
    if d.strip()
}

# Also try AMP page if present
AMP_FETCH = os.getenv("AMP_FETCH", "1").lower() not in ("0", "", "false", "no")

# Optionally HEAD-probe URLs without obvious extensions to verify image/*
HEAD_PROBE = os.getenv("HEAD_PROBE", "0").lower() not in ("0", "", "false", "no")

OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv("FETCH_UA", "Mozilla/5.0 (compatible; CinePulseBot/1.3; +https://example.com/bot)")

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".jfif", ".pjpeg")
IMG_HOSTS_FRIENDLY = {"i0.wp.com", "i1.wp.com", "i2.wp.com", "images.ctfassets.net"}

# Things we never want to keep (demo images, placeholders, etc.)
BAD_IMAGE_HOSTS = {
    "demo.tagdiv.com",
}
BAD_IMAGE_PATTERNS = re.compile(
    r"(?:sprite|favicon|logo[-_]?|watermark|default[-_]?og|default[-_]?share|"
    r"social[-_]?share|generic[-_]?share|breaking[-_]?news[-_]?card)",
    re.I,
)

# ============================== Debug helper =========================

def dlog(msg: str, *kv: Any) -> None:
    if EXTRACT_DEBUG:
        details = " | ".join(repr(k) for k in kv) if kv else ""
        print(f"[extract] {msg}{(' ' + details) if details else ''}")

# ============================== URL helpers ==========================

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
    """
    Remove pure tracking params (utm_*, fbclid, gclid, itok...), keep width/format params.
    """
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

def _unwrap_if_wpcom_proxy(u: str) -> str:
    """
    WordPress CDN often uses i*.wp.com/<origin>/<path>?resize=...
    Keep as-is (hotlink friendly), but also catch cases where the inner origin
    is obviously a banned host (e.g., demo.tagdiv.com in the path) and drop.
    """
    p = urlparse(u)
    host = p.netloc.lower()
    if host not in {"i0.wp.com", "i1.wp.com", "i2.wp.com", "s0.wp.com", "s1.wp.com", "s2.wp.com"}:
        return u
    # Path looks like /www.koimoi.com/wp-content/...  — just return unchanged.
    if any(bad in p.path.lower() for bad in ("demo.tagdiv.com", "/newspaper/")):
        return ""
    return u

def _norm(url: Optional[str], base: str) -> Optional[str]:
    u = to_https(abs_url(url, base))
    if not u:
        return None
    u = _strip_tracking_query(u)
    u = _unwrap_if_wpcom_proxy(u)
    if not u:
        return None
    # last guardrails
    try:
        ph = urlparse(u)
        host = (ph.netloc or "").lower().removeprefix("www.")
        if host in BAD_IMAGE_HOSTS:
            return None
    except Exception:
        pass
    return u

# ============================== Image heuristics =====================

def _has_image_ext(path_or_url: str) -> bool:
    base = path_or_url.split("?", 1)[0].lower()
    return base.endswith(IMG_EXTS)

def _looks_image_like(url: str) -> bool:
    """
    Accept typical extensions OR obvious 'image' cues OR query-format hints
    even without extension. Covers WordPress uploads and Cloudinary/imgix transforms.
    """
    l = url.lower()
    if _has_image_ext(l):
        return True

    # WordPress uploads/galleries often have no final extension on resized variants
    if "/wp-content/" in l:
        return True
    if "/uploads/" in l or "/new-galleries/" in l or "/gallery/" in l or "/media/" in l:
        return True

    # Query-string hints (format=webp|jpg|png, fm=jpg, output=webp)
    if re.search(r"([?&](?:format|fm|output)=(?:jpe?g|png|webp|avif))", l):
        return True

    # Generic OG/hero/thumb cues
    if re.search(r"(og|open[-_]?graph|image|thumb|thumbnail|poster|photo|hero|share)", l):
        return True

    # Cloudinary / imgix / etc
    if re.search(r"/(?:image|upload)/.*(?:/c_|/w_|/q_|/f_|/ar_|/g_)", l):
        return True

    return False

def _prefer_same_origin_score(u: str, page_url: str) -> int:
    """Small bias for same-origin or friendly CDN."""
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
    """Fetch HTML for OG/AMP scraping with short timeout, no retries."""
    try:
        try:
            import requests  # type: ignore
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if r.status_code >= 400:
                return None
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
        h = requests.head(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=min(OG_TIMEOUT, 2.5),
            allow_redirects=True,
        )
        ct = (h.headers.get("Content-Type") or "").lower()
        return ct.startswith("image/")
    except Exception:
        return False

def _maybe_fetch(url: str) -> Optional[str]:
    """Fetch page HTML only if domain matches our allowlist."""
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
    """Choose largest width from srcset attribute."""
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

# ===================== Scoring =====================

def _numeric_size_hint(u: str) -> int:
    """Guess resolution from patterns like 1200x630, -2048, _1080 etc."""
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
    """
    Assign a score to an image URL:
    - big hero images / og:image get a heavy bonus
    - tiny thumbs / icons get penalized
    """
    score = bias + _numeric_size_hint(u)

    # Hero cues
    if re.search(r"(og|open[-_]?graph|hero|share|feature|original|full)", u, re.I):
        score += 400

    # Downscore tiny/thumb/favicons
    if re.search(r"(sprite|icon|logo-|favicon|amp/)", u, re.I):
        score -= 200
    if re.search(r"(thumb|thumbnail|small|mini|tiny)", u, re.I):
        score -= 60

    # Hard penalty for obvious “brand cards” / placeholders
    if BAD_IMAGE_PATTERNS.search(u):
        score -= 1000

    return score

def choose_best_image(candidates: Iterable[str]) -> Optional[str]:
    best, s_best = None, -10**9
    for u in candidates:
        s = _score_image_url(u)
        if s > s_best:
            best, s_best = u, s
    return best

# ===================== HTML scraping helpers =========================

def _images_from_html_block(
    html_str: Optional[str],
    base_url: str,
    page_url: Optional[str] = None
) -> List[Tuple[str, int]]:
    """
    Return [(normalized_url, score_bias), ...] from HTML:
    <img>, lazy-load attrs, srcset, background-image, OG/Twitter meta, JSON-LD, etc.
    """
    if not html_str:
        return []
    s = html.unescape(html_str)

    out: List[Tuple[str, int]] = []

    # <img src="...">
    for m in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 140))

    # common lazy-load attributes
    for attr in (
        "data-src", "data-original", "data-lazy-src", "data-image",
        "data-orig-src", "data-lazyload", "data-srcset",
    ):
        for m in re.finditer(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), 135))

    # srcset on <img>/<source>
    for m in re.finditer(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 180))

    # <picture><source type=image/... srcset="...">
    for m in re.finditer(
        r'<source[^>]+type=["\']image/[^"\']+["\'][^>]+srcset=["\']([^"\']+)["\']',
        s, flags=re.I
    ):
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

    # <noscript><img ...></noscript>
    for m in re.finditer(r'<noscript[^>]*>(.*?)</noscript>', s, flags=re.I | re.S):
        sub = m.group(1)
        for m2 in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', sub, flags=re.I):
            out.append((m2.group(1), 160))

    # CSS background-image: url("...")
    for m in re.finditer(r'background-image\s*:\s*url\((["\']?)([^)]+?)\1\)', s, flags=re.I):
        out.append((m.group(2), 110))

    # data-background / data-bg
    for attr in ("data-background", "data-background-image", "data-bg", "data-bg-url"):
        for m in re.finditer(fr'(?:<\w+[^>]+{attr}=["\']([^"\']+)["\'])', s, flags=re.I):
            out.append((m.group(1), 110))

    # <a href="*.jpg|*.webp|..."> (some blogs wrap the hero inside a link)
    for m in re.finditer(r'<a[^>]+href=["\']([^"\']+\.(?:jpe?g|png|webp|gif|avif))["\']', s, flags=re.I):
        out.append((m.group(1), 195))
    for m in re.finditer(
        r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(?:\s*Image[:\s]|<img|[^<]{0,7})',
        s, flags=re.I
    ):
        out.append((m.group(1), 200))

    # <meta> OpenGraph / Twitter / itemprop variants
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

    # <link rel="image_src">, <link rel="preload" as="image" href="...">
    for m in re.finditer(r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']', s, flags=re.I):
        out.append((m.group(1), 330))
    for m in re.finditer(
        r'<link[^>]+rel=["\']preload["\'][^>]+as=["\']image["\'][^>]+href=["\']([^"\']+)["\']',
        s, flags=re.I
    ):
        out.append((m.group(1), 310))

    # JSON-LD blocks: image / thumbnailUrl / contentUrl / ...
    for m in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', s, flags=re.I | re.S):
        raw = m.group(1).strip()
        try:
            data = json.loads(raw)
        except Exception:
            try:
                data = json.loads(raw.replace("\n", " ").replace(", }", " }"))
            except Exception:
                data = None
        if not data:
            continue
        objs = data if isinstance(data, list) else [data]

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
            v = objs[0].get(k) if objs and isinstance(objs[0], dict) else None
            if v:
                collect_from_ld(v, bias)

    # Normalize, filter to "imagey" URLs, add origin preference bias
    results: List[Tuple[str, int]] = []
    seen = set()
    for raw, bias in out:
        u = _norm(raw, base_url)
        if not u:
            continue
        if not (_looks_image_like(u) or _head_is_image(u)):
            continue
        if u in seen:
            continue
        seen.add(u)
        # prefer same-origin a bit
        if page_url:
            bias += _prefer_same_origin_score(u, page_url)
        results.append((u, bias))

    return results

# ===================== Feed entry extraction =========================

def _enclosures_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    urls: List[Tuple[str, int]] = []
    for enc in entry.get("enclosures") or []:
        u = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if u and (typ.startswith("image/") or _has_image_ext(u)):
            urls.append((_norm(u, base_url) or u, 265))
    for lnk in entry.get("links") or []:
        if isinstance(lnk, dict) and lnk.get("rel") == "enclosure":
            u = lnk.get("href")
            typ = (lnk.get("type") or "").lower()
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
    cand += _media_fields_from_entry(entry, base)
    cand += _enclosures_from_entry(entry, base)

    # HTML blocks in feed
    content_html = ""
    content = entry.get("content")
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            content_html = first.get("value") or ""

    summary_html = (
        entry.get("summary_detail", {}).get("value")
        or entry.get("summary")
        or entry.get("description")
        or ""
    )

    cand += _images_from_html_block(content_html, base, page_url=link_url or base)
    cand += _images_from_html_block(summary_html, base, page_url=link_url or base)

    # unique, keep best bias if duplicate URL appears multiple times
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
    """
    Pull og:image / hero images, then apply light site-specific bumps.
    WordPress/Koimoi: prefer featured/article images from /wp-content/… over social cards.
    """
    page_base = _extract_base_href(page_html, page_url)
    cands = _images_from_html_block(page_html, page_base, page_url=page_url)

    host = urlparse(page_url).netloc.lower().removeprefix("www.")

    # WordPress-heavy (Koimoi etc.) — nudge uploads higher
    if host.endswith(("koimoi.com", "tellyupdates.com")) or "wp-content" in page_html:
        bumped: List[Tuple[str, int]] = []
        for u, b in cands:
            if "/wp-content/" in u or "/uploads/" in u or "/new-galleries/" in u:
                bumped.append((u, b + 60))
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

    if AMP_FETCH:
        amp = _extract_amp_link(html_text, base)
        if amp and amp != url:
            amp_html = _maybe_fetch(amp)
            if amp_html:
                out += _page_discover_images(amp_html, amp)

    return out

# ===================== Utility for text fields =======================

def _strip_html(text: str) -> str:
    if not text:
        return ""
    no_tags = re.sub(r"<[^>]+>", " ", text)
    no_tags = html.unescape(no_tags)
    return re.sub(r"\s+", " ", no_tags).strip()

def _entry_epoch(entry: Dict[str, Any]) -> Optional[int]:
    for k in ("published_parsed", "updated_parsed"):
        st = entry.get(k)
        if st and hasattr(st, "tm_year"):
            try:
                return int(calendar.timegm(st))
            except Exception:
                pass
    return None

# ============================ Main entry =============================

def build_rss_payload(entry: Dict[str, Any], feed_url: str) -> Tuple[Dict[str, Any], Optional[str], List[str]]:
    """
    Build payload from a feed entry.
    Returns:
      payload_dict, thumb_hint (best guess), candidates (best-first)
    """
    # Canonical link
    link = entry.get("link") or entry.get("id") or ""
    link = to_https(abs_url(link, feed_url)) or link

    # ----------------- Image candidates -----------------
    cands = _collect_all_candidates(entry, feed_url, link)

    # If none (or only weak), probe article page(s) (og:image / JSON-LD / AMP)
    top_bias = max((b for _, b in cands), default=0)
    if OG_FETCH and (not cands or top_bias < 320) and link:
        cands += _maybe_probe_page_for_images(link)

    # Merge/score/normalize/dedupe → final ordered candidates
    merged: Dict[str, int] = {}
    for u, b in cands:
        if not u:
            continue
        if not (_looks_image_like(u) or _head_is_image(u)):
            continue
        bonus = _prefer_same_origin_score(u, link) if link else 0
        merged[u] = max(merged.get(u, -10**9), b + bonus + _score_image_url(u))

    ordered = sorted(merged.items(), key=lambda x: x[1], reverse=True)
    candidates = [u for u, _ in ordered]
    thumb_hint = candidates[0] if candidates else None

    # ----------------- Text / HTML fields -----------------
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

    raw_summary_text = entry.get("summary") or entry.get("title") or description_html
    summary_text = _strip_html(raw_summary_text or "")

    inline_imgs = [u for u, _ in _images_from_html_block(content_html, link, page_url=link)[:3]]
    if not inline_imgs:
        inline_imgs = [u for u, _ in _images_from_html_block(description_html, link, page_url=link)[:3]]

    # ----------------- Timestamp & title -----------------
    published_ts = _entry_epoch(entry)
    title = _strip_html(entry.get("title") or "")

    # ----------------- Build payload -----------------
    payload: Dict[str, Any] = {
        "url": link,
        "feed": feed_url,
        "title": title,
        "summary": summary_text,
        "content_html": content_html or "",
        "description_html": description_html or "",
        "published_ts": published_ts,
        "enclosures": entry.get("enclosures") or [],
        "inline_images": inline_imgs or None,
        "image_candidates": candidates or None,
    }

    dlog("payload", {"url": link, "published_ts": published_ts, "thumb_hint": thumb_hint, "top_candidates": candidates[:3]})
    return payload, thumb_hint, candidates
