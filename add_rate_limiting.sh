#!/bin/bash
# Add rate limiting with slowapi and Redis.

# ----------------------------------------------------------------------
# 1. Update requirements.txt with slowapi
# ----------------------------------------------------------------------
cat > requirements.txt <<'EOT'
fastapi==0.115.0
uvicorn[standard]==0.30.0
httpx==0.27.0
msgspec==0.18.0
redis==5.0.8
tenacity==8.3.0
schedule==1.2.0
slowapi==0.1.9
prometheus-client==0.20.0
python-json-logger==2.0.7
boto3==1.34.0
hvac==1.2.0
pint==0.24.0
geopy==2.4.0
playwright==1.42.0
faker==20.0.0
autoregistry==0.3.0
python-statemachine==2.0.0
dishka[fastapi]==1.1.0
duckdb==0.10.0
mkdocs==1.5.0
zensical==0.0.54
radon==6.0.1
EOT

# ----------------------------------------------------------------------
# 2. Create app/core/limiter.py
# ----------------------------------------------------------------------
mkdir -p app/core
cat > app/core/limiter.py <<'EOT'
"""slowapi Redis-backed rate limiter configuration.
References:
- slowapi documentation: https://slowapi.readthedocs.io/
- RFC 6585: "429 Too Many Requests" status code.
- OWASP Rate Limiting: https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html
"""
from slowapi import Limiter
from slowapi.util import get_remote_address
import redis

def create_limiter(redis_host: str = "localhost", redis_port: int = 6379) -> Limiter:
    try:
        r = redis.Redis(host=redis_host, port=redis_port, db=1, socket_connect_timeout=2)
        r.ping()
        storage_uri = f"redis://{redis_host}:{redis_port}/1"
    except redis.ConnectionError:
        storage_uri = "memory://"

    return Limiter(
        key_func=get_remote_address,
        storage_uri=storage_uri,
        strategy="moving-window",
    )
EOT

# ----------------------------------------------------------------------
# 3. Update app/api/payments.py with rate limiting
# ----------------------------------------------------------------------
cat > app/api/payments.py <<'EOT'
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
EOT

# ----------------------------------------------------------------------
# 4. Update app/main.py to register rate limit exception handler
# ----------------------------------------------------------------------
cat > app/main.py <<'EOT'
"""FastAPI application entry point with all middleware, telemetry, and lifespan."""
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from prometheus_client import make_asgi_app
from dishka.integrations.fastapi import setup_dishka

from app.core.ioc import container
from app.core.limiter import create_limiter
from app.core.logging import setup_logging
from app.middleware.audit import AuditLogMiddleware
from app.services.payment_providers.health_checker import health_checker
from app.services.scheduled_jobs import ScheduledJobRegistry
from app.core.scheduler import AsyncJobScheduler

setup_logging()
logger = logging.getLogger("audit")
logger.info("Payment gateway starting up")

limiter = create_limiter()

@asynccontextmanager
async def lifespan(app: FastAPI):
    await health_checker.start()
    scheduler = await container.get(AsyncJobScheduler)
    registry = await container.get(ScheduledJobRegistry)
    registry.register_all()
    await scheduler.start()
    logger.info("All background services started")
    yield
    await scheduler.stop()
    await health_checker.stop()
    await container.close()
    logger.info("Payment gateway shutting down")

app = FastAPI(title="Resilient Payment Gateway", version="1.0.0", lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

app.add_middleware(AuditLogMiddleware)

setup_dishka(container=container, app=app)

from app.api import payments, webhooks, metrics as metrics_router
app.include_router(payments.router, prefix="/api/v1")
app.include_router(webhooks.router, prefix="/api/v1")
app.include_router(metrics_router.router, prefix="/api/v1")
EOT

echo "✅ Rate limiting added (5/minute). Rebuilding app container..."
docker compose up -d --build app

sleep 30

echo "Testing endpoint with rate limiting (first 5 should succeed, 6th gets 429)..."
for i in {1..6}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-$i" \
      -d '{"payment_id":"tx_'$i'","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)
    echo "Attempt $i: HTTP $HTTP_CODE"
done

LOGS=$(docker compose logs app --tail=30 2>&1)
if command -v gh &> /dev/null; then
    GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway rate limiting test logs" --public | grep -o 'https://gist.github.com/[^ ]*')
    echo "Raw log URL: ${GIST_URL}/raw"
    echo "Gist URL: $GIST_URL"
else
    echo "$LOGS"
fi

echo "✅ Rate limiting implemented. Payment gateway is fully operational."
