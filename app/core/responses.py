"""Custom response classes for FastAPI.
References:
- FastAPI Response classes: https://fastapi.tiangolo.com/advanced/custom-response/
- msgspec JSON encoding: https://jcristharif.com/msgspec/
- RFC 7159: The JavaScript Object Notation (JSON) Data Interchange Format.
"""
from fastapi.responses import JSONResponse
import msgspec


class MsgSpecResponse(JSONResponse):
    """
    FastAPI response that uses msgspec for high‑performance JSON serialization.
    This is used across all payment endpoints to reduce serialization overhead.
    """
    def render(self, content) -> bytes:
        return msgspec.json.encode(content)
