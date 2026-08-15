"""Payment execution endpoints with idempotency, rate limiting, and audit logging.
References:
- FastAPI dependency injection: https://fastapi.tiangolo.com/tutorial/dependencies/
- RFC 7231: POST semantics.
- OWASP API Security: authentication and rate limiting.
"""
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from slowapi import Limiter
from dishka.integrations.fastapi import FromDishka, inject

from app.core.responses import MsgSpecResponse
from app.core.idempotency import IdempotencyService
from app.core.metrics import (
    IDEMPOTENCY_CACHE_REQUESTS_TOTAL,
    PAYMENT_EXECUTION_LATENCY,
    PAYMENT_TRANSACTIONS_TOTAL,
)
from app.services.payment_service import (
    PaymentService,
    ExecutePaymentRequest,
    _format_payment_response,
    PaymentResponse,
)
from app.core.limiter import create_limiter

limiter = create_limiter()
router = APIRouter(prefix="/payments", tags=["Payments"])

@router.post(
    "/execute",
    response_class=MsgSpecResponse,
    response_model=PaymentResponse,
)
@limiter.limit("5/minute")
@inject
async def execute_provider_payment_rate_limited(
    request: Request,
    req: ExecutePaymentRequest,
    svc: FromDishka[PaymentService],
    idempotency_svc: FromDishka[IdempotencyService],
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
) -> PaymentResponse:
    import time

    if not x_idempotency_key:
        start_time = time.perf_counter()
        sm = await svc.execute_provider_payment(
            req.payment_id, req.amount, req.provider, req.currency
        )
        duration = time.perf_counter() - start_time
        PAYMENT_EXECUTION_LATENCY.labels(provider=req.provider).observe(duration)
        PAYMENT_TRANSACTIONS_TOTAL.labels(provider=req.provider, status=sm.current_state.id).inc()
        return _format_payment_response(sm)

    cached = await idempotency_svc.get_cached_response(x_idempotency_key)
    if cached:
        IDEMPOTENCY_CACHE_REQUESTS_TOTAL.labels(hit="true").inc()
        status_code, body = cached
        return JSONResponse(status_code=status_code, content=body, headers={"X-Cache-Hit": "true"})

    IDEMPOTENCY_CACHE_REQUESTS_TOTAL.labels(hit="false").inc()

    acquired = await idempotency_svc.lock_and_check(x_idempotency_key)
    if not acquired:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Concurrent request in progress for this Idempotency-Key.",
        )

    start_time = time.perf_counter()
    sm = await svc.execute_provider_payment(
        req.payment_id, req.amount, req.provider, req.currency
    )
    duration = time.perf_counter() - start_time
    PAYMENT_EXECUTION_LATENCY.labels(provider=req.provider).observe(duration)
    PAYMENT_TRANSACTIONS_TOTAL.labels(provider=req.provider, status=sm.current_state.id).inc()

    response_payload = _format_payment_response(sm)
    response_dict = {
        "payment_id": response_payload.payment_id,
        "amount": response_payload.amount,
        "currency": response_payload.currency,
        "current_state": response_payload.current_state,
        "failure_reason": response_payload.failure_reason,
    }

    await idempotency_svc.save_response(x_idempotency_key, 200, response_dict)
    return JSONResponse(status_code=200, content=response_dict, headers={"X-Cache-Hit": "false"})
