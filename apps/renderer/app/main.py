from io import BytesIO
from datetime import datetime
from fastapi import FastAPI
from fastapi.responses import Response
from PIL import Image, ImageDraw

app = FastAPI(title="CinePulse Renderer", version="0.1.0")

@app.post("/render-card")
def render_card(story_id: str = "demo", variant: str = "story"):
    w, h = 1200, 628
    img = Image.new("RGB", (w, h), (18, 18, 24))
    d = ImageDraw.Draw(img)
    d.text((40, 40),
           f"CinePulse — {variant}\nID: {story_id}\n{datetime.utcnow().isoformat()}Z",
           fill=(230, 230, 230))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return Response(content=buf.getvalue(), media_type="image/png")
