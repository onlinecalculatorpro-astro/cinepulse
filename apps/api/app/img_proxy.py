# apps/api/app/img_proxy.py
from fastapi import APIRouter, HTTPException, Response, Query
import httpx
import re

router = APIRouter(prefix="/v1", tags=["img-proxy"])

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari"

SAFE = re.compile(r"^https?://", re.I)

@router.get("/img")
async def img(u: str = Query(..., description="absolute image URL")):
    if not SAFE.match(u):
        raise HTTPException(status_code=400, detail="bad url")

    # fetch upstream
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=20.0, headers={"User-Agent": UA}) as client:
            r = await client.get(u)
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"upstream error: {e!s}")

    if r.status_code != 200 or not r.content:
        raise HTTPException(status_code=502, detail=f"upstream status {r.status_code}")

    ctype = r.headers.get("content-type", "image/jpeg")
    # return with cache + CORS
    return Response(
        r.content,
        media_type=ctype.split(";")[0],
        headers={
            "Cache-Control": "public, max-age=86400, s-maxage=86400",  # 1 day
            "Access-Control-Allow-Origin": "*",
        },
    )
