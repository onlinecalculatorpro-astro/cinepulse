from __future__ import annotations

import json
import os
import re
import time as _time
from datetime import datetime, timezone
from typing import List, Optional, Union, TypedDict

import feedparser
from redis import Redis
from rq import Queue

__all__ = ["youtube_rss_poll", "normalize_event"]

class AdapterEventDict(TypedDict, total=False):
    source: str
    source_event_id: str
    title: str
    kind: str
    published_at: Optional[str]
    payload: dict

TRAILER_RE = re.compile(r"\b(trailer|teaser)\b", re.I)
FEED_KEY = "feed:items"
FEED_MAX = 200

def _classify(title: str) -> str:
    return "trailer" if TRAILER_RE.search(title or "") else "ott"

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
    return value

def _extract_video_id(entry: dict) -> Optional[str]:
    vid = entry.get("yt_videoid") or entry.get("yt:videoid")
    if vid:
        return vid
    link = entry.get("link") or ""
    if "watch?v=" in link:
        return link.split("watch?v=", 1)[1].split("&", 1)[0]
    return None

def _safe_job_id(prefix: str, *parts: str) -> str:
    def clean(s: str) -> str:
        return re.sub(r"[^A-Za-z0-9_\-]+", "-", s).strip("-")
    safe = "-".join([clean(prefix), *(clean(p) for p in parts if p)])
    return safe or clean(prefix)

def normalize_event(event: dict) -> dict:
    story = {
        "id": f"{event.get('source','src')}:{event.get('source_event_id','')}",
        "kind": event.get("kind", "trailer"),
        "title": event.get("title"),
        "summary": None,
        "published_at": _to_rfc3339(event.get("published_at")),
        "source": event.get("source"),
        "thumb_url": (
            f"https://i.ytimg.com/vi/{event.get('source_event_id','')}/hqdefault.jpg"
            if event.get("source") == "youtube" else None
        ),
        "normalized_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    conn = Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"))
    conn.lpush(FEED_KEY, json.dumps(story))
    conn.ltrim(FEED_KEY, 0, FEED_MAX - 1)
    print("[normalize_event] -> feed", story["id"], "-", story.get("title"))
    return story

def youtube_rss_poll(
    channel_id: str,
    published_after: Optional[Union[str, datetime]] = None,
    max_items: int = 10,
) -> int:
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    conn = Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"))
    etag_key = f"rss:etag:{channel_id}"
    mod_key = f"rss:mod:{channel_id}"

    etag = conn.get(etag_key)
    etag = etag.decode() if etag else None

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

    events: List[AdapterEventDict] = []
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
        events.append(
            AdapterEventDict(
                source="youtube",
                source_event_id=vid,
                title=title,
                kind=_classify(title),
                published_at=pub_norm,
                payload={"channelId": channel_id, "videoId": vid},
            )
        )

    q = Queue("events", connection=conn)
    emitted = 0
    for ev in events:
        jid = _safe_job_id("normalize", ev["source"], ev["source_event_id"])
        q.enqueue(
            normalize_event,  # function ref
            ev,
            job_id=jid,
            ttl=600,
            result_ttl=300,
            failure_ttl=300,
        )
        emitted += 1

    print(f"[youtube_rss_poll] channel={channel_id} emitted={emitted}")
    return emitted
