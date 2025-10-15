from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
from .config import settings

app = FastAPI(title="CinePulse API", version="0.1.0")

class Story(BaseModel):
    id: str
    kind: str  # trailer|release|ott|bo|award
    title: str
    summary: str | None = None
    published_at: datetime | None = None
    source: str | None = None
    thumb_url: str | None = None

@app.get("/health")
def health():
    return {"status": "ok", "env": settings.env, "ts": datetime.utcnow().isoformat() + "Z"}

@app.get("/v1/feed")
def feed(tab: str = "all", since: str | None = None):
    # Stub: wire real data later
    return {"tab": tab, "since": since, "items": []}

@app.get("/v1/search")
def search(q: str):
    return {"q": q, "items": []}
