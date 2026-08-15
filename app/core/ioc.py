"""Dishka dependency injection container with all providers.
References:
- Dishka documentation: https://dishka.readthedocs.io/
- Redis asyncio: https://redis.readthedocs.io/en/latest/
"""
import os
from typing import AsyncIterable
from dishka import Provider, Scope, provide, make_async_container
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
    async def provide_redis_client(self) -> AsyncIterable[aioredis.Redis]:
        """Create Redis client once per app lifecycle, close on shutdown."""
        redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
        client = aioredis.from_url(redis_url, decode_responses=True)
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
