#!/bin/bash
# Fix Redis event loop attachment by using app.state.redis with lifespan.

cat > app/main.py <<'EOT'
"""FastAPI application entry point with all middleware, telemetry, and lifespan.
References:
- FastAPI documentation: https://fastapi.tiangolo.com/
- Redis asyncio: https://redis.readthedocs.io/en/latest/
"""
import logging
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from prometheus_client import make_asgi_app
from dishka.integrations.fastapi import setup_dishka
import redis.asyncio as aioredis

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
    # Startup: Initialize Redis client once (single event loop)
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    app.state.redis = aioredis.from_url(redis_url, decode_responses=True)
    logger.info(f"Redis client initialized at {redis_url}")

    # Start health checker
    await health_checker.start()

    # Get scheduler and registry from container
    scheduler = await container.get(AsyncJobScheduler)
    registry = await container.get(ScheduledJobRegistry)
    registry.register_all()
    await scheduler.start()
    logger.info("All background services started")

    yield

    # Shutdown
    await scheduler.stop()
    await health_checker.stop()
    await app.state.redis.aclose()
    logger.info("Payment gateway shutting down")

app = FastAPI(
    title="Resilient Payment Gateway",
    version="1.0.0",
    lifespan=lifespan
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Mount Prometheus metrics
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

# Add audit middleware (for payment endpoints)
app.add_middleware(AuditLogMiddleware)

# Set up Dishka container BEFORE including routers
setup_dishka(container=container, app=app)

# Include routers
from app.api import payments, webhooks, metrics as metrics_router
app.include_router(payments.router, prefix="/api/v1")
app.include_router(webhooks.router, prefix="/api/v1")
app.include_router(metrics_router.router, prefix="/api/v1")
EOT

cat > app/core/ioc.py <<'EOT'
"""Dishka dependency injection container with all providers.
References:
- Dishka documentation: https://dishka.readthedocs.io/
- RFC 2119: "SHOULD" for optional dependencies.
"""
from typing import AsyncIterable
from dishka import Container, Provider, Scope, provide, make_async_container, from_context
from slowapi import Limiter

from app.core.idempotency import IdempotencyService
from app.core.limiter import create_limiter
from app.core.scheduler import AsyncJobScheduler
from app.services.webhook_dispatcher import WebhookDispatcher
from app.services.payment_service import PaymentService
from app.services.scheduled_jobs import ScheduledJobRegistry
from app.services.reconciliation import TransactionReconciliator
from app.core.redis_client import get_redis_client


class InfrastructureProvider(Provider):
    @provide(scope=Scope.APP)
    def provide_idempotency_service(self) -> IdempotencyService:
        # Get Redis client from app.state via from_context
        redis_client = from_context(aioredis.Redis, source="app.state.redis")
        return IdempotencyService(redis_client=redis_client)

    @provide(scope=Scope.APP)
    def provide_limiter(self) -> Limiter:
        return create_limiter()

    @provide(scope=Scope.APP)
    def provide_webhook_dispatcher(self) -> WebhookDispatcher:
        redis_client = from_context(aioredis.Redis, source="app.state.redis")
        return WebhookDispatcher(redis_client=redis_client)

    @provide(scope=Scope.APP)
    def provide_payment_service(self, dispatcher: WebhookDispatcher) -> PaymentService:
        return PaymentService(webhook_dispatcher=dispatcher)

    @provide(scope=Scope.APP)
    def provide_scheduler(self) -> AsyncJobScheduler:
        redis_client = from_context(aioredis.Redis, source="app.state.redis")
        return AsyncJobScheduler(redis_client=redis_client, check_interval=1.0)

    @provide(scope=Scope.APP)
    def provide_reconciliator(
        self,
        payment_service: PaymentService,
        dispatcher: WebhookDispatcher,
    ) -> TransactionReconciliator:
        return TransactionReconciliator(payment_service, dispatcher)

    @provide(scope=Scope.APP)
    def provide_job_registry(
        self,
        scheduler: AsyncJobScheduler,
        dispatcher: WebhookDispatcher,
        payment_service: PaymentService,
        reconciliator: TransactionReconciliator,
    ) -> ScheduledJobRegistry:
        return ScheduledJobRegistry(
            scheduler=scheduler,
            webhook_dispatcher=dispatcher,
            payment_service=payment_service,
            redis_client=None,  # Scheduler manages its own Redis client
            reconciliator=reconciliator,
        )


# Use async container for async generator factories
container = make_async_container(InfrastructureProvider())
EOT

# Create a small helper module for Redis client access
mkdir -p app/core
cat > app/core/redis_client.py <<'EOT'
"""Helper to access Redis client from app.state."""
from fastapi import FastAPI
import redis.asyncio as aioredis

def get_redis_client(app: FastAPI) -> aioredis.Redis:
    """Get Redis client from app.state."""
    return app.state.redis
EOT

echo "✅ Fixed Redis client with lifespan management."
echo "Rebuilding app container..."
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
    echo "✅ SUCCESS – endpoint responded with 200 OK."
    echo "Response:"
    curl -s -X POST http://localhost:8000/api/v1/payments/execute \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-001" \
      -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' | python -m json.tool
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs."
    LOGS=$(docker compose logs app --tail=50 2>&1)
    if command -v gh &> /dev/null; then
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (HTTP $HTTP_CODE)" --public | grep -o 'https://gist.github.com/[^ ]*')
        echo "Raw log URL: ${GIST_URL}/raw"
        echo "Gist URL: $GIST_URL"
    else
        echo "$LOGS"
    fi
fi
