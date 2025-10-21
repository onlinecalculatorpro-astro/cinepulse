# apps/webhooks/main.py
"""
CinePulse Webhooks (WebSub push ingestion)
------------------------------------------
- YouTube WebSub (PubSubHubbub) verification + notifications
- Optional generic WebSub for RSS hubs
- (Best-effort) auto-subscribe on startup using your sources YAML

ENV (defaults align with docker-compose):
  PUBLIC_BASE_URL            e.g. https://hooks.example.com
  WEBHOOK_LEASE_SEC          default 86400 (24h)
  PUSH_HTTP_TIMEOUT          seconds, default 8.0
  USE_SOURCES_FILE           1/true to read YAML, default true
  SOURCES_FILE               default /app/source.yml
  AUTO_SUBSCRIBE_ON_START    1/true to subscribe enabled YT channels at boot
  YT_PULL_WINDOW_HOURS       fallback window; else read YAML youtube.defaults.published_after_hours or 72
  RSS_PULL_WINDOW_HOURS      default 48
  WEBHOOK_SHARED_SECRET      optional HMAC secret for generic WebSub (sha1/sha256)
"""
from __future__ import annotations

import base64
import hmac
import os
import logging
from datetime import datetime, timedelta, timezone
from hashlib import sha1, sha256
from typing import Optional, Any, Dict, List, Tuple

import httpx
from fastapi import FastAPI, BackgroundTasks, Request, Response, Query, HTTPException
from fastapi.responses import PlainTextResponse

# ----------------------------- logging -----------------------------
log = logging.getLogger("cinepulse.webhooks")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

# --------------------------- optional deps -------------------------
# YAML config (same file as scheduler).
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None  # type: ignore
    log.warning("PyYAML not installed; USE_SOURCES_FILE will be ignored.")

# Worker jobs (don’t crash if the module is missing in a slim deploy).
try:
    from apps.workers.jobs import youtube_rss_poll, rss_poll  # type: ignore
except Exception:  # pragma: no cover
    def youtube_rss_poll(channel_id: str, published_after: Optional[datetime] = None):  # type: ignore
        log.warning("youtube_rss_poll unavailable (workers not installed?) — noop")

    def rss_poll(url: str, kind_hint: str = "news"):  # type: ignore
        log.warning("rss_poll unavailable (workers not installed?) — noop")

# ----------------------------- app --------------------------------
app = FastAPI(title="CinePulse Webhooks (WebSub)", version="0.2.0")

# ----------------------------- config ------------------------------
def _truthy(s: Optional[str], default: bool = False) -> bool:
    if s is None:
        return default
    return s.strip().lower() in {"1", "true", "yes", "y", "on"}

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL")  # required for subscribe APIs
WEBHOOK_LEASE_SEC = int(os.getenv("WEBHOOK_LEASE_SEC", "86400"))
PUSH_HTTP_TIMEOUT = float(os.getenv("PUSH_HTTP_TIMEOUT", "8.0"))
WEBHOOK_SECRET = os.getenv("WEBHOOK_SHARED_SECRET")

USE_SOURCES_FILE = _truthy(os.getenv("USE_SOURCES_FILE", "true"), True)
SOURCES_FILE = os.getenv("SOURCES_FILE") or "/app/source.yml"

YT_PULL_WINDOW_HOURS_ENV = os.getenv("YT_PULL_WINDOW_HOURS")  # optional
RSS_PULL_WINDOW_HOURS = int(os.getenv("RSS_PULL_WINDOW_HOURS", "48"))

YOUTUBE_HUB = "https://pubsubhubbub.appspot.com"
YOUTUBE_TOPIC = "https://www.youtube.com/xml/feeds/videos.xml?channel_id={}"

# In-memory map for generic RSS WebSub (token -> (hub, topic, kind_hint))
SUBS: Dict[str, Tuple[str, str, str]] = {}

# ----------------------------- helpers -----------------------------
def _utc_now() -> datetime:
    return datetime.now(timezone.utc)

def _b64url(s: str) -> str:
    return base64.urlsafe_b64encode(s.encode("utf-8")).decode("ascii")

def _b64url_dec(s: str) -> str:
    return base64.urlsafe_b64decode(s.encode("ascii")).decode("utf-8")

async def _hub_subscribe(
    hub_url: str,
    topic_url: str,
    callback_url: str,
    *,
    lease_seconds: int = WEBHOOK_LEASE_SEC,
    secret: Optional[str] = None,
    mode: str = "subscribe",
) -> None:
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
        r = await cli.post(hub_url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
        r.raise_for_status()
    log.info("%s requested hub=%s topic=%s -> %s", mode.upper(), hub_url, topic_url, callback_url)

def _read_sources() -> Dict[str, Any]:
    if not (USE_SOURCES_FILE and yaml):
        return {}
    try:
        with open(SOURCES_FILE, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        log.warning("Could not read sources file %s: %r", SOURCES_FILE, e)
        return {}

def _enabled_yt_channel_ids(S: Dict[str, Any]) -> List[str]:
    out: List[str] = []
    yt_cfg = (S.get("youtube") or {})
    for ch in yt_cfg.get("channels") or []:
        if ch.get("enabled", True) and ch.get("channel_id"):
            out.append(str(ch["channel_id"]))
    return out

def _yt_default_window_from_yaml(S: Dict[str, Any]) -> int:
    try:
        def_ = ((S.get("youtube") or {}).get("defaults") or {})
        hrs = int(def_.get("published_after_hours", 72))
        return max(1, hrs)
    except Exception:
        return 72

def _yt_window_hours(S: Dict[str, Any]) -> int:
    if YT_PULL_WINDOW_HOURS_ENV:
        try:
            return max(1, int(YT_PULL_WINDOW_HOURS_ENV))
        except Exception:
            pass
    return _yt_default_window_from_yaml(S)

def _parse_sig(h: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    if not h:
        return None, None
    if "=" not in h:
        return None, None
    alg, hexd = h.split("=", 1)
    return alg.lower().strip(), hexd.strip()

def _verify_hub_signature(raw: bytes, headers: Dict[str, str]) -> bool:
    """Verify WebSub HMAC if a secret is configured. Supports 'X-Hub-Signature' (sha1=) and 'X-Hub-Signature-256' (sha256=)."""
    if not WEBHOOK_SECRET:
        return True
    # Prefer sha256 if present, else sha1
    for name in ("X-Hub-Signature-256", "X-Hub-Signature"):
        alg, hexd = _parse_sig(headers.get(name))
        if not alg or not hexd:
            continue
        if alg == "sha256":
            expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha256).hexdigest()
        elif alg == "sha1":
            expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha1).hexdigest()
        else:
            continue
        if hmac.compare_digest(hexd, expected):
            return True
        # If one header is present but wrong, fail fast.
        return False
    # Secret configured but no signature provided -> reject.
    return False

# -------------------------- startup: auto-subscribe -------------------------
@app.on_event("startup")
async def _startup_autosub() -> None:
    S = _read_sources()
    if not _truthy(os.getenv("AUTO_SUBSCRIBE_ON_START")):
        log.info("Startup: AUTO_SUBSCRIBE_ON_START disabled.")
        return
    if not PUBLIC_BASE_URL:
        log.warning("Startup: PUBLIC_BASE_URL not set; cannot auto-subscribe.")
        return
    cids = _enabled_yt_channel_ids(S)
    if not cids:
        log.info("Startup: no enabled YouTube channels found in sources.")
        return
    for cid in cids:
        try:
            cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
            await _hub_subscribe(YOUTUBE_HUB, YOUTUBE_TOPIC.format(cid), cb, lease_seconds=WEBHOOK_LEASE_SEC)
        except Exception as e:
            log.warning("Startup subscribe error channel=%s: %r", cid, e)

# -------------------------------- health -----------------------------------
@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    S = _read_sources()
    return {
        "status": "ok",
        "time": _utc_now().isoformat(),
        "sources_file": SOURCES_FILE,
        "yt_channels_enabled": len(_enabled_yt_channel_ids(S)),
        "yt_pull_window_hours": _yt_window_hours(S),
        "rss_pull_window_hours": RSS_PULL_WINDOW_HOURS,
        "public_base_url_set": bool(PUBLIC_BASE_URL),
    }

@app.get("/")
def root():
    return {"ok": True, "service": "cinepulse-webhooks"}

# -------------------------- YouTube subscribe API --------------------------
@app.post("/subscribe/yt")
async def subscribe_yt(channel_id: str = Query(..., min_length=6)) -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    await _hub_subscribe(YOUTUBE_HUB, YOUTUBE_TOPIC.format(channel_id), cb, lease_seconds=WEBHOOK_LEASE_SEC)
    return {"ok": True, "channel_id": channel_id, "callback": cb}

@app.post("/subscribe/yt/all")
async def subscribe_yt_all() -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    S = _read_sources()
    cids = _enabled_yt_channel_ids(S)
    ok, err = 0, 0
    for cid in cids:
        try:
            cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
            await _hub_subscribe(YOUTUBE_HUB, YOUTUBE_TOPIC.format(cid), cb, lease_seconds=WEBHOOK_LEASE_SEC)
            ok += 1
        except Exception as e:
            log.warning("subscribe all error channel=%s: %r", cid, e)
            err += 1
    return {"ok": True, "requested": len(cids), "subscribed": ok, "failed": err}

@app.post("/unsubscribe/yt")
async def unsubscribe_yt(channel_id: str = Query(..., min_length=6)) -> Dict[str, Any]:
    if not PUBLIC_BASE_URL:
        raise HTTPException(400, "PUBLIC_BASE_URL not set")
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    await _hub_subscribe(
        YOUTUBE_HUB, YOUTUBE_TOPIC.format(channel_id), cb, lease_seconds=WEBHOOK_LEASE_SEC, mode="unsubscribe"
    )
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
    log.info("YT VERIFY mode=%s lease=%s topic=%s channel=%s", hub_mode, hub_lease_seconds, hub_topic, channel_id)
    return PlainTextResponse(content=hub_challenge)

@app.post("/websub/yt/{channel_id}")
async def yt_notify(channel_id: str, request: Request, bg: BackgroundTasks) -> Response:
    raw = await request.body()
    # Optional signature check (YouTube usually does not sign).
    if not _verify_hub_signature(raw, {k: v for k, v in request.headers.items()}):
        log.warning("YT notify: signature verification failed")
        raise HTTPException(403, "invalid signature")

    # Best-effort log of the video ID (don’t fail on parsing).
    try:
        # Very small inline XML parse without global import to keep memory tiny.
        import xml.etree.ElementTree as ET  # local import
        ns = {"atom": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015"}
        root = ET.fromstring(raw.decode("utf-8", "ignore"))
        entry = root.find("atom:entry", ns)
        vid = entry.findtext("yt:videoId", default="", namespaces=ns) if entry is not None else ""
        log.info("YT NOTIFY channel=%s video=%s bytes=%d", channel_id, vid or "?", len(raw))
    except Exception:
        log.info("YT NOTIFY channel=%s bytes=%d (parse skipped)", channel_id, len(raw))

    # Trigger a short lookback poll to ingest fresh content
    S = _read_sources()
    hours = _yt_window_hours(S)
    since = _utc_now() - timedelta(hours=max(1, hours))

    def _run():
        try:
            youtube_rss_poll(channel_id, published_after=since)
        except Exception as e:
            log.warning("youtube_rss_poll error channel=%s: %r", channel_id, e)

    bg.add_task(_run)
    return Response(status_code=204)

# -------------------------- Generic RSS WebSub ------------------------------
def _rss_token(hub: str, topic: str) -> str:
    return _b64url(f"{hub}\n{topic}")

def _rss_unpack_token(token: str) -> Tuple[str, str]:
    hub, topic = _b64url_dec(token).split("\n", 1)
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
    log.info("RSS VERIFY token=%s mode=%s lease=%s topic=%s", token[:8], hub_mode, hub_lease_seconds, hub_topic)
    return PlainTextResponse(content=hub_challenge)

@app.post("/websub/rss/{token}")
async def rss_notify(token: str, request: Request, bg: BackgroundTasks) -> Response:
    raw = await request.body()
    if not _verify_hub_signature(raw, {k: v for k, v in request.headers.items()}):
        log.warning("RSS notify: signature verification failed")
        raise HTTPException(403, "invalid signature")

    hub, topic = _rss_unpack_token(token)
    _, _, kind_hint = SUBS.get(token, (hub, topic, "news"))
    log.info("RSS NOTIFY hub=%s topic=%s kind=%s bytes=%d", hub, topic, kind_hint, len(raw))

    def _run():
        try:
            # Keep parity with your worker signature (no published_after for RSS).
            rss_poll(topic, kind_hint=kind_hint)
        except Exception as e:
            log.warning("rss_poll error topic=%s: %r", topic, e)

    bg.add_task(_run)
    return Response(status_code=204)
