# apps/workers/extractors.py
from __future__ import annotations

"""
Extractor layer
---------------
This file is responsible for:
- pulling structured data out of one feed entry (RSS / Atom / YouTube etc.)
- aggressively discovering a good hero/thumbnail image
It does NOT:
- classify verticals (entertainment/sports/etc.)
- generate tags/kind_meta
Those happen later in normalize_event() inside jobs.py.

Public API:
    build_rss_payload(entry, feed_url) -> (payload: dict, thumb_hint: Optional[str], candidates: List[str])
    choose_best_image(candidates)
    abs_url(), to_https()

The 'payload' we return is what normalize_event() will consume.
"""

import calendar
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

# Optional network fetch to page for richer discovery (og:image, etc.)
OG_FETCH = os.getenv("OG_FETCH", "1").lower() not in ("0", "", "false", "no")

# Allow-list of domains we are OK probing (comma-separated, suffix match).
# This keeps us from hammering random sites.
OG_ALLOWED_DOMAINS = {
    d.strip().lower()
    for d in os.getenv(
        "OG_ALLOWED_DOMAINS",
        # add common sites we ingest (heavy WordPress/CDN setups etc.)
        "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com,deadline.com,indiewire.com,slashfilm.com,"
        "tellyupdates.com,wordpress.com,wp.com,wordpress.org,wpengine.com,cloudfront.net,akamaized.net"
    ).split(",")
    if d.strip()
}

# Also try AMP page if present (<link rel="amphtml">)
AMP_FETCH = os.getenv("AMP_FETCH", "1").lower() not in ("0", "", "false", "no")

# Optionally HEAD-probe URLs with no extension to verify Content-Type: image/*
HEAD_PROBE = os.getenv("HEAD_PROBE", "0").lower() not in ("0", "", "false", "no")

OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv("FETCH_UA", "Mozilla/5.0 (compatible; CinePulseBot/1.2; +https://example.com/bot)")

IMG_EXTS = (".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".jfif", ".pjpeg")
IMG_HOSTS_FRIENDLY = {
    "i0.wp.com",
    "i1.wp.com",
    "images.ctfassets.net",
}  # hotlink-friendly CDNs we usually trust

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
    Remove pure tracking params (utm_*, fbclid, gclid, itok...) so that
    duplicates normalize and cache keys stay stable.
    Preserve format/width params (w=1080 etc.) because they affect image size.
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

def _norm(url: Optional[str], base: str) -> Optional[str]:
    u = to_https(abs_url(url, base))
    return _strip_tracking_query(u) if u else None

# ============================== Image heuristics =====================

def _has_image_ext(path_or_url: str) -> bool:
    base = path_or_url.split("?", 1)[0].lower()
    return base.endswith(IMG_EXTS)

def _looks_image_like(url: str) -> bool:
    """
    Accept typical extensions OR obvious 'image' cues OR query-format hints
    even without extension.
    Handles WordPress uploads and Cloudinary/imgix-like transforms.
    """
    l = url.lower()
    if _has_image_ext(l):
        return True

    # WordPress uploads often carry no final extension (resized variants etc.)
    if "/wp-content/uploads/" in l:
        return True

    # Query-string hints (format=webp|jpg|png, fm=jpg, output=webp)
    if re.search(r"([?&](?:format|fm|output)=(?:jpe?g|png|webp|avif))", l):
        return True

    # Generic OG/hero/thumb cues
    if re.search(r"(og|open[-_]?graph|image|thumb|thumbnail|poster|photo|hero|share)", l):
        return True

    # Cloudinary /imgix/GraphCMS-ish transforms
    if re.search(r"/(?:image|upload)/.*(?:/c_|/w_|/q_|/f_|/ar_|/g_)", l):
        return True

    return False

def _prefer_same_origin_score(u: str, page_url: str) -> int:
    """
    Small bias to images hosted on same registrable domain as the article
    (less likely to 403 hotlink).
    """
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
    """
    Fetch full HTML for OG/AMP scraping. We'll use requests if available,
    else fallback to urllib. Intentionally short timeout, no retries.
    """
    try:
        try:
            import requests  # type: ignore
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if r.status_code >= 400:
                return None
            # some sites send latin-1/etc. incorrectly; ignore errors
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
    """
    Use a HEAD request (optional) to verify that something without an obvious
    extension is actually image/*.
    """
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
    """
    Fetch page HTML only if domain matches our allowlist,
    so we don't DDoS or get IP banned.
    """
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
    """
    Choose largest width from srcset attribute.
    srcset examples like: "img_200.jpg 200w, img_1200.jpg 1200w"
    """
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
    """
    Guess resolution from patterns like 1200x630, -2048, _1080 etc.
    Higher number = higher score.
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
    """
    Assign a score to an image URL:
    - big hero images / og:image get a heavy bonus
    - tiny thumbs / icons get penalized
    """
    score = bias
    score += _numeric_size_hint(u)

    # OG/hero cues
    if re.search(r"(og|open[-_]?graph|hero|share|feature|original|full)", u, re.I):
        score += 400

    # downscore tiny/thumb/favicons
    if re.search(r"(sprite|icon|logo-|favicon|amp/)", u, re.I):
        score -= 200
    if re.search(r"(thumb|thumbnail|small|mini|tiny)", u, re.I):
        score -= 60

    return score

def choose_best_image(candidates: Iterable[str]) -> Optional[str]:
    """
    Given a list of candidate URLs (already normalized), pick the best one
    purely by score. This is a convenience helper for consumers that don't
    want to run the full bias/scoring pipeline.
    """
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
    Return [(normalized_url, score_bias), ...] from a snippet of HTML.
    We look at <img>, lazy-load attrs, srcset, background-image, OG meta, etc.
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
        "data-src",
        "data-original",
        "data-lazy-src",
        "data-image",
        "data-orig-src",
        "data-lazyload",
    ):
        for m in re.finditer(fr'<img[^>]+{attr}=["\']([^"\']+)["\']', s, flags=re.I):
            out.append((m.group(1), 135))

    # srcset on <img>/<source>
    for m in re.finditer(r'(?:<img|<source)[^>]+srcset=["\']([^"\']+)["\']', s, flags=re.I):
        pick = _choose_from_srcset(m.group(1))
        if pick:
            out.append((pick, 180))

    # <picture><source> type=image/... (just in case)
    for m in re.finditer(
        r'<source[^>]+type=["\']image/[^"\']+["\'][^>]+srcset=["\']([^"\']+)["\']',
        s,
        flags=re.I
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

    # <noscript> with <img>
    for m in re.finditer(r'<noscript[^>]*>(.*?)</noscript>', s, flags=re.I | re.S):
        sub = m.group(1)
        for m2 in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', sub, flags=re.I):
            out.append((m2.group(1), 160))

    # CSS background-image: url("...")
    for m in re.finditer(r'background-image\s*:\s*url\((["\']?)([^)]+?)\1\)', s, flags=re.I):
        out.append((m.group(2), 110))

    # data-background / data-bg
    for attr in (
        "data-background",
        "data-background-image",
        "data-bg",
        "data-bg-url",
    ):
        for m in re.finditer(fr'(?:<\w+[^>]+{attr}=["\']([^"\']+)["\'])', s, flags=re.I):
            out.append((m.group(1), 110))

    # <a href="..."> that directly points to an image (some blogs do this)
    for m in re.finditer(
        r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(?:\s*Image[:\s]|<img|[^<]{0,7})',
        s,
        flags=re.I
    ):
        out.append((m.group(1), 200))

    # any <a href="*.jpg|*.webp|...">
    for m in re.finditer(
        r'<a[^>]+href=["\']([^"\']+\.(?:jpe?g|png|webp|gif|avif))["\']',
        s,
        flags=re.I
    ):
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
        for m in re.finditer(
            rf'<meta[^>]+{sel}[^>]+content=["\']([^"\']+)["\']',
            s,
            flags=re.I
        ):
            out.append((m.group(1), bias))

    # <link rel="image_src" ...>, <link rel="preload" as="image" href="...">
    for m in re.finditer(
        r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I
    ):
        out.append((m.group(1), 330))
    for m in re.finditer(
        r'<link[^>]+rel=["\']preload["\'][^>]+as=["\']image["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I
    ):
        out.append((m.group(1), 310))

    # JSON-LD blocks: image / thumbnailUrl / contentUrl / ...
    for m in re.finditer(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        s,
        flags=re.I | re.S
    ):
        raw = m.group(1).strip()
        # many sites emit chained/invalid JSON-LD, so be forgiving
        try:
            data = json.loads(raw)
        except Exception:
            try:
                data = json.loads(raw.replace("\n", " ").replace(", }", " }"))
            except Exception:
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
            v = objs[0].get(k) if objs else None
            if v:
                collect_from_ld(v, bias)

    # Normalize, filter to "imagey" URLs, and score origin preference
    results: List[Tuple[str, int]] = []
    seen = set()
    for raw, bias in out:
        u = _norm(raw, base_url)
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            if u not in seen:
                seen.add(u)
                # prefer same-origin => bump a little
                if page_url:
                    bias += _prefer_same_origin_score(u, page_url)
                results.append((u, bias))

    return results

# ===================== Feed entry extraction =========================

def _enclosures_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    """
    Pick images from <enclosure> / entry.enclosures / entry.links[rel=enclosure].
    """
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
    """
    Pick up media_thumbnail / media_content / custom fields like 'image', 'poster', etc.
    """
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

    # simple custom fields occasionally present in feeds
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str):
            urls.append((_norm(v, base_url) or v, 230))
        elif isinstance(v, dict) and v.get("href"):
            urls.append((_norm(v["href"], base_url) or v["href"], 230))

    return [(u, b) for (u, b) in urls if u]

def _collect_all_candidates(entry: Dict[str, Any], feed_url: str, link_url: str) -> List[Tuple[str, int]]:
    """
    Aggregate candidate image URLs from:
    - feed-level media/enclosures
    - HTML content blocks in the feed
    """
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
    m = re.search(
        r'<link[^>]+rel=["\']amphtml["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I
    )
    if m:
        return _norm(m.group(1), base)
    return None

def _page_discover_images(page_html: str, page_url: str) -> List[Tuple[str, int]]:
    """
    Pull og:image / hero images, then apply light site-specific bumps.
    For example, WordPress/Koimoi-style featured images should float up.
    """
    page_base = _extract_base_href(page_html, page_url)
    cands = _images_from_html_block(page_html, page_base, page_url=page_url)

    # ---- site shims (very light-touch, extendable) ----
    host = urlparse(page_url).netloc.lower().removeprefix("www.")

    # WordPress-heavy sites (Koimoi, etc.):
    # Prefer og:image and featured upload images as main hero.
    if host.endswith(("koimoi.com", "tellyupdates.com")) or "wp-content" in page_html:
        bumped: List[Tuple[str, int]] = []
        for u, b in cands:
            if "/wp-content/uploads/" in u:
                bumped.append((u, b + 40))
            else:
                bumped.append((u, b))
        cands = bumped

    return cands

def _maybe_probe_page_for_images(url: str) -> List[Tuple[str, int]]:
    """
    Fetch main article URL (and possibly AMP fallback) to mine OG/Twitter/JSON-LD
    hero image. This helps when feeds don't expose thumbnails.
    """
    html_text = _maybe_fetch(url)
    if not html_text:
        return []
    base = _extract_base_href(html_text, url)
    out = _page_discover_images(html_text, base)

    # Optionally probe AMP page for better og:image
    if AMP_FETCH:
        amp = _extract_amp_link(html_text, base)
        if amp and amp != url:
            amp_html = _maybe_fetch(amp)
            if amp_html:
                out += _page_discover_images(amp_html, amp)

    return out

# ===================== Utility for text fields =======================

def _strip_html(text: str) -> str:
    """
    Collapse simple HTML to plain text-ish for summary/snippet.
    We're not doing full sanitization here (that's later / frontend),
    just removing tags/entities for classification / display fallback.
    """
    if not text:
        return ""
    # kill tags
    no_tags = re.sub(r"<[^>]+>", " ", text)
    # unescape entities
    no_tags = html.unescape(no_tags)
    # collapse whitespace
    no_tags = re.sub(r"\s+", " ", no_tags).strip()
    return no_tags

def _entry_epoch(entry: Dict[str, Any]) -> Optional[int]:
    """
    Try to convert feedparser's published_parsed / updated_parsed into epoch seconds (UTC).
    """
    for k in ("published_parsed", "updated_parsed"):
        st = entry.get(k)
        # feedparser gives time.struct_time or None
        if st and hasattr(st, "tm_year"):
            try:
                return int(calendar.timegm(st))
            except Exception:
                pass
    return None

# ============================ Main entry =============================

def build_rss_payload(entry: Dict[str, Any], feed_url: str) -> Tuple[Dict[str, Any], Optional[str], List[str]]:
    """
    Build a comprehensive payload from a feed entry.

    Returns:
        payload_dict: dict with content we will hand to normalize_event()
        thumb_hint:   best guess hero image URL (or None)
        candidates:   list of all viable image URLs (sorted best-first)

    normalize_event() will then:
      - pick a final thumbnail
      - build tags/kind_meta
      - classify verticals
      - push to Redis
    """
    # Canonical link for the story
    link = entry.get("link") or entry.get("id") or ""
    link = to_https(abs_url(link, feed_url)) or link

    # ----------------- Image candidates -----------------
    cands = _collect_all_candidates(entry, feed_url, link)

    # If none (or only weak), probe article page(s) (og:image / JSON-LD)
    top_bias = max((b for _, b in cands), default=0)
    if OG_FETCH and (not cands or top_bias < 320) and link:
        cands += _maybe_probe_page_for_images(link)

    # Merge/score/normalize/dedupe -> final ordered candidates
    merged: Dict[str, int] = {}
    for u, b in cands:
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            bonus = _prefer_same_origin_score(u, link) if link else 0
            merged[u] = max(
                merged.get(u, -10**9),
                b + bonus + _score_image_url(u)
            )

    ordered = sorted(merged.items(), key=lambda x: x[1], reverse=True)
    candidates = [u for u, _ in ordered]
    thumb_hint = candidates[0] if candidates else None

    # ----------------- Text / HTML fields -----------------
    # Rich body HTML from feed <content> (first content block)
    content_html = ""
    content = entry.get("content")
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            content_html = first.get("value") or ""

    # Fallback description/summary HTML from feed
    description_html = (
        entry.get("summary_detail", {}).get("value")
        or entry.get("summary")
        or entry.get("description")
        or ""
    )

    # Plain-text summary for classification / push notifications etc.
    # Prefer entry.summary if present, else strip HTML from description_html.
    raw_summary_text = entry.get("summary") or entry.get("title") or description_html
    summary_text = _strip_html(raw_summary_text or "")

    # Gather a few inline <img> URLs actually embedded in body,
    # mostly for debugging / analytics / future UI.
    inline_imgs = [
        u for u, _ in _images_from_html_block(content_html, link, page_url=link)[:3]
    ]
    if not inline_imgs:
        inline_imgs = [
            u for u, _ in _images_from_html_block(description_html, link, page_url=link)[:3]
        ]

    # ----------------- Timestamp & title -----------------
    published_ts = _entry_epoch(entry)
    title = _strip_html(entry.get("title") or "")

    # ----------------- Build payload -----------------
    payload: Dict[str, Any] = {
        # canonical identifiers
        "url": link,
        "feed": feed_url,

        # human-facing text
        "title": title,
        "summary": summary_text,  # short text / notification snippet

        # richer HTML bodies (safe rendering/sanitizing happens later)
        "content_html": content_html or "",
        "description_html": description_html or "",

        # when it (allegedly) went live
        "published_ts": published_ts,  # int epoch seconds or None

        # enclosures from feed (useful if we want audio/video or direct thumbs)
        "enclosures": entry.get("enclosures") or [],

        # extras to help normalize_event() choose thumbnail & debug
        "inline_images": inline_imgs or None,
        "image_candidates": candidates or None,
    }

    dlog(
        "payload",
        {
            "url": link,
            "published_ts": published_ts,
            "thumb_hint": thumb_hint,
            "top_candidates": candidates[:3],
        },
    )

    return payload, thumb_hint, candidates
