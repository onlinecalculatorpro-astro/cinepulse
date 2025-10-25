# apps/webhooks/main.py
#
# CinePulse Webhooks (WebSub push ingestion)
# -----------------------------------------
# This service exposes public callback URLs that hubs (like YouTube's
# PubSubHubbub) POST to when there's new content.
#
# Flow:
#   - Hubs send us a verification GET -> we respond with the challenge.
#   - Later they POST us a notification -> we trigger a short lookback poll
#     (youtube_rss_poll / rss_poll) to enqueue fresh items into RQ.
#
# CRITICAL:
# - We DO NOT write to the public feed list here.
# - We DO NOT dedupe here.
# - We just nudge the "scheduler → workers → sanitizer" pipeline.
#
# Features:
#   - YouTube WebSub subscribe/unsubscribe helpers
#   - Generic RSS WebSub subscribe/unsubscribe
#   - Optional auto-subscribe to all YouTube channels on startup
#   - Optional HMAC validation of incoming POSTs (X-Hub-Signature / ...-256)
#
# ENV:
#   PUBLIC_BASE_URL            e.g. https://hooks.example.com (required to subscribe)
#   WEBHOOK_LEASE_SEC          lease for hub subscription (default 86400)
#   PUSH_HTTP_TIMEOUT          timeout for hub subscribe calls (default 8.0)
#   WEBHOOK_SHARED_SECRET      if set, verify X-Hub-Signature / X-Hub-Signature-256
#
#   USE_SOURCES_FILE           default "true"
#   SOURCES_FILE               default /app/infra/source.yml
#   AUTO_SUBSCRIBE_ON_START    "1"/"true"/"yes" to auto-sub all enabled YT channels at boot
#
#   YT_PULL_WINDOW_HOURS       override YouTube lookback window on notify (else YAML youtube.defaults.published_after_hours or 72)
#   RSS_PULL_WINDOW_HOURS      default 48 (how far back we consider RSS "fresh" if we ever add cutoff logic)
#
# Endpoints:
#   GET  /healthz
#   POST /subscribe/yt
#   POST /subscribe/yt/all
#   POST /unsubscribe/yt
#   GET  /websub/yt/{channel_id}      (hub.verify)
#   POST /websub/yt/{channel_id}      (hub.notify)
#
#   POST /subscribe/rss
#   POST /unsubscribe/rss
#   GET  /websub/rss/{token}          (hub.verify)
#   POST /websub/rss/{token}          (hub.notify)
#
# NOTE:
# - We *don't* expose push delivery to clients. That's the /v1/push API in api/.
# - This service only exists so hubs can poke us directly instead of us polling on a fixed timer.


from __future__ import annotations

import base64
import contextlib
import hmac
import logging
import os
from datetime import datetime, timedelta, timezone
from hashlib import sha1, sha256
from typing import Any, Dict, List, Optional, Tuple

import httpx
from fastapi import (
    BackgroundTasks,
    FastAPI,
    HTTPException,
    Query,
    Request,
    Response,
)
from fastapi.responses import PlainTextResponse

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------

log = logging.getLogger("cinepulse.webhooks")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)


def _log(msg: str) -> None:
    # keep this consistent with scheduler/main.py style of timestamped logs
    ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
    log.info("[webhooks] %sZ  %s", ts, msg)


# ---------------------------------------------------------------------------
# optional deps
# ---------------------------------------------------------------------------

# YAML config (shared with scheduler/main.py; drives which YT channels exist)
try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None
    _log("PyYAML not installed; USE_SOURCES_FILE will be ignored.")

# Worker pollers (nudge the pipeline). If they aren't importable in this
# environment, we provide harmless stubs so the service can still boot.
try:
    from apps.workers.jobs import youtube_rss_poll, rss_poll  # type: ignore
except Exception:  # pragma: no cover
    def youtube_rss_poll(channel_id: str, published_after: Optional[datetime] = None):  # type: ignore
        _log("youtube_rss_poll unavailable (workers not installed?) — noop")

    def rss_poll(url: str, kind_hint: str = "news"):  # type: ignore
        _log("rss_poll unavailable (workers not installed?) — noop")


# ---------------------------------------------------------------------------
# environment config
# ---------------------------------------------------------------------------

def _truthy(val: Optional[str], default: bool = False) -> bool:
    if val is None:
        return default
    return val.strip().lower() in {"1", "true", "yes", "y", "on"}


PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL")  # REQUIRED for subscribe endpoints
WEBHOOK_LEASE_SEC = int(os.getenv("WEBHOOK_LEASE_SEC", "86400"))

PUSH_HTTP_TIMEOUT = float(os.getenv("PUSH_HTTP_TIMEOUT", "8.0"))

WEBHOOK_SECRET = os.getenv("WEBHOOK_SHARED_SECRET")

USE_SOURCES_FILE = _truthy(os.getenv("USE_SOURCES_FILE", "true"), True)

# keep same path convention as scheduler/main.py
SOURCES_FILE = os.getenv("SOURCES_FILE") or "/app/infra/source.yml"

YT_PULL_WINDOW_HOURS_ENV = os.getenv("YT_PULL_WINDOW_HOURS")  # optional override
RSS_PULL_WINDOW_HOURS = int(os.getenv("RSS_PULL_WINDOW_HOURS", "48"))

# YouTube hub constants
YOUTUBE_HUB = "https://pubsubhubbub.appspot.com"
YOUTUBE_TOPIC = "https://www.youtube.com/xml/feeds/videos.xml?channel_id={}"

# For generic WebSub RSS. We keep a tiny in-memory map:
# token -> (hub, topic, kind_hint)
SUBS: Dict[str, Tuple[str, str, str]] = {}


# ---------------------------------------------------------------------------
# tiny utils
# ---------------------------------------------------------------------------

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
    """
    Ask the hub to (un)subscribe us.
    'hub.verify=async' means the hub will hit our GET callback
    to confirm, sending hub.challenge.
    """
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
    """
    Load the same YAML scheduler uses, so we know:
    - which YouTube channels are enabled
    - youtube.defaults.published_after_hours
    """
    if not (USE_SOURCES_FILE and yaml):
        return {}
    try:
        with open(SOURCES_FILE, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except Exception as e:
        _log(f"Could not read sources file {SOURCES_FILE}: {e!r}")
        return {}


def _enabled_yt_channel_ids(S: Dict[str, Any]) -> List[str]:
    """
    Pull all enabled youtube.channels[].channel_id from the YAML.
    """
    out: List[str] = []
    yt_cfg = (S.get("youtube") or {})
    for ch in yt_cfg.get("channels") or []:
        if ch.get("enabled", True) and ch.get("channel_id"):
            out.append(str(ch["channel_id"]))
    return out


def _yt_default_window_from_yaml(S: Dict[str, Any]) -> int:
    """
    Fallback lookback for youtube_rss_poll() after a webhook notify.
    If youtube.defaults.published_after_hours exists in YAML we respect it,
    else default 72h.
    """
    try:
        defaults = ((S.get("youtube") or {}).get("defaults") or {})
        hrs = int(defaults.get("published_after_hours", 72))
        return max(1, hrs)
    except Exception:
        return 72


def _yt_window_hours(S: Dict[str, Any]) -> int:
    """
    Resolve effective "lookback hours" window to pass into youtube_rss_poll.
    Priority: env YT_PULL_WINDOW_HOURS > YAML youtube.defaults.published_after_hours > 72
    """
    if YT_PULL_WINDOW_HOURS_ENV:
        with contextlib.suppress(Exception):
            return max(1, int(YT_PULL_WINDOW_HOURS_ENV))
    return _yt_default_window_from_yaml(S)


def _parse_sig(h: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """
    Parse "sha1=<hex>" / "sha256=<hex>" into (alg, hex).
    """
    if not h or "=" not in h:
        return None, None
    alg, hexd = h.split("=", 1)
    return alg.lower().strip(), hexd.strip()


def _verify_hub_signature(raw: bytes, headers: Dict[str, str]) -> bool:
    """
    If WEBHOOK_SECRET is set:
      - Require X-Hub-Signature-256 or X-Hub-Signature
      - Validate HMAC
    If WEBHOOK_SECRET is NOT set:
      - Always allow (because YouTube doesn't sign by default).
    """
    if not WEBHOOK_SECRET:
        return True

    for name in ("X-Hub-Signature-256", "X-Hub-Signature"):
        alg, hexd = _parse_sig(headers.get(name))
        if not alg or not hexd:
            continue

        if alg == "sha256":
            expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha256).hexdigest()
        elif alg == "sha1":
            expected = hmac.new(WEBHOOK_SECRET.encode(), raw, sha1).hexdigest()
        else:
            # Unknown alg -> reject
            return False

        return hmac.compare_digest(hexd, expected)

    # Secret configured but no signature provided -> reject.
    return False


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="CinePulse Webhooks (WebSub)",
    version="0.2.0",
    description="Hub callbacks (YouTube / generic WebSub) that trigger on-demand ingest.",
)


# ---------------------------------------------------------------------------
# startup: optional auto-subscribe to all configured YT channels
# ---------------------------------------------------------------------------

@app.on_event("startup")
async def _startup_autosub() -> None:
    """
    If AUTO_SUBSCRIBE_ON_START=1 and PUBLIC_BASE_URL is set:
    - Iterate enabled YouTube channels from sources YAML
    - Ask the YouTube hub to subscribe each channel to our callback URL
    """
    if not _truthy(os.getenv("AUTO_SUBSCRIBE_ON_START")):
        _log("Startup: AUTO_SUBSCRIBE_ON_START disabled.")
        return

    if not PUBLIC_BASE_URL:
        _log("Startup: PUBLIC_BASE_URL not set; cannot auto-subscribe.")
        return

    S = _read_sources()
    cids = _enabled_yt_channel_ids(S)
    if not cids:
        _log("Startup: no enabled YouTube channels found in sources.")
        return

    for cid in cids:
        try:
            cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
            await _hub_subscribe(
                YOUTUBE_HUB,
                YOUTUBE_TOPIC.format(cid),
                cb,
                lease_seconds=WEBHOOK_LEASE_SEC,
            )
        except Exception as e:
            _log(f"Startup subscribe error channel={cid}: {e!r}")


# ---------------------------------------------------------------------------
# health + root
# ---------------------------------------------------------------------------

@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    """
    Basic liveness/debug info.
    """
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


# ---------------------------------------------------------------------------
# YouTube subscribe / unsubscribe management
# ---------------------------------------------------------------------------

@app.post("/subscribe/yt")
async def subscribe_yt(
    channel_id: str = Query(..., min_length=6, description="YouTube channel_id"),
) -> Dict[str, Any]:
    """
    Manual: subscribe THIS channel_id to WebSub so YouTube pushes us updates.
    """
    if not PUBLIC_BASE_URL:
        raise HTTPException(status_code=400, detail="PUBLIC_BASE_URL not set")

    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    await _hub_subscribe(
        YOUTUBE_HUB,
        YOUTUBE_TOPIC.format(channel_id),
        cb,
        lease_seconds=WEBHOOK_LEASE_SEC,
    )
    return {"ok": True, "channel_id": channel_id, "callback": cb}


@app.post("/subscribe/yt/all")
async def subscribe_yt_all() -> Dict[str, Any]:
    """
    Bulk: subscribe ALL enabled channels from sources YAML.
    """
    if not PUBLIC_BASE_URL:
        raise HTTPException(status_code=400, detail="PUBLIC_BASE_URL not set")

    S = _read_sources()
    cids = _enabled_yt_channel_ids(S)
    sub_ok = 0
    sub_err = 0

    for cid in cids:
        try:
            cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{cid}"
            await _hub_subscribe(
                YOUTUBE_HUB,
                YOUTUBE_TOPIC.format(cid),
                cb,
                lease_seconds=WEBHOOK_LEASE_SEC,
            )
            sub_ok += 1
        except Exception as e:
            _log(f"subscribe all error channel={cid}: {e!r}")
            sub_err += 1

    return {
        "ok": True,
        "requested": len(cids),
        "subscribed": sub_ok,
        "failed": sub_err,
    }


@app.post("/unsubscribe/yt")
async def unsubscribe_yt(
    channel_id: str = Query(..., min_length=6, description="YouTube channel_id"),
) -> Dict[str, Any]:
    """
    Ask the hub to remove our callback for this channel.
    """
    if not PUBLIC_BASE_URL:
        raise HTTPException(status_code=400, detail="PUBLIC_BASE_URL not set")

    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/yt/{channel_id}"
    await _hub_subscribe(
        YOUTUBE_HUB,
        YOUTUBE_TOPIC.format(channel_id),
        cb,
        lease_seconds=WEBHOOK_LEASE_SEC,
        mode="unsubscribe",
    )
    return {"ok": True, "channel_id": channel_id, "callback": cb}


# ---------------------------------------------------------------------------
# YouTube WebSub callbacks (hub -> us)
# ---------------------------------------------------------------------------

@app.get("/websub/yt/{channel_id}")
def yt_verify(
    channel_id: str,
    hub_mode: str = Query(alias="hub.mode"),
    hub_challenge: str = Query(alias="hub.challenge"),
    hub_lease_seconds: Optional[int] = Query(None, alias="hub.lease_seconds"),
    hub_topic: Optional[str] = Query(None, alias="hub.topic"),
) -> Response:
    """
    Hub verification step:
    - The hub calls us with hub.mode=subscribe/unsubscribe and hub.challenge.
    - We must echo hub.challenge as plain text if we accept.
    """
    _log(
        f"YT VERIFY mode={hub_mode} lease={hub_lease_seconds} "
        f"topic={hub_topic} channel={channel_id}"
    )
    return PlainTextResponse(content=hub_challenge)


@app.post("/websub/yt/{channel_id}")
async def yt_notify(
    channel_id: str,
    request: Request,
    bg: BackgroundTasks,
) -> Response:
    """
    Hub notification step:
    - Hub POSTs us the Atom entry for a new/updated YouTube video.
    - We don't trust the payload alone. Instead we trigger a
      short lookback poll for that specific channel.
    """
    raw = await request.body()

    # Optional signature (YouTube usually doesn't sign — but we allow if present)
    if not _verify_hub_signature(raw, dict(request.headers)):
        _log("YT notify: signature verification failed")
        raise HTTPException(status_code=403, detail="invalid signature")

    # Best-effort debug: extract the videoId from the posted XML (if possible).
    try:
        import xml.etree.ElementTree as ET  # local import to keep memory small
        ns = {
            "atom": "http://www.w3.org/2005/Atom",
            "yt": "http://www.youtube.com/xml/schemas/2015",
        }
        root = ET.fromstring(raw.decode("utf-8", "ignore"))
        entry = root.find("atom:entry", ns)
        vid = entry.findtext("yt:videoId", default="", namespaces=ns) if entry is not None else ""
        _log(f"YT NOTIFY channel={channel_id} video={vid or '?'} bytes={len(raw)}")
    except Exception:
        _log(f"YT NOTIFY channel={channel_id} bytes={len(raw)} (parse skipped)")

    # Kick off a background poll with a recent cutoff window.
    S = _read_sources()
    hours = _yt_window_hours(S)
    since = _utc_now() - timedelta(hours=max(1, hours))

    def _run():
        try:
            youtube_rss_poll(channel_id, published_after=since)
        except Exception as e:
            _log(f"youtube_rss_poll error channel={channel_id}: {e!r}")

    bg.add_task(_run)
    return Response(status_code=204)


# ---------------------------------------------------------------------------
# Generic WebSub (RSS hub -> us)
# ---------------------------------------------------------------------------

def _rss_token(hub: str, topic: str) -> str:
    # pack hub+topic into a URL-safe token so our callback path can be stable
    return _b64url(f"{hub}\n{topic}")


def _rss_unpack_token(token: str) -> Tuple[str, str]:
    hub, topic = _b64url_dec(token).split("\n", 1)
    return hub, topic


@app.post("/subscribe/rss")
async def subscribe_rss(
    hub: str,
    topic: str,
    kind_hint: str = "news",
) -> Dict[str, Any]:
    """
    Manually subscribe to a generic WebSub hub for some RSS topic.
    We remember the token -> (hub, topic, kind_hint) mapping in-process.
    """
    if not PUBLIC_BASE_URL:
        raise HTTPException(status_code=400, detail="PUBLIC_BASE_URL not set")

    token = _rss_token(hub, topic)
    SUBS[token] = (hub, topic, kind_hint)

    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/rss/{token}"
    await _hub_subscribe(
        hub,
        topic,
        cb,
        lease_seconds=WEBHOOK_LEASE_SEC,
        secret=WEBHOOK_SECRET,
    )
    return {"ok": True, "callback": cb, "token": token, "kind_hint": kind_hint}


@app.post("/unsubscribe/rss")
async def unsubscribe_rss(
    hub: str,
    topic: str,
) -> Dict[str, Any]:
    """
    Manually unsubscribe from a generic WebSub RSS hub.
    """
    if not PUBLIC_BASE_URL:
        raise HTTPException(status_code=400, detail="PUBLIC_BASE_URL not set")

    token = _rss_token(hub, topic)
    cb = f"{PUBLIC_BASE_URL.rstrip('/')}/websub/rss/{token}"

    await _hub_subscribe(
        hub,
        topic,
        cb,
        lease_seconds=WEBHOOK_LEASE_SEC,
        mode="unsubscribe",
        secret=WEBHOOK_SECRET,
    )
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
    """
    Generic WebSub verification (same dance as YouTube's verify).
    """
    _log(
        f"RSS VERIFY token={token[:8]} mode={hub_mode} "
        f"lease={hub_lease_seconds} topic={hub_topic}"
    )
    return PlainTextResponse(content=hub_challenge)


@app.post("/websub/rss/{token}")
async def rss_notify(
    token: str,
    request: Request,
    bg: BackgroundTasks,
) -> Response:
    """
    Generic WebSub notification:
    - hub POSTs us the updated feed body
    - we background-trigger rss_poll(...) for that feed URL
    """
    raw = await request.body()

    if not _verify_hub_signature(raw, dict(request.headers)):
        _log("RSS notify: signature verification failed")
        raise HTTPException(status_code=403, detail="invalid signature")

    hub, topic = _rss_unpack_token(token)
    _hub, _topic, kind_hint = SUBS.get(token, (hub, topic, "news"))

    _log(
        f"RSS NOTIFY hub={hub} topic={topic} kind={kind_hint} bytes={len(raw)}"
    )

    def _run():
        try:
            # rss_poll doesn't take published_after; RSS feeds are usually tiny,
            # and sanitizer will dedupe anyway.
            rss_poll(topic, kind_hint=kind_hint)
        except Exception as e:
            _log(f"rss_poll error topic={topic}: {e!r}")

    bg.add_task(_run)
    return Response(status_code=204)
