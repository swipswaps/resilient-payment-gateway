"""Payment orchestration with state machine, tenacity retries (no pybreaker).
References:
- python-statemachine: https://github.com/fgmacedo/python-statemachine
- tenacity: https://tenacity.readthedocs.io/
- Pydantic: https://docs.pydantic.dev/
"""
import logging
import time
import re
from typing import Dict, List, Optional
from pydantic import BaseModel, Field
from fastapi import HTTPException, status
from app.services.payment_state import PaymentWorkflow
from app.services.webhook_dispatcher import WebhookDispatcher
from app.services.payment_providers.base import BasePaymentProvider
from app.services.payment_providers.exceptions import (
    PermanentPaymentError,
    TransientPaymentError,
)
from app.services.payment_providers.fallback_router import (
    get_provider_chain,
    PAYMENT_FALLBACK_TOTAL,
)
# Force plugin registration by importing the plugins module
import app.services.payment_providers.plugins  # noqa: F401

logger = logging.getLogger(__name__)


def normalize_provider_name(name: str) -> str:
    """
    Normalize provider name for registry lookup.
    Removes underscores and converts to lowercase.
    Example: 'mock_payment_provider' -> 'mockpaymentprovider'
    """
    return re.sub(r'_+', '', name).lower()


# ----- Request/Response Models (Pydantic) -----

class ExecutePaymentRequest(BaseModel):
    """Pydantic request model for /payments/execute endpoint."""
    payment_id: str = Field(..., description="Unique payment identifier")
    amount: float = Field(..., gt=0, description="Amount to charge")
    provider: str = Field(..., description="Payment provider name")
    currency: str = Field("USD", description="Currency code")


class PaymentResponse(BaseModel):
    """Pydantic response model for payment execution."""
    payment_id: str
    amount: float
    currency: str
    current_state: str
    failure_reason: Optional[str] = None


def _format_payment_response(sm: PaymentWorkflow) -> PaymentResponse:
    """Format a PaymentWorkflow instance into a PaymentResponse."""
    return PaymentResponse(
        payment_id=sm.payment_id,
        amount=sm.amount,
        currency=sm.currency,
        current_state=sm.current_state.id,
        failure_reason=sm.failure_reason,
    )


# ----- Payment Service -----

class PaymentService:
    def __init__(self, webhook_dispatcher: Optional[WebhookDispatcher] = None):
        self._transactions: Dict[str, PaymentWorkflow] = {}
        self._transaction_timestamps: Dict[str, float] = {}
        self.dispatcher = webhook_dispatcher or WebhookDispatcher()

    def list_available_providers(self) -> List[str]:
        return list(BasePaymentProvider.keys())

    def list_pending_transactions(self) -> List[str]:
        return [
            pid for pid, sm in self._transactions.items()
            if sm.current_state.id == "pending"
        ]

    async def cleanup_stale_transactions(self, max_age_seconds: float = 86400.0) -> int:
        now = time.time()
        stale = [
            pid for pid, ts in self._transaction_timestamps.items()
            if now - ts > max_age_seconds
        ]
        for pid in stale:
            self._transactions.pop(pid, None)
            self._transaction_timestamps.pop(pid, None)
        if stale:
            logger.info(f"Cleaned up {len(stale)} stale transactions")
        return len(stale)

    async def execute_provider_payment(
        self,
        payment_id: str,
        amount: float,
        provider_name: str,
        currency: str = "USD",
    ) -> PaymentWorkflow:
        # Normalize the provider name for registry lookup
        normalized = normalize_provider_name(provider_name)
        available = self.list_available_providers()
        logger.info(f"Available providers: {available}")
        logger.info(f"Requested provider: {provider_name} (normalized: {normalized})")

        if normalized not in BasePaymentProvider:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unsupported payment provider: '{provider_name}'. Normalized: '{normalized}'. Available: {available}",
            )

        sm = PaymentWorkflow(payment_id=payment_id, amount=amount, currency=currency)
        sm.authorize()
        self._transactions[payment_id] = sm
        self._transaction_timestamps[payment_id] = time.time()

        await self.dispatcher.dispatch_event(
            "payment.pending", payment_id, {"amount": amount, "currency": currency}
        )

        provider_cls = BasePaymentProvider[normalized]
        provider_instance: BasePaymentProvider = provider_cls()

        try:
            success = await provider_instance.process_charge_with_resilience(
                payment_id, amount, currency
            )
            if success:
                sm.capture()
                await self.dispatcher.dispatch_event(
                    "payment.completed",
                    payment_id,
                    {"amount": amount, "status": "completed"},
                )
            else:
                sm.decline(reason="Provider processing returned false")
                await self.dispatcher.dispatch_event(
                    "payment.failed", payment_id, {"reason": sm.failure_reason}
                )

        except (TransientPaymentError, PermanentPaymentError) as exc:
            sm.decline(reason=f"Provider processing error: {str(exc)}")
            await self.dispatcher.dispatch_event(
                "payment.failed", payment_id, {"reason": sm.failure_reason}
            )

        return sm

    async def execute_provider_payment_with_fallback(
        self,
        payment_id: str,
        amount: float,
        preferred_provider: str,
        currency: str = "USD"
    ) -> PaymentWorkflow:
        normalized = normalize_provider_name(preferred_provider)
        if normalized not in BasePaymentProvider:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unsupported primary payment provider: '{preferred_provider}'. Normalized: '{normalized}'",
            )

        sm = PaymentWorkflow(payment_id=payment_id, amount=amount, currency=currency)
        sm.authorize()
        self._transactions[payment_id] = sm
        self._transaction_timestamps[payment_id] = time.time()

        provider_chain = get_provider_chain(normalized)
        attempted_providers: List[str] = []

        for idx, provider_name in enumerate(provider_chain):
            attempted_providers.append(provider_name)

            if idx > 0:
                primary_provider = provider_chain[0]
                logger.warning(
                    f"Failing over transaction {payment_id} from {primary_provider} to {provider_name}"
                )
                PAYMENT_FALLBACK_TOTAL.labels(
                    primary_provider=primary_provider,
                    fallback_provider=provider_name
                ).inc()

            provider_cls = BasePaymentProvider[provider_name]
            provider_instance: BasePaymentProvider = provider_cls()

            try:
                success = await provider_instance.process_charge_with_resilience(
                    payment_id, amount, currency
                )
                if success:
                    sm.capture()
                    await self.dispatcher.dispatch_event(
                        "payment.completed",
                        payment_id,
                        {"amount": amount, "executed_provider": provider_name}
                    )
                    return sm

            except TransientPaymentError as exc:
                logger.warning(
                    f"Transient failure on provider '{provider_name}' (exhausted retries): {exc}. Trying fallback..."
                )
                continue

            except PermanentPaymentError as exc:
                sm.decline(reason=f"Permanent payment rejection on {provider_name}: {exc}")
                await self.dispatcher.dispatch_event("payment.failed", payment_id, {"reason": sm.failure_reason})
                return sm

        failure_msg = f"All payment providers failed in chain: {', '.join(attempted_providers)}"
        sm.decline(reason=failure_msg)
        await self.dispatcher.dispatch_event("payment.failed", payment_id, {"reason": failure_msg})
        return sm
