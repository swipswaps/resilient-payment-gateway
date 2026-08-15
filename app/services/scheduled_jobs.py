"""Scheduled background jobs: webhook retry, stale cleanup, reconciliation.
References:
- schedule library: https://schedule.readthedocs.io/
- Redis for job persistence.
"""
import json
import logging
from typing import Optional
import redis.asyncio as aioredis
from app.core.scheduler import AsyncJobScheduler
from app.services.webhook_dispatcher import WebhookDispatcher
from app.services.payment_service import PaymentService
from app.services.reconciliation import TransactionReconciliator

logger = logging.getLogger(__name__)

class ScheduledJobRegistry:
    def __init__(
        self,
        scheduler: AsyncJobScheduler,
        webhook_dispatcher: WebhookDispatcher,
        payment_service: PaymentService,
        redis_client: aioredis.Redis,
        reconciliator: TransactionReconciliator,
    ):
        self.scheduler = scheduler
        self.dispatcher = webhook_dispatcher
        self.payment_service = payment_service
        self.redis = redis_client
        self.reconciliator = reconciliator

    def register_all(self) -> None:
        @self.scheduler.schedule_every(
            interval_seconds=30,
            job_id="webhook_retry_processor",
            lock_timeout=120,
            max_retries=3,
        )
        async def retry_failed_webhooks() -> None:
            queue_key = "webhook:retry:queue"
            for _ in range(10):
                item_raw = await self.redis.rpop(queue_key)
                if not item_raw:
                    break
                item = json.loads(item_raw.decode("utf-8"))
                if item.get("attempts", 0) >= 5:
                    logger.error(f"Dropping webhook {item['event_type']}:{item['payment_id']} after max retries")
                    continue
                await self.dispatcher.dispatch_event(
                    event_type=item["event_type"],
                    payment_id=item["payment_id"],
                    data=item["data"],
                    target_urls=item.get("urls", []),
                )

        @self.scheduler.schedule_every(
            interval_seconds=300,
            job_id="stale_transaction_cleanup",
            lock_timeout=60,
            max_retries=3,
        )
        async def cleanup_stale_transactions() -> None:
            removed = await self.payment_service.cleanup_stale_transactions(max_age_seconds=86400.0)
            if removed:
                logger.info(f"Background cleanup removed {removed} stale transactions")

        @self.scheduler.schedule_every(
            interval_seconds=120,
            job_id="transaction_reconciliation",
            lock_timeout=180,
            max_retries=3,
        )
        async def reconcile_transactions() -> None:
            fixed = await self.reconciliator.reconcile_all_pending()
            if fixed:
                logger.info(f"Reconciliation job fixed {fixed} transactions")
