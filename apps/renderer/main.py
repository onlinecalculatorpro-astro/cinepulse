# apps/renderer/main.py
#
# ROLE:
# - Lightweight renderer service
#   - /render-card : returns a 1200x628 PNG "share card" stub for a story
#   - /health      : simple liveness/readiness check + feed length
#
# NOTES:
# - This service does NOT read from the feed to render real story art yet.
#   It just draws a placeholder card. Frontend/social preview can still
#   hit this to get a valid PNG.
# - Pillow (PIL) must be installed in this container.
# - Redis is optional here; if Redis is down, /health returns "degraded"
#   but /render-card still works.

from __future__ import annotations

import os
import redis
from io import BytesIO
from datetime import datetime

from fastapi import FastAPI
from fastapi.responses import Response
from PIL import Image, ImageDraw, ImageFont

# -------------------------------------------------------------------
# Env / Redis
# -------------------------------------------------------------------

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
FEED_KEY = os.getenv("FEED_KEY", "feed:items")

# best-effort Redis client; if this fails at import time we'll handle later
try:
    r = redis.from_url(
        REDIS_URL,
        decode_responses=True,
        socket_timeout=float(os.getenv("REDIS_SOCKET_TIMEOUT", "2.0")),
        socket_connect_timeout=float(os.getenv("REDIS_CONNECT_TIMEOUT", "2.0")),
    )
except Exception:
    r = None  # health() will report degraded if we can't init


app = FastAPI(
    title="CinePulse Renderer",
    version="0.2.0",
    description="Generates share-card PNGs for stories and exposes a health probe.",
)


# -------------------------------------------------------------------
# /health
# -------------------------------------------------------------------

@app.get("/health")
def health():
    """
    Liveness / readiness probe for infra.
    Reports Redis reachability + feed length, but won't crash if Redis is down.
    """
    if r is None:
        return {
            "status": "degraded",
            "redis": REDIS_URL,
            "feed_key": FEED_KEY,
            "feed_len": None,
            "error": "redis-not-initialized",
        }

    try:
        feed_len = r.llen(FEED_KEY)
        return {
            "status": "ok",
            "redis": REDIS_URL,
            "feed_key": FEED_KEY,
            "feed_len": feed_len,
        }
    except Exception as e:
        return {
            "status": "degraded",
            "redis": REDIS_URL,
            "feed_key": FEED_KEY,
            "feed_len": None,
            "error": f"{type(e).__name__}: {e}",
        }


# -------------------------------------------------------------------
# /render-card
# -------------------------------------------------------------------

@app.post("/render-card")
def render_card(
    story_id: str = "demo",
    variant: str = "story",
):
    """
    Return a 1200x628 PNG "card". Right now it's a placeholder:
    dark background + debug text (story id, variant, timestamp).

    Later we can:
    - fetch story (title, poster) from Redis
    - lay out hero image, gradient, logo, etc.
    """
    W, H = 1200, 628
    bg_color = (18, 18, 24)        # near-black
    fg_color = (230, 230, 230)     # light gray text

    # base canvas
    img = Image.new("RGB", (W, H), bg_color)
    draw = ImageDraw.Draw(img)

    # timestamp (UTC, suffixed with Z)
    ts = datetime.utcnow().isoformat(timespec="seconds") + "Z"

    # Try to load a nicer font if we ever mount one in the container;
    # fall back to default PIL bitmap font if not available.
    # We do NOT fail render if custom font is missing.
    font = None
    try:
        # example future path: "/app/assets/Inter-SemiBold.ttf"
        font_path = os.getenv("CARD_FONT_PATH", "")
        if font_path:
            font = ImageFont.truetype(font_path, 40)
    except Exception:
        font = None

    # Text block
    text = (
        f"CinePulse\n"
        f"variant: {variant}\n"
        f"id: {story_id}\n"
        f"{ts}"
    )

    draw.text(
        (40, 40),
        text,
        fill=fg_color,
        font=font,  # ok if None -> default font
        spacing=8,
    )

    # Encode to PNG bytes
    buf = BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)

    return Response(
        content=buf.getvalue(),
        media_type="image/png",
        headers={
            # mild CDN friendliness, can be tuned
            "Cache-Control": "public, max-age=60",
        },
    )
