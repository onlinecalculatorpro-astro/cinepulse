from pydantic import BaseModel
from typing import Literal, Optional

Kind = Literal["trailer", "release", "ott", "bo", "award"]

class AdapterEvent(BaseModel):
    source: Literal["youtube", "pressroom", "trade", "bom", "netflix_top10"]
    source_event_id: str
    title: str
    kind: Kind
    published_at: Optional[str] = None  # ISO string
    payload: dict = {}
