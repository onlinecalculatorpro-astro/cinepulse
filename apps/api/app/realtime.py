# apps/api/app/realtime.py
from __future__ import annotations

import asyncio
import contextlib
import json
import os
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


# ----------------------- SSE (Server-Sent Events) -----------------------
async def _event_source() -> AsyncIterator[bytes]:
    """
    Simple SSE stream fed from Redis Stream + heartbeat.
    Each item is a small JSON with id/kind/ts, enough to prompt clients to refetch.
    """
    r = _redis()
    try:
        last_id = "$"  # start at newest; use "0-0" if you want historical replay
        heartbeat_elapsed = 0
        block_ms = 15000

        while True:
            items = await r.xread({FEED_STREAM: last_id}, block=block_ms, count=20)
            if items:
                for _, msgs in items:
                    for msg_id, kv in msgs:
                        last_id = msg_id
                        data = json.dumps(
                            {
                                "type": "feed",
                                "id": kv.get("id"),
                                "kind": kv.get("kind"),
                                "ts": kv.get("ts"),
                            },
                            ensure_ascii=False,
                        )
                        yield b"event: feed\n"
                        yield f"data: {data}\n\n".encode()
                        heartbeat_elapsed = 0
            else:
                # heartbeat comment to keep connections alive through proxies/LB
                heartbeat_elapsed += block_ms / 1000
                if heartbeat_elapsed >= HEARTBEAT_SEC:
                    yield b": keep-alive\n\n"
                    heartbeat_elapsed = 0
    finally:
        await r.aclose()


@router.get("/stream")
async def sse_stream() -> StreamingResponse:
    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        # Helps with some reverse proxies (e.g., NGINX) to avoid buffering SSE
        "X-Accel-Buffering": "no",
    }
    return StreamingResponse(_event_source(), media_type="text/event-stream", headers=headers)


# ----------------------------- WebSocket --------------------------------
@router.websocket("/ws")
async def ws_feed(ws: WebSocket):
    await ws.accept()
    # send a tiny hello so the client knows the socket is ready
    with contextlib.suppress(Exception):
        await ws.send_text('{"type":"hello"}')

    r = _redis()
    pubsub = r.pubsub()
    await pubsub.subscribe(FEED_PUBSUB)

    async def _pinger():
        # periodic ping frame to keep intermediaries happy
        while True:
            try:
                await ws.send_text('{"type":"ping"}')
            except Exception:
                break
            await asyncio.sleep(25)

    ping_task = asyncio.create_task(_pinger())

    try:
        while True:
            # Pull from Redis pub/sub with a timeout so we can interleave WS checks
            message = await pubsub.get_message(ignore_subscribe_messages=True, timeout=15.0)
            if message and message.get("type") == "message":
                # message["data"] is already JSON (emitted by jobs.py)
                await ws.send_text(message["data"])

            # Detect client-initiated close without blocking the loop
            try:
                _ = await asyncio.wait_for(ws.receive_text(), timeout=0.01)
                # We don't need to do anything with incoming client text for now.
            except asyncio.TimeoutError:
                pass
            except WebSocketDisconnect:
                break
    except WebSocketDisconnect:
        pass
    finally:
        ping_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await ping_task
        with contextlib.suppress(Exception):
            await pubsub.unsubscribe(FEED_PUBSUB)
            await pubsub.close()
            await r.aclose()
