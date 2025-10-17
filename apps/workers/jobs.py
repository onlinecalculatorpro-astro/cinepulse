# apps/workers/jobs.py
from __future__ import annotations

import hashlib
import json
import os
import re
import time as _time
from datetime import datetime, timezone
from typing import List, Optional, Union, TypedDict
from urllib.parse import urlparse

import feedparser
from redis import Redis
from rq import Queue

__all__ = ["youtube_rss_poll", "rss_poll", "normalize_event"]

# --------------------------- Redis / keys ---------------------------------

def _redis() -> Redis:
    return Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"), decode_responses=True)

FEED_KEY = "feed:items"   # LIST newest-first
SEEN_KEY = "feed:seen"    # SET of story ids (dedupe)
FEED_MAX = int(os.getenv("FEED_MAX", "1200"))

# --------------------------- Types ----------------------------------------

class AdapterEventDict(TypedDict, total=False):
    source: str                  # "youtube" | "rss:<domain>"
    source_event_id: str         # unique per source (videoId | link hash)
    title: str
    kind: str                    # trailer | ott | news | release
    published_at: Optional[str]  # RFC3339
    thumb_url: Optional[str]
    payload: dict

# --------------------------- Utils ----------------------------------------

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)
RELEASE_RE = re.compile(r"\b(release[sd]?|in\s+theatres?|coming\s+soon|on\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\b)\b", re.I)

def _classify_from_title(title: str, fallback: str = "news") -> str:
    t = title or ""
    if TRAILER_RE.search(t):
        return "trailer"
    if RELEASE_RE.search(t):
        return "release"
    return fallback

def _to_rfc3339(value: Optional[Union[str, datetime, _time.struct_time]]) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, _time.struct_time):
        dt = datetime.fromtimestamp(_time.mktime(value), tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    v = str(value).strip()
    return v if v else None

def _extract_video_id(entry: dict) -> Optional[str]:
    vid = entry.get("yt_videoid") or entry.get("yt:videoid")
    if vid:
        return vid
    link = (entry.get("link") or "") + " "
    if "watch?v=" in link:
        return link.split("watch?v=", 1)[1].split("&", 1)[0]
    return None

def _link_thumb(entry: dict) -> Optional[str]:
    # media:thumbnail as list of dicts with 'url'
    thumbs = entry.get("media_thumbnail") or entry.get("media:thumbnail")
    if isinstance(thumbs, list) and thumbs:
        url = thumbs[0].get("url") if isinstance(thumbs[0], dict) else None
        if url:
            return url
    # enclosure
    links = entry.get("links") or []
    for l in links:
        if isinstance(l, dict) and l.get("rel") == "enclosure" and l.get("type", "").startswith("image/"):
            return l.get("href")
    # some feeds place 'image' / 'logo'
    for k in ("image", "picture", "logo"):
        v = entry.get(k)
        if isinstance(v, str) and v.startswith("http"):
            return v
        if isinstance(v, dict) and v.get("href"):
            return v["href"]
    return None

def _safe_job_id(prefix: str, *parts: str) -> str:
    def clean(s: str) -> str:
        return re.sub(r"[^A-Za-z0-9_\-]+", "-", s).strip("-")
    safe = "-".join([clean(prefix), *(clean(p) for p in parts if p)])
    return safe or clean(prefix)

def _domain(url: str) -> str:
    try:
        return urlparse(url).netloc.replace("www.", "")
    except Exception:
        return "rss"

def _hash_link(link: str) -> str:
    return hashlib.sha1(link.encode("utf-8", "ignore")).hexdigest()  # stable id for RSS items

# --------------------------- Normalizer (writes to feed) -------------------

def normalize_event(event: AdapterEventDict) -> dict:
    conn = _redis()

    source = event.get("source", "src")
    src_id = event.get("source_event_id", "")
    story_id = f"{source}:{src_id}".strip(":")
    kind = event.get("kind", "news")
    title = event.get("title", "") or ""
    published_at = _to_rfc3339(event.get("published_at"))
    thumb_url = event.get("thumb_url")

    if source == "youtube" and not thumb_url and src_id:
        thumb_url = f"https://i.ytimg.com/vi/{src_id}/hqdefault.jpg"

    story = {
        "id": story_id,
        "kind": kind,
        "title": title,
        "summary": None,
        "published_at": published_at,
        "source": source,
        "thumb_url": thumb_url,
        "normalized_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # Dedupe: only push new IDs
    if conn.sadd(SEEN_KEY, story_id):
        pipe = conn.pipeline()
        pipe.lpush(FEED_KEY, json.dumps(story))
        pipe.ltrim(FEED_KEY, 0, FEED_MAX - 1)
        pipe.execute()
        print("[normalize_event] NEW -> feed", story_id, "-", title)
        return story

    print("[normalize_event] SKIP duplicate", story_id)
    return story

# --------------------------- YouTube poller --------------------------------

# Known channel kinds (override title-based detection)
YOUTUBE_CHANNEL_KIND = {
    # Studios = trailers
    # "UCvC4D8onUfXzvjTOM-dBfEA": "trailer",  # Marvel (example)
    # Streamers = ott
    # "UCWOA1ZGywLbqmigxE4Qlvuw": "ott",      # Netflix (example)
}

def youtube_rss_poll(
    channel_id: str,
    published_after: Optional[Union[str, datetime]] = None,
    max_items: int = 10,
) -> int:
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    conn = _redis()
    etag_key = f"rss:etag:yt:{channel_id}"
    mod_key = f"rss:mod:yt:{channel_id}"

    etag = conn.get(etag_key)
    mod_epoch = conn.get(mod_key)
    modified = _time.gmtime(float(mod_epoch)) if mod_epoch else None

    parsed = feedparser.parse(url, etag=etag, modified=modified)
    status = getattr(parsed, "status", 200)
    if status == 304:
        print(f"[youtube_rss_poll] channel={channel_id} no changes (304)")
        return 0

    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        from time import mktime as _mktime
        conn.setex(mod_key, 7 * 24 * 3600, str(_mktime(parsed.modified_parsed)))

    cutoff = _to_rfc3339(published_after)

    q = Queue("events", connection=conn)
    emitted = 0

    for entry in parsed.entries[:max_items]:
        vid = _extract_video_id(entry) or ""
        if not vid:
            continue
        title = entry.get("title", "")
        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )
        if cutoff and pub_norm and pub_norm <= cutoff:
            continue

        # classify: channel hint > title regex fallback
        kind = YOUTUBE_CHANNEL_KIND.get(channel_id) or ("trailer" if TRAILER_RE.search(title) else "ott")

        ev: AdapterEventDict = {
            "source": "youtube",
            "source_event_id": vid,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": None,  # computed in normalize if missing
            "payload": {"channelId": channel_id, "videoId": vid},
        }

        jid = _safe_job_id("normalize", ev["source"], ev["source_event_id"])
        q.enqueue(
            normalize_event,
            ev,
            job_id=jid,
            ttl=600,
            result_ttl=300,
            failure_ttl=300,
        )
        emitted += 1

    print(f"[youtube_rss_poll] channel={channel_id} emitted={emitted}")
    return emitted

# --------------------------- Generic RSS poller ----------------------------

def rss_poll(
    url: str,
    kind_hint: str = "news",
    max_items: int = 10,
) -> int:
    conn = _redis()
    etag_key = f"rss:etag:{url}"
    mod_key = f"rss:mod:{url}"

    etag = conn.get(etag_key)
    mod_epoch = conn.get(mod_key)
    modified = _time.gmtime(float(mod_epoch)) if mod_epoch else None

    parsed = feedparser.parse(url, etag=etag, modified=modified)
    status = getattr(parsed, "status", 200)
    if status == 304:
        print(f"[rss_poll] url={url} no changes (304)")
        return 0

    if getattr(parsed, "etag", None):
        conn.setex(etag_key, 7 * 24 * 3600, parsed.etag)
    if getattr(parsed, "modified_parsed", None):
        from time import mktime as _mktime
        conn.setex(mod_key, 7 * 24 * 3600, str(_mktime(parsed.modified_parsed)))

    source_domain = _domain(parsed.feed.get("link") or url)

    q = Queue("events", connection=conn)
    emitted = 0

    for entry in parsed.entries[:max_items]:
        title = entry.get("title", "") or ""
        # pick link: prefer 'link' else 'id'
        link = entry.get("link") or entry.get("id") or ""
        if not link:
            continue

        # stable per-source id
        src_id = _hash_link(link)

        pub_norm = _to_rfc3339(
            entry.get("published_parsed")
            or entry.get("updated_parsed")
            or entry.get("published")
            or entry.get("updated")
        )

        # classification: upgrade from hint when title clearly indicates
        kind = _classify_from_title(title, fallback=kind_hint)

        ev: AdapterEventDict = {
            "source": f"rss:{source_domain}",
            "source_event_id": src_id,
            "title": title,
            "kind": kind,
            "published_at": pub_norm,
            "thumb_url": _link_thumb(entry),
            "payload": {"url": link, "feed": url},
        }

        jid = _safe_job_id("normalize", "rss", source_domain, src_id[:10])
        q.enqueue(
            normalize_event,
            ev,
            job_id=jid,
            ttl=600,
            result_ttl=300,
            failure_ttl=300,
        )
        emitted += 1

    print(f"[rss_poll] url={url} domain={source_domain} emitted={emitted}")
    return emitted
