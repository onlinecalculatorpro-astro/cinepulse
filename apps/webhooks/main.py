# apps/webhooks/main.py
"""
CinePulse Webhooks (push ingestion)
-----------------------------------
- WebSub (PubSubHubbub) verification + notifications for YouTube
- Optional generic WebSub for RSS hubs that support it
- Reads SOURCES_FILE (same as scheduler) to auto-subscribe enabled channels

ENV (defaults match your compose style):
  PUBLIC_BASE_URL            public HTTPS base (e.g. https://hooks.example.com)
  WEBHOOK_LEASE_SEC          lease length for hub subscriptions (default 86400)
  PUSH_HTTP_TIMEOUT          HTTP hub timeout (default 8s)
  USE_SOURCES_FILE           1/true to read YAML (default true)
  SOURCES_FILE               path (default /app/source.yml)
  AUTO_SUBSCRIBE_ON_START    1/true to subscribe all enabled YT channels on startup
  YT_PULL_WINDOW_HOURS       override lookback on YT notify (else YAML youtube.defaults.published_after_hours or 72)
  RSS_PULL_WINDOW_HOURS      lookback for generic RSS push (default 48)
  WEBHOOK_SHARED_SECRET      optional HMAC secret for generic RSS WebSub (verifies X-Hub-Signature or X-Hub-Signature-256)

Routes:
  GET  /healthz
  POST /subscribe/yt?channel_id=UCxxxx
  POST /subscribe/yt/all
  POST /unsubscribe/yt?channel_id=UCxxxx
  GET  /websub/yt/{channel_id}   (hub verification)
  POST /websub/yt/{channel_id}   (hub notifications -> youtube_rss_poll)

  POST /subscribe/rss?hub=...&topic=...&kind_hint=news
  POST /unsubscribe/rss?hub=...&topic=...
  GET  /websub/rss/{token}        (hub verification)
  POST /websub/rss/{token}        (hub notifications -> rss_poll)
"""
from __future__ import annotations

import base64
import hmac
import os
from datetime import datetime, timedelta, timezone
from hashlib import sha1, sha256
from typing import Optional, Any, Dict, List, Tuple

import httpx
from fastapi import FastAPI, BackgroundTasks, Request, Response, Query, HTTPException
from fastapi.responses import PlainTextResponse
from xml.etree import ElementTree as ET

# Reuse the same jobs your scheduler calls
from apps.workers.jobs import youtube_rss_poll, rss_poll  # type: ignore

# Optional YAML (mirror scheduler behavior)
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore

app = FastAPI(title="CinePulse Webhooks (WebSub)", version="0.1.0")

# ----------------------------- Config -----------------------------

PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL")  # e.g., https://hooks.cinepulse.app
WEBHOOK_LEASE_SEC = int(os.environ.get("WEBHOOK_LEASE_SEC", "86400"))
PUSH_HTTP_TIMEOUT = float(os.environ.get("PUSH_HTTP_TIMEOUT", "8.0"))
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SHARED_SECRET")

USE_SOURCES_FILE = os.environ.get("USE_SOURCES_FILE", "true").lower() in ("1", "true", "yes")
SOURCES_FILE = os.environ.get("SOURCES_FILE") or "/app/source.yml"

YOUTUBE_HUB = "https://pubsubhubbub.appspot.com"
YOUTUBE_TOPIC = "https://www.youtube.com/xml/feeds/videos.xml?channel_id={}"

YT_PULL_WINDOW_HOURS_ENV = os.environ.get("YT_PULL_WINDOW_HOURS")
RSS_PULL_WINDOW_HOURS = int(os.environ.get("RSS_PULL_WINDOW_HOURS", "48"))

# In-memory map for generic RSS WebSub subscriptions (token -> (hub, topic, kind_hint))
SUBS: Dict[str, Tuple[str, str, str]] = {}

# ----------------------------- Utils ------------------------------

def _log(msg: str) -> None:
    print(f"[webhooks] {datetime.utcnow():%Y-%m-%d %H:%M:%S}Z  {msg}")

def _b64url(s: str) -> str:
    return base64.urlsafe_b64encode(s.encode("utf-8")).decode("ascii")

def _b64url_dec(s: str) -> str:
    return base64.urlsafe_b64decode(s.encode("ascii")).decode("utf-8")

def _utc_now() -> datetime:
    return datetime.now(timezone.utc)

async def _hub_subscribe(hub_url: str, topic_url: str, callback_url: str,
                         lease_seconds: int = WEBHOOK_LEASE_SEC,
                         secret: Optional[str] = None,
                         mode: str = "subscribe") -> None:
    data = {
        "hub.mode": mode,
        "hub.topic": topic_url,
        "hub.callback": callback_url,
        "hub.verify": "async",
        "hub.lease_seconds": str(lease_seconds),
    }
    if secret:
        data["hub.secret"] = secret
    async with httpx.AsyncClient(timeout=PUSH_HTTP_TIMEOUT) as cli:
        r = await cli.post(
            hub_url,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        r.raise_for_status()
    _log(f"{mode.upper()} requested hub={hub_url} topic={topic_url} -> {callback_url}")

def _read_sources() -> Dict[str, Any]:
    if not USE_SOURCES_FILE or not yaml:
        return {}
    try:
        with open(SOURCES_FILE, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        _log(f"Could not read sources file '{SOURCES_FILE}': {e!r}")
        return {}

def _enabled_yt_channel_ids(S: Dict[str, Any]) -> List[str]:
    out: List[str] = []
    yt_cfg = (S.get("youtube") or {})
    channels = yt_cfg.get("channels") or []
    for ch in channels:
        if not ch.get("enabled", True):
            continue
        cid = ch.get("channel_id")
        if cid:
            out.append(str(cid))
    return out

def _yt_default_window_from_yaml(S: Dict[str, Any]) -> int:
    try:
        d = ((S.get("youtube") or {}).get("defaults") or {})
        hrs = d.get("published_after_hours")
        return int(hrs) if hrs is not None else 72
    except Exception:
        return 72

def _yt_window_hours(S: Dict[str, Any]) -> int:
    if YT_PULL_WINDOW_HOURS_ENV:
        try:
            return int(YT_PULL_WINDOW_HOURS_ENV)
        except Exception:
            pass
    return _yt_default_window_from_yaml(S)

def _verify_hub_signature(raw: bytes, headers: Dict[str, str]) -> bool:
    """Verify WebSub HMAC if secret configured. Supports sha1= and sha256=."""
    if not WEBHOOK_SECRET:
        return True
    sig = headers.get("X-Hub-Signature") or headers.get("X-Hub-Signature-256") or ""
    sig = sig.strip()
    if sig.startswith("sha1="):
        expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha1).hexdigest()
        return hmac.compare_digest(sig[4+1:], expected)
    if sig.startswith("sha256="):
        expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha256).hexdigest()
        return hmac.compare_digest(sig[7+1:], expected)
    # Secret configured but no signature -> reject
    return False

# -------------------------- Startup: auto-subscribe -------------------------

@app.on_event("startup")
async def _startup() -> None:
    S = _read_sources()

    auto_sub = os.environ.get("AUTO_SUBSCRIBE_ON_START", "false").lower() in ("1", "true", "yes")
    if not auto_sub:
        _log("Startup: AUTO_SUBSCRIBE_ON_START disabled.")
        return
    if not PUBLIC_BASE_URL:
        _log("Startup: PUBLIC_BASE_URL not set; cannot subscribe. Skipping.")
        return

    cids = _enabled_yt_channel_ids(S)
    if not cids:
        _log("Startup: no enabled YouTube channels in sources.")
        return

    for cid in cids:
        try:
            cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
            topic = YOUTUBE_TOPIC.format(cid)
            await _hub_subscribe(YOUTUBE_HUB, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC)
        except Exception as e:
            _log(f"Startup subscribe error channel={cid}: {e!r}")

# ------------------------------ Health -------------------------------------

@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    S = _read_sources()
    return {
        "status": "ok",
        "time": datetime.utcnow().isoformat() + "Z",
        "sources_file": SOURCES_FILE,
        "yt_channels_enabled": len(_enabled_yt_channel_ids(S)),
        "yt_pull_window_hours": _yt_window_hours(S),
        "rss_pull_window_hours": RSS_PULL_WINDOW_HOURS,
    }

# -------------------------- YouTube subscribe API --------------------------

@app.post("/subscribe/yt")
async def subscribe_yt(channel_id: str = Query(..., min_length=6)) -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    topic = YOUTUBE_TOPIC.format(channel_id)
    await _hub_subscribe(YOUTUBE_HUB, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC)
    return {"ok": True, "channel_id": channel_id, "callback": cb}

@app.post("/subscribe/yt/all")
async def subscribe_yt_all() -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    S = _read_sources()
    cids = _enabled_yt_channel_ids(S)
    for cid in cids:
        cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
        topic = YOUTUBE_TOPIC.format(cid)
        try:
            await _hub_subscribe(YOUTUBE_HUB, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC)
        except Exception as e:
            _log(f"subscribe all error for channel={cid}: {e!r}")
    return {"ok": True, "count": len(cids)}

@app.post("/unsubscribe/yt")
async def unsubscribe_yt(channel_id: str = Query(..., min_length=6)) -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    topic = YOUTUBE_TOPIC.format(channel_id)
    await _hub_subscribe(YOUTUBE_HUB, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC, mode="unsubscribe")
    return {"ok": True, "channel_id": channel_id, "callback": cb}

# -------------------------- YouTube WebSub callbacks -----------------------

@app.get("/websub/yt/{channel_id}")
def yt_verify(
    channel_id: str,
    hub_mode: str = Query(alias="hub.mode"),
    hub_challenge: str = Query(alias="hub.challenge"),
    hub_lease_seconds: Optional[int] = Query(None, alias="hub.lease_seconds"),
    hub_topic: Optional[str] = Query(None, alias="hub.topic"),
) -> Response:
    _log(f"YT VERIFY mode={hub_mode} ch={hub_challenge[:8]}.. lease={hub_lease_seconds} topic={hub_topic}")
    # Echo back challenge as required by WebSub
    return PlainTextResponse(content=hub_challenge)

@app.post("/websub/yt/{channel_id}")
async def yt_notify(channel_id: str, request: Request, bg: BackgroundTasks) -> Response:
    raw = await request.body()
    # YouTube doesn't sign; generic hubs might. We still allow optional HMAC check.
    if not _verify_hub_signature(raw, {k: v for k, v in request.headers.items()}):
        _log("YT notify: signature verification failed")
        raise HTTPException(403, "invalid signature")

    # Best-effort parse to log the video id (not required for our worker call)
    try:
        root = ET.fromstring(raw.decode("utf-8", "ignore"))
        ns = {"atom": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015"}
        entry = root.find("atom:entry", ns)
        vid = entry.findtext("yt:videoId", default="", namespaces=ns) if entry is not None else ""
        _log(f"YT NOTIFY channel={channel_id} video={vid or '?'} bytes={len(raw)}")
    except Exception:
        _log(f"YT NOTIFY channel={channel_id} bytes={len(raw)} (parse skipped)")

    # Trigger a tight lookback poll to ingest the fresh item
    S = _read_sources()
    hrs = _yt_window_hours(S)
    since = _utc_now() - timedelta(hours=max(1, hrs))  # never zero
    def _run():
        try:
            youtube_rss_poll(channel_id, published_after=since)
        except Exception as e:
            _log(f"youtube_rss_poll error channel={channel_id}: {e!r}")
    bg.add_task(_run)

    return Response(status_code=204)

# -------------------------- Generic RSS WebSub (optional) -------------------

def _rss_token(hub: str, topic: str) -> str:
    return _b64url(f"{hub}\n{topic}")

def _rss_unpack_token(token: str) -> Tuple[str, str]:
    s = _b64url_dec(token)
    hub, topic = s.split("\n", 1)
    return hub, topic

@app.post("/subscribe/rss")
async def subscribe_rss(hub: str, topic: str, kind_hint: str = "news") -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    token = _rss_token(hub, topic)
    SUBS[token] = (hub, topic, kind_hint)
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/rss/{token}"
    await _hub_subscribe(hub, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC, secret=WEBHOOK_SECRET)
    return {"ok": True, "callback": cb, "token": token, "kind_hint": kind_hint}

@app.post("/unsubscribe/rss")
async def unsubscribe_rss(hub: str, topic: str) -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    token = _rss_token(hub, topic)
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/rss/{token}"
    await _hub_subscribe(hub, topic, cb, lease_seconds=WEBHOOK_LEASE_SEC, mode="unsubscribe", secret=WEBHOOK_SECRET)
    SUBS.pop(token, None)
    return {"ok": True}

@app.get("/websub/rss/{token}")
def rss_verify(
    token: str,
    hub_mode: str = Query(alias="hub.mode"),
    hub_challenge: str = Query(alias="hub.challenge"),
    hub_lease_seconds: Optional[int] = Query(None, alias="hub.lease_seconds"),
    hub_topic: Optional[str] = Query(None, alias="hub.topic"),
) -> Response:
    _log(f"RSS VERIFY token={token[:8]}.. mode={hub_mode} lease={hub_lease_seconds} topic={hub_topic}")
    return PlainTextResponse(content=hub_challenge)

@app.post("/websub/rss/{token}")
async def rss_notify(token: str, request: Request, bg: BackgroundTasks) -> Response:
    raw = await request.body()
    if not _verify_hub_signature(raw, {k: v for k, v in request.headers.items()}):
        _log("RSS notify: signature verification failed")
        raise HTTPException(403, "invalid signature")

    hub, topic = _rss_unpack_token(token)
    _, _, kind_hint = SUBS.get(token, (hub, topic, "news"))
    _log(f"RSS NOTIFY hub={hub} topic={topic} kind={kind_hint} bytes={len(raw)}")

    # Kick a quick poll to ingest latest
    since = _utc_now() - timedelta(hours=max(1, RSS_PULL_WINDOW_HOURS))
    def _run():
        try:
            # rss_poll signature in your scheduler doesn't take 'published_after';
            # keep parity with jobs.rss_poll(url, kind_hint, max_items?)
            rss_poll(topic, kind_hint=kind_hint)
        except Exception as e:
            _log(f"rss_poll error topic={topic}: {e!r}")
    bg.add_task(_run)

    return Response(status_code=204)
