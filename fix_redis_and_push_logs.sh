#!/bin/bash
# Fix Redis URL, rebuild, test, and push logs to Gist on failure.

cat > app/core/ioc.py <<'EOT'
"""Dishka dependency injection container with all providers.
References:
- Dishka documentation: https://dishka.readthedocs.io/
- RFC 2119: "SHOULD" for optional dependencies.
"""
import os
from typing import AsyncIterable
import redis.asyncio as aioredis
from dishka import Container, Provider, Scope, provide, make_async_container
from slowapi import Limiter

from app.core.idempotency import IdempotencyService
from app.core.limiter import create_limiter
from app.core.scheduler import AsyncJobScheduler
from app.services.webhook_dispatcher import WebhookDispatcher
from app.services.payment_service import PaymentService
from app.services.scheduled_jobs import ScheduledJobRegistry
from app.services.reconciliation import TransactionReconciliator


class InfrastructureProvider(Provider):
    @provide(scope=Scope.APP)
    async def provide_redis_client(self) -> AsyncIterable[aioredis.Redis]:
        # Use REDIS_URL from environment, fallback to localhost for development
        redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
        client = aioredis.from_url(redis_url)
        yield client
        await client.aclose()

    @provide(scope=Scope.APP)
    def provide_idempotency_service(self, redis_client: aioredis.Redis) -> IdempotencyService:
        return IdempotencyService(redis_client=redis_client)

    @provide(scope=Scope.APP)
    def provide_limiter(self) -> Limiter:
        return create_limiter()

    @provide(scope=Scope.APP)
    def provide_webhook_dispatcher(self, redis_client: aioredis.Redis) -> WebhookDispatcher:
        return WebhookDispatcher(redis_client=redis_client)

    @provide(scope=Scope.APP)
    def provide_payment_service(self, dispatcher: WebhookDispatcher) -> PaymentService:
        return PaymentService(webhook_dispatcher=dispatcher)

    @provide(scope=Scope.APP)
    def provide_scheduler(self, redis_client: aioredis.Redis) -> AsyncJobScheduler:
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
        redis_client: aioredis.Redis,
        reconciliator: TransactionReconciliator,
    ) -> ScheduledJobRegistry:
        return ScheduledJobRegistry(
            scheduler=scheduler,
            webhook_dispatcher=dispatcher,
            payment_service=payment_service,
            redis_client=redis_client,
            reconciliator=reconciliator,
        )


# Use async container for async generator factories
container = make_async_container(InfrastructureProvider())
EOT

echo "✅ Fixed Redis URL to use REDIS_URL environment variable."
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
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs for debugging."
    LOGS=$(docker compose logs app --tail=50 2>&1)

    if command -v gh &> /dev/null; then
        echo "Creating GitHub Gist with logs..."
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (HTTP $HTTP_CODE)" --public | grep -o 'https://gist.github.com/[^ ]*')
        RAW_URL="${GIST_URL}/raw"
        echo "Raw log URL: $RAW_URL"
        echo "Gist URL: $GIST_URL"
    else
        echo "⚠️  gh not installed. Printing logs below:"
        echo "$LOGS"
        echo "Please manually create a gist or share these logs."
    fi
fi
