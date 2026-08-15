#!/bin/bash
# Fix missing aioredis import in ioc.py and health checker iteration.

cat > app/core/ioc.py <<'EOT'
"""Dishka dependency injection container with all providers.
References:
- Dishka documentation: https://dishka.readthedocs.io/
- RFC 2119: "SHOULD" for optional dependencies.
"""
from typing import AsyncIterable
from dishka import Container, Provider, Scope, provide, make_async_container, from_context
from slowapi import Limiter
import redis.asyncio as aioredis

from app.core.idempotency import IdempotencyService
from app.core.limiter import create_limiter
from app.core.scheduler import AsyncJobScheduler
from app.services.webhook_dispatcher import WebhookDispatcher
from app.services.payment_service import PaymentService
from app.services.scheduled_jobs import ScheduledJobRegistry
from app.services.reconciliation import TransactionReconciliator


class InfrastructureProvider(Provider):
    @provide(scope=Scope.APP)
    def provide_idempotency_service(self) -> IdempotencyService:
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
            redis_client=None,
            reconciliator=reconciliator,
        )


container = make_async_container(InfrastructureProvider())
EOT

cat > app/services/payment_providers/health_checker.py <<'EOT'
"""Active health-check polling for circuit breaker recovery.
References:
- Health checks: https://microservices.io/patterns/observability/health-check.html
- Prometheus: Gauge metric for health status.
"""
import asyncio
import logging
from typing import Dict
from prometheus_client import Gauge
from app.services.payment_providers.base import BasePaymentProvider
from app.services.payment_providers.circuit_breaker import breaker_registry

logger = logging.getLogger(__name__)

PROVIDER_HEALTH_GAUGE = Gauge(
    "payment_provider_health_status",
    "Health status of payment provider gateways (1 = Healthy, 0 = Unhealthy)",
    ["provider"]
)

class ProviderHealthChecker:
    def __init__(self, check_interval: int = 10):
        self.check_interval = check_interval
        self._running = False
        self._task = None

    async def start(self):
        self._running = True
        self._task = asyncio.create_task(self._poll_loop())
        logger.info(f"ProviderHealthChecker started (interval: {self.check_interval}s)")

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("ProviderHealthChecker stopped")

    async def _poll_loop(self):
        while self._running:
            try:
                await self.check_all_providers()
            except Exception as exc:
                logger.error(f"Error during provider health check poll: {exc}")
            await asyncio.sleep(self.check_interval)

    async def check_all_providers(self):
        # Use .keys() to iterate over provider names.
        for provider_key in BasePaymentProvider.keys():
            breaker = breaker_registry.get_breaker(provider_key)
            is_healthy = await self._probe_provider_health(provider_key)

            PROVIDER_HEALTH_GAUGE.labels(provider=provider_key).set(1 if is_healthy else 0)

            if breaker.current_state.name == "open" and is_healthy:
                logger.info(
                    f"Health check passed for primary provider '{provider_key}'. Resetting circuit breaker to CLOSED."
                )
                breaker.close()

    async def _probe_provider_health(self, provider_key: str) -> bool:
        try:
            provider_cls = BasePaymentProvider[provider_key]
            provider_instance = provider_cls()
            if hasattr(provider_instance, "ping"):
                return await provider_instance.ping()
            return True
        except Exception:
            return False

health_checker = ProviderHealthChecker(check_interval=10)
EOT

echo "Fixed: aioredis import added, health checker iteration corrected."
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
