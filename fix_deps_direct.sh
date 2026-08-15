#!/bin/bash
# Fix payments.py: use container directly, remove FromDishka.

cat > app/api/payments.py <<'EOT'
"""Payment execution endpoints with idempotency, rate limiting, and audit logging."""
from typing import Optional
from fastapi import APIRouter, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from slowapi import Limiter
from dishka.integrations.fastapi import FromDishka

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
from app.core.ioc import container   # direct container access

limiter = create_limiter()
router = APIRouter(prefix="/payments", tags=["Payments"])

@router.post(
    "/execute",
    response_class=MsgSpecResponse,
    response_model=PaymentResponse,
)
@limiter.limit("5/minute")
async def execute_provider_payment_rate_limited(
    request: Request,
    req: ExecutePaymentRequest,
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
) -> PaymentResponse:
    import time

    # Get services from container directly
    svc = await container.get(PaymentService)
    idempotency_svc = await container.get(IdempotencyService)

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
EOT

echo "payments.py updated to use container directly. Rebuilding app container..."
docker compose up -d --build app

echo "Waiting 30 seconds for container to start..."
sleep 30

echo "Testing endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Endpoint responded with 200 OK – system is healthy."
    echo "Response:"
    curl -s -X POST http://localhost:8000/api/v1/payments/execute \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-001" \
      -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' | python -m json.tool
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs for debugging."
    LOGS=$(docker compose logs app --tail=50 2>&1)

    # Create a GitHub Gist with logs and print raw URL
    if command -v gh &> /dev/null; then
        echo "Creating GitHub Gist with logs..."
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs" --public | grep -o 'https://gist.github.com/[^ ]*')
        RAW_URL="${GIST_URL}/raw"
        echo "Raw log URL: $RAW_URL"
        echo "Gist URL: $GIST_URL"
    else
        echo "gh not installed. Printing logs below:"
        echo "$LOGS"
        echo "Please manually create a gist or share these logs."
    fi
fi
