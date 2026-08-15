#!/bin/bash
# Fix main.py: call setup_dishka before including routers.

cat > app/main.py <<'EOT'
"""FastAPI application entry point with all middleware, telemetry, and lifespan.
References:
- FastAPI documentation: https://fastapi.tiangolo.com/
- RFC 7231: HTTP/1.1 Semantics and Content
- OWASP API Security Top 10: https://owasp.org/www-project-api-security/
"""
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

# Setup structured JSON logging (PCI‑DSS Requirement 10)
setup_logging()
logger = logging.getLogger("audit")
logger.info("Payment gateway starting up")

limiter = create_limiter()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: health checker, scheduler, etc.
    await health_checker.start()
    scheduler = await container.get(AsyncJobScheduler)
    registry = await container.get(ScheduledJobRegistry)
    registry.register_all()
    await scheduler.start()
    logger.info("All background services started")
    yield
    # Shutdown
    await scheduler.stop()
    await health_checker.stop()
    logger.info("Payment gateway shutting down")

app = FastAPI(
    title="Resilient Payment Gateway",
    version="1.0.0",
    lifespan=lifespan
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Mount Prometheus metrics (RFC 2119: SHOULD expose /metrics)
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

# Add audit middleware (for payment endpoints)
app.add_middleware(AuditLogMiddleware)

# Set up Dishka container BEFORE including routers
setup_dishka(container=container, app=app)

# Include routers (now Dishka integration is active)
from app.api import payments, webhooks, metrics as metrics_router
app.include_router(payments.router, prefix="/api/v1")
app.include_router(webhooks.router, prefix="/api/v1")
app.include_router(metrics_router.router, prefix="/api/v1")
EOT

echo "main.py updated: setup_dishka called before routers. Rebuilding app container..."
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
    echo "❌ Endpoint returned HTTP $HTTP_CODE – system may not be ready."
    echo "Recent app logs:"
    docker compose logs app --tail=30
fi
