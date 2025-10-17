# apps/workers/enqueuer.py
import os
import yaml
from rq import Queue
from redis import Redis
from jobs import youtube_rss_poll, rss_poll  # same package

SOURCES_FILE = os.getenv("SOURCES_FILE", os.path.join(os.path.dirname(__file__), "sources.yaml"))

def main():
    conn = Redis.from_url(os.getenv("REDIS_URL", "redis://redis:6379/0"), decode_responses=True)
    q = Queue("default", connection=conn)

    with open(SOURCES_FILE, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}

    total = 0

    for yt in (cfg.get("youtube") or []):
        if isinstance(yt, str):
            channel_id = yt
            kind = None
        else:
            channel_id = yt.get("channel_id")
            kind = yt.get("kind")
        if not channel_id:
            continue
        # Allow optional per-channel kind override via env-free config
        if kind:
            # expose to jobs via env var map if you like; or extend YOUTUBE_CHANNEL_KIND centrally
            pass
        job = q.enqueue_call(
            func=youtube_rss_poll,
            args=(channel_id,),
            kwargs={"max_items": int(cfg.get("max_items_per_feed", 10))},
            job_id=f"poll:yt:{channel_id}",
            ttl=600, result_ttl=0, failure_ttl=900,
        )
        print("enqueued", job.id)
        total += 1

    for rss in (cfg.get("rss") or []):
        url = rss if isinstance(rss, str) else rss.get("url")
        kind_hint = "news" if isinstance(rss, str) else (rss.get("kind") or "news")
        if not url:
            continue
        job = q.enqueue_call(
            func=rss_poll,
            args=(url,),
            kwargs={"kind_hint": kind_hint, "max_items": int(cfg.get("max_items_per_feed", 10))},
            job_id=f"poll:rss:{url}",
            ttl=600, result_ttl=0, failure_ttl=900,
        )
        print("enqueued", job.id)
        total += 1

    print("enqueued total:", total)

if __name__ == "__main__":
    main()
