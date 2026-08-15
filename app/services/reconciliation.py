"""Automated transaction reconciliation for fallback double-charge protection.
References:
- NIST SP 800-53: System and Information Integrity.
- ISO 20022: Financial services messaging.
"""
import logging
from typing import List, Dict, Optional
from app.services.payment_service import PaymentService
from app.services.payment_providers.base import BasePaymentProvider
from app.services.payment_state import PaymentWorkflow
from app.services.webhook_dispatcher import WebhookDispatcher
from app.core.metrics import PAYMENT_TRANSACTIONS_TOTAL
from prometheus_client import Counter

logger = logging.getLogger(__name__)

RECONCILIATION_DISCREPANCIES = Counter(
    "payment_reconciliation_discrepancies_total",
    "Number of state mismatches detected during reconciliation",
    ["provider", "local_state", "provider_state"]
)

class TransactionReconciliator:
    def __init__(
        self,
        payment_service: PaymentService,
        webhook_dispatcher: WebhookDispatcher,
    ):
        self.payment_service = payment_service
        self.dispatcher = webhook_dispatcher

    async def reconcile_all_pending(self) -> int:
        pending_ids = self.payment_service.list_pending_transactions()
        if not pending_ids:
            return 0

        fixed_count = 0
        for pid in pending_ids:
            sm = self.payment_service._transactions.get(pid)
            if not sm:
                continue

            provider_name = getattr(sm, "provider_name", None)
            if not provider_name or provider_name not in BasePaymentProvider:
                continue

            provider_cls = BasePaymentProvider[provider_name]
            provider_instance = provider_cls()
            try:
                status = await provider_instance.get_transaction_status(pid)
            except Exception as e:
                logger.error(f"Reconciliation: failed to query {provider_name} for {pid}: {e}")
                continue

            if status is None:
                continue

            local_state = sm.current_state.id
            if local_state == "pending":
                if status == "succeeded":
                    sm.capture()
                    await self.dispatcher.dispatch_event(
                        "payment.completed",
                        pid,
                        {"amount": sm.amount, "reconciled": True}
                    )
                    PAYMENT_TRANSACTIONS_TOTAL.labels(provider=provider_name, status="completed").inc()
                    RECONCILIATION_DISCREPANCIES.labels(
                        provider=provider_name,
                        local_state="pending",
                        provider_state="succeeded"
                    ).inc()
                    fixed_count += 1
                    logger.info(f"Reconciled {pid}: pending → completed (provider says succeeded)")
                elif status == "failed":
                    sm.decline(reason="Provider reported failure (reconciliation)")
                    await self.dispatcher.dispatch_event(
                        "payment.failed",
                        pid,
                        {"reason": sm.failure_reason, "reconciled": True}
                    )
                    PAYMENT_TRANSACTIONS_TOTAL.labels(provider=provider_name, status="failed").inc()
                    RECONCILIATION_DISCREPANCIES.labels(
                        provider=provider_name,
                        local_state="pending",
                        provider_state="failed"
                    ).inc()
                    fixed_count += 1
                    logger.info(f"Reconciled {pid}: pending → failed (provider says failed)")
        return fixed_count
