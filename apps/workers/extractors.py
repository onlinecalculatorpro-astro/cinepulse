from __future__ import annotations

"""
Extractor layer
---------------
This file is responsible for:
- pulling structured data out of one feed entry (RSS / Atom / YouTube etc.)
- aggressively discovering a good hero/thumbnail image
- lightly ranking those candidates

It does NOT:
- classify verticals (entertainment/sports/etc.)
- generate tags/kind_meta
Those happen later in normalize_event() inside jobs.py.

Public API:
    build_rss_payload(entry, feed_url)
        -> (payload: dict, thumb_hint: Optional[str], candidates: List[str])

    choose_best_image(candidates)  # helper if someone just wants 1 URL
    abs_url(), to_https()

The 'payload' we return is what normalize_event() will consume.
normalize_event() will do the final scoring with context, pick the best
hero image, add poster_url/thumb_url/etc., and enqueue for sanitizer.
"""

import calendar
import html
import json
import os
import re
from typing import Iterable, Optional, Tuple, List, Dict, Any
from urllib.parse import (
    urljoin,
    urlparse,
    urlunparse,
    urlencode,
    parse_qsl,
)

__all__ = [
    "build_rss_payload",          # -> (payload: dict, thumb_hint: Optional[str], candidates: List[str])
    "choose_best_image",          # quick 1-shot picker
    "abs_url",
    "to_https",
]

# ============================== Config ===============================

EXTRACT_DEBUG = os.getenv("EXTRACT_DEBUG", "0").lower() not in ("0", "", "false", "no")

# Optional network fetch to page for richer discovery (og:image, JSON-LD hero, etc.)
OG_FETCH = os.getenv("OG_FETCH", "1").lower() not in ("0", "", "false", "no")

# We ONLY fetch pages whose hostname ends with one of these suffixes.
# This avoids hammering random sites / getting IP-blocked.
OG_ALLOWED_DOMAINS = {
    d.strip().lower()
    for d in os.getenv(
        "OG_ALLOWED_DOMAINS",
        (
            "bollywoodhungama.com,koimoi.com,pinkvilla.com,filmfare.com,deadline.com,"
            "indiewire.com,slashfilm.com,tellyupdates.com,wordpress.com,wp.com,"
            "wordpress.org,wpengine.com,cloudfront.net,akamaized.net"
        ),
    ).split(",")
    if d.strip()
}

# Also try AMP page if present (<link rel="amphtml">).
AMP_FETCH = os.getenv("AMP_FETCH", "1").lower() not in ("0", "", "false", "no")

# Optionally HEAD-probe URLs without extensions to confirm Content-Type: image/*.
HEAD_PROBE = os.getenv("HEAD_PROBE", "0").lower() not in ("0", "", "false", "no")

OG_TIMEOUT = float(os.getenv("OG_TIMEOUT", "3.5"))
USER_AGENT = os.getenv(
    "FETCH_UA",
    "Mozilla/5.0 (compatible; CinePulseBot/1.2; +https://example.com/bot)",
)

# Common "looks like actual photo" extensions.
IMG_EXTS = (
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".jfif", ".pjpeg"
)

# Hotlink-friendly or generally reliable CDNs we trust a little more.
IMG_HOSTS_FRIENDLY = {
    "i0.wp.com",
    "i1.wp.com",
    "images.ctfassets.net",
}

# ============================== Debug helper =========================

def dlog(msg: str, *kv: Any) -> None:
    if EXTRACT_DEBUG:
        details = " | ".join(repr(k) for k in kv) if kv else ""
        print(f"[extract] {msg}{(' ' + details) if details else ''}")

# ============================== URL helpers ==========================

def abs_url(url: Optional[str], base: str) -> Optional[str]:
    """
    Return an absolute URL.
    - Resolve relative URLs against `base`.
    - HTML-unescape first.
    """
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
    """
    Force http:// → https:// and protocol-relative // → https://.
    Leave https:// and data: etc. alone.
    """
    if not url:
        return None
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("http://"):
        return "https://" + url[7:]
    return url

def _strip_tracking_query(u: str) -> str:
    """
    Remove obvious tracking params (utm_*, fbclid, gclid, itok, etc.)
    but keep params that affect asset size/format (like w=1080 or fm=webp).
    """
    p = urlparse(u)
    if not p.query:
        return u

    keep_pairs: List[Tuple[str, str]] = []
    for k, v in parse_qsl(p.query, keep_blank_values=True):
        lk = k.lower()
        if lk.startswith("utm_") or lk in {
            "fbclid",
            "gclid",
            "igshid",
            "mc_cid",
            "mc_eid",
            "itok",
        }:
            continue
        keep_pairs.append((k, v))

    new_q = urlencode(keep_pairs)
    return urlunparse((p.scheme, p.netloc, p.path, p.params, new_q, p.fragment))

def _norm(url: Optional[str], base: str) -> Optional[str]:
    """
    Normalize a candidate URL:
    - resolve relative → absolute
    - force https
    - strip tracking query junk
    """
    u = to_https(abs_url(url, base))
    return _strip_tracking_query(u) if u else None

# ============================== Image heuristics =====================

def _has_image_ext(path_or_url: str) -> bool:
    """
    True if URL path (before query string) ends with a common image extension.
    """
    before_q = path_or_url.split("?", 1)[0].lower()
    return before_q.endswith(IMG_EXTS)

def _looks_image_like(url: str) -> bool:
    """
    We accept:
    - normal extensions (.jpg, .png, etc.)
    - obvious WordPress-style /wp-content/uploads/ paths
    - URLs with query hints like format=webp
    - OG / hero / thumbnail-ish keywords
    - Cloudinary/imgix/GraphCMS style "image/upload" pipelines even without ext
    """
    l = url.lower()

    if _has_image_ext(l):
        return True

    # WordPress & other CMS uploads often expose hero images here
    if "/wp-content/uploads/" in l:
        return True

    # query string hints (format=webp|jpg|png etc.)
    if re.search(r"([?&](?:format|fm|output)=(?:jpe?g|png|webp|avif))", l):
        return True

    # generic hero-ish / social card-ish cues
    if re.search(r"(og|open[-_]?graph|image|thumb|thumbnail|poster|photo|hero|share)", l):
        return True

    # cloudinary/imgix style transforms
    if re.search(r"/(?:image|upload)/.*(?:/c_|/w_|/q_|/f_|/ar_|/g_)", l):
        return True

    return False

def _prefer_same_origin_score(u: str, page_url: str) -> int:
    """
    Light bias: prefer images on the same site (less likely to 403),
    and give some credit to certain well-behaved CDNs.
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
    Fetch full HTML so we can scrape og:image, twitter:image, JSON-LD hero, etc.
    - Only called for allowlisted domains (checked in _maybe_fetch()).
    - Short timeout, no retries.
    """
    try:
        # Try requests first (nicer ergonomics / redirects)
        try:
            import requests  # type: ignore
            r = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=OG_TIMEOUT)
            if r.status_code >= 400:
                return None
            r.encoding = r.encoding or "utf-8"
            return r.text
        except Exception:
            # Fallback: stdlib urllib
            from urllib.request import Request, urlopen
            req = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=OG_TIMEOUT) as resp:  # nosec
                return resp.read().decode("utf-8", "ignore")
    except Exception:
        return None

def _head_is_image(url: str) -> bool:
    """
    Optionally issue a HEAD request to confirm something without an extension
    is actually image/*.
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
    Only fetch HTML if the domain is allowlisted.
    We check suffix match (endswith) because many feeds are subdomains/CDNs.
    """
    host = urlparse(url).netloc.lower().replace("www.", "")
    if OG_ALLOWED_DOMAINS and not any(host.endswith(d) for d in OG_ALLOWED_DOMAINS):
        return None
    return _fetch_text(url)

def _extract_base_href(s: str, fallback: str) -> str:
    """
    Some pages define <base href="..."> which changes how relative URLs resolve.
    We honor that, but fall back to the page URL if it's weird/broken.
    """
    m = re.search(r'<base[^>]+href=["\']([^"\']+)["\']', s, flags=re.I)
    if m:
        return to_https(m.group(1)) or fallback
    return fallback

def _choose_from_srcset(srcset: str) -> Optional[str]:
    """
    From a srcset like "img_200.jpg 200w, img_1200.jpg 1200w"
    choose the largest width candidate.
    """
    best = None
    wbest = -1
    for part in srcset.split(","):
        tokens = part.strip().split()
        if not tokens:
            continue
        cand_url = tokens[0]
        w = 0
        if len(tokens) > 1 and tokens[1].endswith("w"):
            try:
                w = int(re.sub(r"\D", "", tokens[1]))
            except Exception:
                w = 0
        if w >= wbest:
            best, wbest = cand_url, w
    return best

# ===================== Scoring =====================

_BAD_BRAND_RE = re.compile(
    r"(sprite|icon|favicon|logo|watermark|default[-_]?og|default[-_]?share|"
    r"social[-_]?share|generic[-_]?share|breaking[-_]?news[-_]?card)",
    re.I,
)

_TINY_RE = re.compile(r"(\b|_)(1x1|64x64|100x100|150x150)(\b|_)")

def _looks_bad_brand_card(u: str) -> bool:
    """
    Detect obvious social share cards / site logo tiles / pixel trackers.
    We don't want those to dominate score.
    """
    l = u.lower()

    if _BAD_BRAND_RE.search(l):
        return True

    # very tiny fixed size
    if _TINY_RE.search(l):
        return True

    # placeholder-y
    if "default" in l and ("og" in l or "share" in l or "social" in l):
        return True

    if "placeholder" in l:
        return True

    return False

def _numeric_size_hint(u: str) -> int:
    """
    Guess resolution from patterns like "1200x630", "-2048", "_1080", etc.
    Larger number => bigger image => higher score.
    """
    size = 0

    m = re.search(r'(\d{3,5})[xX_ -](\d{3,5})', u)
    if m:
        try:
            a = int(m.group(1))
            b = int(m.group(2))
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
    Assign a score to an image URL for ranking candidates.

    Heuristics:
    - Big hero / og-ish images get a heavy bonus.
    - If it's an obvious tiny logo/social share card, huge penalty.
    - Larger numeric hints (1200x630 etc.) = likely better quality.
    - Small thumbs / sprites / favicons = penalty.
    """
    l = u.lower()
    score = bias

    # downweight obvious logo/share-card junk first
    if _looks_bad_brand_card(l):
        score -= 5000

    # prefer large-ish hero-ish names
    if re.search(r"(og|open[-_]?graph|hero|share|feature|original|full)", l, re.I):
        score += 400

    # numeric dimension hint
    score += _numeric_size_hint(l)

    # punish sprites/icons/favicons/amp placeholders
    if re.search(r"(sprite|icon|logo-|favicon|amp/)", l, re.I):
        score -= 200

    # punish explicit "thumb", "thumbnail", "small", etc.
    if re.search(r"(thumb|thumbnail|small|mini|tiny)", l, re.I):
        score -= 60

    return score

def choose_best_image(candidates: Iterable[str]) -> Optional[str]:
    """
    Convenience: choose top-scoring URL from a list.
    We assume candidates are already normalized absolute https URLs.
    """
    best = None
    s_best = -10**9
    for u in candidates:
        s = _score_image_url(u)
        if s > s_best:
            best, s_best = u, s
    return best

# ===================== HTML scraping helpers =========================

def _images_from_html_block(
    html_str: Optional[str],
    base_url: str,
    page_url: Optional[str] = None,
) -> List[Tuple[str, int]]:
    """
    Return [(normalized_url, score_bias), ...] from some HTML.
    We scan:
    - <img src="">
    - lazy-load attrs (data-src etc.)
    - srcset / <picture>
    - <amp-img>
    - <noscript><img>
    - background-image: url(...)
    - data-background / data-bg
    - <a href="...image...">
    - og:image / twitter:image / JSON-LD ImageObject
    - <link rel="image_src"> etc.

    Then:
    - normalize URLs (absolute + https + strip trackers)
    - filter only "image-like" URLs (_looks_image_like or HEAD check)
    - add small bias if same origin as the article
    - dedupe
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

    # <picture><source type="image/...">
    for m in re.finditer(
        r'<source[^>]+type=["\']image/[^"\']+["\'][^>]+srcset=["\']([^"\']+)["\']',
        s,
        flags=re.I,
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

    # <noscript> fallback images
    for m in re.finditer(r'<noscript[^>]*>(.*?)</noscript>', s, flags=re.I | re.S):
        sub = m.group(1)
        for m2 in re.finditer(r'<img[^>]+src=["\']([^"\']+)["\']', sub, flags=re.I):
            out.append((m2.group(1), 160))

    # Inline CSS background-image: url("...")
    for m in re.finditer(
        r'background-image\s*:\s*url\((["\']?)([^)]+?)\1\)',
        s,
        flags=re.I,
    ):
        out.append((m.group(2), 110))

    # Custom data-* background hooks
    for attr in (
        "data-background",
        "data-background-image",
        "data-bg",
        "data-bg-url",
    ):
        for m in re.finditer(
            fr'(?:<\w+[^>]+{attr}=["\']([^"\']+)["\'])',
            s,
            flags=re.I,
        ):
            out.append((m.group(1), 110))

    # <a href="..."> wrappers that directly link an image
    for m in re.finditer(
        r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>(?:\s*Image[:\s]|<img|[^<]{0,7})',
        s,
        flags=re.I,
    ):
        out.append((m.group(1), 200))

    # any <a href="*.jpg|*.webp|...">
    for m in re.finditer(
        r'<a[^>]+href=["\']([^"\']+\.(?:jpe?g|png|webp|gif|avif))["\']',
        s,
        flags=re.I,
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
            flags=re.I,
        ):
            out.append((m.group(1), bias))

    # <link rel="image_src" ...> or <link rel="preload" as="image" href="...">
    for m in re.finditer(
        r'<link[^>]+rel=["\']image_src["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I,
    ):
        out.append((m.group(1), 330))
    for m in re.finditer(
        r'<link[^>]+rel=["\']preload["\'][^>]+as=["\']image["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I,
    ):
        out.append((m.group(1), 310))

    # JSON-LD <script type="application/ld+json"> ... </script>
    for m in re.finditer(
        r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>',
        s,
        flags=re.I | re.S,
    ):
        raw = m.group(1).strip()

        # many sites emit invalid-ish JSON-LD; attempt a light fix
        try:
            data = json.loads(raw)
        except Exception:
            try:
                data = json.loads(raw.replace("\n", " ").replace(", }", " }"))
            except Exception:
                data = None

        if data is None:
            continue

        objs = data if isinstance(data, list) else [data]

        def collect_from_ld(val: Any, bias: int) -> None:
            if isinstance(val, str):
                out.append((val, bias))
                return
            if isinstance(val, dict):
                if val.get("url"):
                    out.append((val["url"], bias))
                if val.get("@type") == "ImageObject":
                    for k in ("url", "contentUrl", "thumbnail", "thumbnailUrl"):
                        if val.get(k):
                            out.append((val[k], bias))
                return
            if isinstance(val, list):
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

    # Normalize + dedupe + origin bias
    results: List[Tuple[str, int]] = []
    seen: set[str] = set()

    for raw_url, base_bias in out:
        norm_u = _norm(raw_url, base_url)
        if not norm_u:
            continue

        # Only keep URLs that look like an image or HEAD-probe to image/*
        if not (_looks_image_like(norm_u) or _head_is_image(norm_u)):
            continue

        if norm_u in seen:
            continue
        seen.add(norm_u)

        # bump bias if same origin as article
        bias = base_bias
        if page_url:
            bias += _prefer_same_origin_score(norm_u, page_url)

        results.append((norm_u, bias))

    return results

# ===================== Feed entry extraction =========================

def _enclosures_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    """
    Inspect feed-level enclosures (RSS <enclosure> tags or links with rel="enclosure")
    and grab anything that looks like an image.
    """
    out: List[Tuple[str, int]] = []

    for enc in entry.get("enclosures") or []:
        u = enc.get("href") or enc.get("url")
        typ = (enc.get("type") or "").lower()
        if u and (typ.startswith("image/") or _has_image_ext(u)):
            out.append((_norm(u, base_url) or u, 265))

    for lnk in entry.get("links") or []:
        if isinstance(lnk, dict) and lnk.get("rel") == "enclosure":
            u = lnk.get("href")
            typ = (lnk.get("type") or "").lower()
            if u and (typ.startswith("image/") or _has_image_ext(u)):
                out.append((_norm(u, base_url) or u, 260))

    # keep only non-empty normalized URLs
    return [(u, b) for (u, b) in out if u]

def _media_fields_from_entry(entry: Dict[str, Any], base_url: str) -> List[Tuple[str, int]]:
    """
    Look for common RSS media extensions:
    - media_thumbnail / media:thumbnail
    - media_content / media:content
    - simple fields like 'image', 'poster', etc.
    """
    out: List[Tuple[str, int]] = []

    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list):
        for t in thumbs:
            if isinstance(t, dict) and t.get("url"):
                out.append((_norm(t["url"], base_url) or t["url"], 285))

    media_cont = entry.get("media_content") or entry.get("media:content")
    if isinstance(media_cont, list):
        for it in media_cont:
            if not isinstance(it, dict):
                continue
            u = it.get("url") or it.get("href")
            typ = (it.get("type") or "").lower()
            if u and (typ.startswith("image/") or _has_image_ext(u)):
                out.append((_norm(u, base_url) or u, 280))

    # ad-hoc fields some feeds include
    for k in ("image", "picture", "logo", "thumbnail", "poster"):
        v = entry.get(k)
        if isinstance(v, str):
            out.append((_norm(v, base_url) or v, 230))
        elif isinstance(v, dict) and v.get("href"):
            out.append((_norm(v["href"], base_url) or v["href"], 230))

    return [(u, b) for (u, b) in out if u]

def _collect_all_candidates(entry: Dict[str, Any], feed_url: str, link_url: str) -> List[Tuple[str, int]]:
    """
    Aggregate candidate image URLs from:
    - feed-level media/enclosures/custom media fields
    - inline HTML in summary/content blocks
    """
    base = link_url or feed_url
    cand: List[Tuple[str, int]] = []

    # feed-level media/enclosures/custom fields
    cand += _media_fields_from_entry(entry, base)
    cand += _enclosures_from_entry(entry, base)

    # inline HTML blocks in entry
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

    # Deduplicate by URL, keep the highest bias for each unique URL.
    best_bias: Dict[str, int] = {}
    for u, b in cand:
        if not u:
            continue
        if u not in best_bias or b > best_bias[u]:
            best_bias[u] = b

    return [(u, best_bias[u]) for u in best_bias.keys()]

# ===================== Optional page probing (OG/AMP + shims) =========

def _extract_amp_link(s: str, base: str) -> Optional[str]:
    """
    Pull <link rel="amphtml" href="..."> from page HTML if present.
    """
    m = re.search(
        r'<link[^>]+rel=["\']amphtml["\'][^>]+href=["\']([^"\']+)["\']',
        s,
        flags=re.I,
    )
    if m:
        return _norm(m.group(1), base)
    return None

def _page_discover_images(page_html: str, page_url: str) -> List[Tuple[str, int]]:
    """
    Mine the full article HTML for og:image / twitter:image / JSON-LD hero / main stills.
    We also add tiny site-specific nudges.
    """
    page_base = _extract_base_href(page_html, page_url)
    cands = _images_from_html_block(page_html, page_base, page_url=page_url)

    # --- light site shims ------------------------------------------
    host = urlparse(page_url).netloc.lower().removeprefix("www.")

    # WordPress-heavy Bollywood sites (koimoi.com etc.) often embed a branded
    # orange share card AND a real still from the movie in /wp-content/uploads/.
    # We want to bump real stills.
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
    Deepen our candidate list:
    - fetch main article URL if allowed
    - scrape hero images (og:image, JSON-LD)
    - (optionally) follow AMP version and merge its candidates

    This is our fallback when the RSS entry itself doesn't expose
    a good thumbnail.
    """
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
    """
    Collapse simple HTML into plain-ish text:
    - strip tags
    - unescape entities
    - collapse whitespace

    (This is NOT full sanitization for UI. It's just for summaries / model input.)
    """
    if not text:
        return ""
    no_tags = re.sub(r"<[^>]+>", " ", text)
    no_tags = html.unescape(no_tags)
    no_tags = re.sub(r"\s+", " ", no_tags).strip()
    return no_tags

def _entry_epoch(entry: Dict[str, Any]) -> Optional[int]:
    """
    Convert feedparser's published_parsed / updated_parsed to epoch seconds (UTC).
    """
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
    Build a payload for this RSS entry that normalize_event() (in jobs.py)
    will later convert into a final "story" dict.

    Returns (payload_dict, thumb_hint, candidates):

        payload_dict:
            {
                "url": canonical article URL,
                "feed": source feed URL,
                "title": cleaned title,
                "summary": plain-text summary,
                "content_html": raw article HTML (unsafe),
                "description_html": summary/description HTML (unsafe),
                "published_ts": epoch seconds (int or None),
                "enclosures": [...],
                "inline_images": [up to ~3 inline imgs],
                "image_candidates": [all candidate hero URLs, best-first],
            }

        thumb_hint:
            our best single guess at a hero/thumbnail (string or None)

        candidates:
            same URLs as image_candidates but flattened list[str]

    normalize_event() will:
      - re-score candidates with more advanced rules
      - pick the true hero (movie still / celeb photo, not social card)
      - attach that hero to thumb_url/poster_url/etc.
      - classify kind, tags, verticals
      - enqueue to sanitizer
    """
    # 1. Canonical link for the story
    link = entry.get("link") or entry.get("id") or ""
    link = to_https(abs_url(link, feed_url)) or link

    # 2. Collect all candidate images from the feed entry itself
    cands = _collect_all_candidates(entry, feed_url, link)

    # 3. If no good candidates yet, or the best bias is weak (<320),
    #    try fetching the live article / AMP version to mine og:image, etc.
    top_bias = max((b for _, b in cands), default=0)
    if OG_FETCH and (not cands or top_bias < 320) and link:
        cands += _maybe_probe_page_for_images(link)

    # 4. Merge + score + dedupe
    merged: Dict[str, int] = {}
    for u, bias in cands:
        if not u:
            continue
        if _looks_image_like(u) or _head_is_image(u):
            origin_bonus = _prefer_same_origin_score(u, link) if link else 0
            # keep the max of existing score vs new score
            merged[u] = max(
                merged.get(u, -10**9),
                bias + origin_bonus + _score_image_url(u),
            )

    # sort by final score high → low
    ordered = sorted(merged.items(), key=lambda x: x[1], reverse=True)
    candidates = [u for (u, _s) in ordered]

    # first one is our "best guess" hero image;
    # normalize_event() will still re-check quality.
    thumb_hint = candidates[0] if candidates else None

    # 5. Get raw HTML blobs / summary text for text modeling later
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

    # plain text summary for classification / push text
    raw_summary_text = entry.get("summary") or entry.get("title") or description_html
    summary_text = _strip_html(raw_summary_text or "")

    # For debugging / analytics: capture a couple inline imgs actually in body
    inline_imgs = [
        u for (u, _b) in _images_from_html_block(content_html, link, page_url=link)[:3]
    ]
    if not inline_imgs:
        inline_imgs = [
            u for (u, _b) in _images_from_html_block(description_html, link, page_url=link)[:3]
        ]

    # timestamps
    published_ts = _entry_epoch(entry)
    cleaned_title = _strip_html(entry.get("title") or "")

    # 6. Build payload dict
    payload: Dict[str, Any] = {
        # canonical identifiers
        "url": link,
        "feed": feed_url,

        # human-facing text
        "title": cleaned_title,
        "summary": summary_text,  # short text / notification snippet

        # richer HTML bodies (unsafe markup; UI sanitizes downstream)
        "content_html": content_html or "",
        "description_html": description_html or "",

        # when it (allegedly) went live
        "published_ts": published_ts,  # int epoch seconds or None

        # media / debug
        "enclosures": entry.get("enclosures") or [],
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
