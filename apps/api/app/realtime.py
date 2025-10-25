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

"""
REALTIME CONTRACT

Sanitizer (apps/sanitizer/sanitizer.py) is the single writer to:
  - Redis Pub/Sub channel FEED_PUBSUB
  - Redis Stream FEED_STREAM

When a NEW story is ACCEPTED into the feed, sanitizer does:
    conn.publish(FEED_PUBSUB, json.dumps({
        "id": story["id"],
        "kind": story["kind"],
        "normalized_at": story["normalized_at"],
        "ingested_at": story["ingested_at"],
        "title": story["title"],
        "source": story["source"],
        "source_domain": story["source_domain"],
        "url": story["url"],
        "thumb_url": story["thumb_url"],
    }))

    conn.xadd(FEED_STREAM, {
        "id": story["id"],
        "kind": story["kind"],
        "ts": story["normalized_at"],
    }, ...)

We expose two realtime surfaces to clients:
  1. /v1/realtime/stream  (Server-Sent Events / SSE)
     -> emits lightweight "feed" events from FEED_STREAM and also heartbeats.
     -> each event has {id, kind, ts} so the client knows "new stuff landed,
        go hit /v1/feed again".
  2. /v1/realtime/ws      (WebSocket)
     -> subscribes to FEED_PUBSUB and forwards each published JSON payload.
     -> this payload is richer (title, thumb_url, etc.) and is already JSON.

NOTE:
- Story objects in Redis now include `verticals`, `kind_meta`, etc., but we
  don't *need* those in the realtime ping to tell the client to refetch.
  We keep this channel lightweight.
- The API /v1/feed already supports `?vertical=` and will filter stories
  based on story["verticals"], so clients can refetch with whatever vertical
  tab they're on after they receive a realtime ping.
"""

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FEED_PUBSUB = os.getenv("FEED_PUBSUB", "feed:pub")
FEED_STREAM = os.getenv("FEED_STREAM", "feed:stream")
HEARTBEAT_SEC = int(os.getenv("SSE_HEARTBEAT_SEC", "20"))

router = APIRouter(prefix="/v1/realtime", tags=["realtime"])


def _redis() -> AsyncRedis:
    """
    Build a single-use async Redis client.
    Caller is responsible for closing it (aclose()).
    """
    return AsyncRedis.from_url(
        REDIS_URL,
        decode_responses=True,
    )


# -----------------------------------------------------------------------------
# SSE (Server-Sent Events)
# -----------------------------------------------------------------------------

async def _event_source() -> AsyncIterator[bytes]:
    """
    Yield an endless text/event-stream response.

    Implementation details:
    - We tail FEED_STREAM via XREAD with a blocking timeout.
    - Each new entry gets turned into an SSE "feed" event that looks like:
          event: feed
          data: {"type":"feed","id":"rss:koimoi:abc123","kind":"news","ts":"2025-10-25T12:34:56Z"}

      `id`      -> story.id
      `kind`    -> story.kind ("trailer", "release", "ott", "news", ...)
      `ts`      -> story.normalized_at (what sanitizer stored as "ts")

    - Between messages we also emit a heartbeat comment:
          : keep-alive

      so that proxies / CDNs don't kill the connection when it's quiet.

    Contract for clients:
    - Treat ANY "feed" event as "the feed changed; call /v1/feed again
      with your active tab/vertical to pull fresh items."
    - Ignore/comment lines that start with ":" (they're heartbeats).
    """
    r = _redis()
    try:
        # "$" means "start from the latest entry going forward (no replay)".
        # Use "0-0" if you ever want to offer historical replay instead.
        last_id = "$"

        # We'll XREAD with a ~15s block; we'll send a manual heartbeat if we've
        # been quiet for HEARTBEAT_SEC seconds.
        block_ms = 15_000
        heartbeat_elapsed = 0.0

        while True:
            # XREAD returns: [ (stream_name, [ (msg_id, {field:val,...}), ... ]) ]
            items = await r.xread(
                {FEED_STREAM: last_id},
                block=block_ms,
                count=20,
            )

            if items:
                for _, msgs in items:
                    for msg_id, kv in msgs:
                        last_id = msg_id

                        payload = {
                            "type": "feed",
                            "id": kv.get("id"),
                            "kind": kv.get("kind"),
                            "ts": kv.get("ts"),
                        }

                        # Standard SSE frame:
                        #  - "event:" lets client filter specific event types
                        #  - "data:" is one line of JSON
                        yield b"event: feed\n"
                        yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode()

                        heartbeat_elapsed = 0.0
            else:
                # No new story within block, send heartbeat if overdue
                heartbeat_elapsed += block_ms / 1000.0
                if heartbeat_elapsed >= HEARTBEAT_SEC:
                    # A comment line in SSE starts with ':'
                    yield b": keep-alive\n\n"
                    heartbeat_elapsed = 0.0

    finally:
        await r.aclose()


@router.get(
    "/stream",
    summary="Server-Sent Events stream of new feed activity",
    description=(
        "SSE stream that pushes lightweight 'feed' events whenever a new story "
        "is accepted. Clients should refetch /v1/feed (with their current "
        "vertical/tab params) when they get an event. Includes heartbeat "
        "comments to keep the connection alive."
    ),
)
async def sse_stream() -> StreamingResponse:
    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        # Disable proxy buffering (esp. nginx) so events flush immediately
        "X-Accel-Buffering": "no",
    }
    return StreamingResponse(
        _event_source(),
        media_type="text/event-stream",
        headers=headers,
    )


# -----------------------------------------------------------------------------
# WebSocket
# -----------------------------------------------------------------------------

@router.websocket("/ws")
async def ws_feed(ws: WebSocket):
    """
    WebSocket variant of realtime.

    Flow:
    - Accept client.
    - Subscribe to Redis Pub/Sub FEED_PUBSUB.
    - Whenever sanitizer publishes a new story payload (JSON dict with id,
      title, thumb_url, etc.), forward that JSON as text.
    - Also send periodic {"type":"ping"} so infra doesn't kill idle sockets.

    NOTE:
    - Unlike SSE, Pub/Sub messages already include richer info like title,
      thumb_url, source_domain, etc. We forward that directly.
    - Client is still expected to re-pull /v1/feed if they care about
      ordering/filtering, because the pubsub ping doesn't include the full
      normalized object with all fields (verticals, kind_meta, etc.).
    """
    await ws.accept()

    # Let client know socket is alive right away.
    with contextlib.suppress(Exception):
        await ws.send_text('{"type":"hello"}')

    r = _redis()
    pubsub = r.pubsub()
    await pubsub.subscribe(FEED_PUBSUB)

    async def _pinger():
        # background task: send a ping every 25s
        while True:
            try:
                await ws.send_text('{"type":"ping"}')
            except Exception:
                break
            await asyncio.sleep(25)

    ping_task = asyncio.create_task(_pinger())

    try:
        while True:
            # Pull one message from Redis pubsub with timeout so we can also
            # watch for client disconnect without blocking forever.
            message = await pubsub.get_message(
                ignore_subscribe_messages=True,
                timeout=15.0,
            )

            if message and message.get("type") == "message":
                # sanitizer published json.dumps(payload), so message["data"]
                # is already a JSON string. We forward that 1:1.
                with contextlib.suppress(Exception):
                    await ws.send_text(message["data"])

            # Check if the client sent anything / is still alive.
            # We don't currently act on client->server messages.
            try:
                _ = await asyncio.wait_for(ws.receive_text(), timeout=0.01)
            except asyncio.TimeoutError:
                # totally fine, just means no inbound msg this tick
                pass
            except WebSocketDisconnect:
                break

    except WebSocketDisconnect:
        # normal close
        pass
    finally:
        # tear down ping loop
        ping_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await ping_task

        # clean up Redis resources
        with contextlib.suppress(Exception):
            await pubsub.unsubscribe(FEED_PUBSUB)
            await pubsub.close()
            await r.aclose()
