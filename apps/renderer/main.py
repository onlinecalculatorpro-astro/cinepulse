from fastapi import FastAPI
import os, redis

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FEED_KEY  = os.getenv("FEED_KEY", "feed:items")
r = redis.from_url(REDIS_URL, decode_responses=True)

app = FastAPI(title="CinePulse Renderer", version="0.1.0")

@app.get("/health")
def health():
    try:
        feed_len = r.llen(FEED_KEY)
        return {"status":"ok","redis":REDIS_URL,"feed_key":FEED_KEY,"feed_len":feed_len}
    except Exception as e:
        return {"status":"degraded","error":str(e)}
