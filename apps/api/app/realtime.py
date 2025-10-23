# apps/api/realtime.py
from __future__ import annotations
import asyncio, json, os, signal
from typing import AsyncIterator

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse

from redis.asyncio import Redis as AsyncRedis

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
HEARTBEAT_SEC = int(os.getenv("SSE_HEARTBEAT_SEC", "20"))

router = APIRouter(prefix="/v1/realtime", tags=["realtime"])

def _redis() -> AsyncRedis:
    return AsyncRedis.from_url(REDIS_URL, decode_responses=True)

# -------- SSE (Server-Sent Events): GET /v1/realtime/stream --------
async def _event_source() -> AsyncIterator[bytes]:
    """
    Simple SSE stream fed from Redis Stream + heartbeat.
    Each item is a small JSON with id/kind/ts, enough to prompt clients to refetch.
    """
    r = _redis()
    try:
        last_id = "$"  # start at newest; switch to 0-0 to backfill if you want
        heartbeat = 0
        while True:
            # XREAD BLOCK waits for new items ~ 15s
            items = await r.xread({FEED_STREAM: last_id}, block=15000, count=20)
            if items:
                for _, msgs in items:
                    for msg_id, kv in msgs:
                        last_id = msg_id
                        data = json.dumps({"id": kv.get("id"), "kind": kv.get("kind"), "ts": kv.get("ts")})
                        yield f"event: feed\n".encode()
                        yield f"data: {data}\n\n".encode()
                        heartbeat = 0
            else:
                # heartbeat to keep proxies/lb happy
                heartbeat += 1
                if heartbeat * 15 >= HEARTBEAT_SEC:
                    yield b": keep-alive\n\n"
                    heartbeat = 0
    finally:
        await r.aclose()

@router.get("/stream")
async def sse_stream() -> StreamingResponse:
    return StreamingResponse(_event_source(), media_type="text/event-stream")

# -------- WebSocket: ws://.../v1/realtime/ws --------
@router.websocket("/ws")
async def ws_feed(ws: WebSocket):
    await ws.accept()
    r = _redis()
    pubsub = r.pubsub()
    await pubsub.subscribe(FEED_PUBSUB)

    async def _pinger():
        while True:
            try:
                await ws.send_text('{"type":"ping"}')
            except Exception:
                break
            await asyncio.sleep(25)

    ping_task = asyncio.create_task(_pinger())
    try:
        while True:
            message = await pubsub.get_message(ignore_subscribe_messages=True, timeout=15.0)
            if message and message.get("type") == "message":
                await ws.send_text(message["data"])  # already JSON from jobs.py
            # also allow client to close
            try:
                _ = await asyncio.wait_for(ws.receive_text(), timeout=0.01)
            except (asyncio.TimeoutError, WebSocketDisconnect):
                pass
    except WebSocketDisconnect:
        pass
    finally:
        ping_task.cancel()
        with contextlib.suppress(Exception):
            await pubsub.unsubscribe(FEED_PUBSUB)
            await pubsub.close()
            await r.aclose()
