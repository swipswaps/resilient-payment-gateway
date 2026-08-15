"""Audit logging middleware for payment forensics – Phase 60.
References:
- PCI DSS Requirement 10: Log all access to system components.
- NIST SP 800‑92: Guide to Computer Security Log Management.
- RFC 5424: The Syslog Protocol (structured logging).
- OWASP Logging Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
- ISO/IEC 27001:2013 – Information security management (audit trail requirements).
"""
import json
import time
import uuid
from typing import Callable, Optional
from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp
import logging

logger = logging.getLogger("audit")

class AuditLogMiddleware(BaseHTTPMiddleware):
    """
    Logs request/response metadata for all /api/v1/payments/* endpoints.
    Generates correlation ID, captures user ID, idempotency key, and truncates bodies.
    """
    def __init__(self, app: ASGIApp, exclude_paths: Optional[list] = None):
        super().__init__(app)
        # Exclude monitoring endpoints to reduce noise (OWASP recommends filtering).
        self.exclude_paths = exclude_paths or ["/metrics", "/health", "/docs", "/openapi.json"]

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        if request.url.path in self.exclude_paths or not request.url.path.startswith("/api/v1/payments"):
            return await call_next(request)

        corr_id = request.headers.get("X-Correlation-ID") or str(uuid.uuid4())
        request.state.corr_id = corr_id
        user_id = request.headers.get("X-User-ID") or "anonymous"
        idempotency_key = request.headers.get("X-Idempotency-Key")

        start = time.perf_counter()
        body_bytes = await request.body()
        request._body = body_bytes

        log_entry = {
            "correlation_id": corr_id,
            "user_id": user_id,
            "idempotency_key": idempotency_key,
            "method": request.method,
            "path": request.url.path,
            "query": dict(request.query_params),
            "client_ip": request.client.host if request.client else None,
            "request_body": self._truncate(body_bytes.decode("utf-8", errors="replace")),
            "timestamp": time.time(),
        }

        try:
            response = await call_next(request)
            duration = time.perf_counter() - start
            response_body = b""
            if hasattr(response, "body"):
                response_body = response.body
            log_entry.update({
                "status_code": response.status_code,
                "duration_seconds": round(duration, 4),
                "response_body": self._truncate(response_body.decode("utf-8", errors="replace")),
            })
            logger.info(json.dumps(log_entry))
            return response
        except Exception as exc:
            duration = time.perf_counter() - start
            log_entry.update({
                "status_code": 500,
                "duration_seconds": round(duration, 4),
                "error": str(exc),
            })
            logger.error(json.dumps(log_entry))
            raise

    @staticmethod
    def _truncate(text: str, max_len: int = 1024) -> str:
        if len(text) > max_len:
            return text[:max_len] + "... (truncated)"
        return text
