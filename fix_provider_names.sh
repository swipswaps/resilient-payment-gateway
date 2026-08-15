#!/bin/bash
# Fix provider name normalization and health checker.

# ----------------------------------------------------------------------
# 1. Fix payment_service.py – normalize provider names
# ----------------------------------------------------------------------
cat > app/services/payment_service.py <<'EOT'
"""Payment orchestration with state machine, circuit breaker, and retries.
References:
- python-statemachine: https://github.com/fgmacedo/python-statemachine
- tenacity: https://tenacity.readthedocs.io/
- pybreaker: https://github.com/danielfm/pybreaker
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
import pybreaker

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

        except pybreaker.CircuitBreakerError as exc:
            logger.error(f"Circuit breaker OPEN for {provider_name}: {exc}")
            sm.decline(
                reason=f"Gateway circuit breaker open ({provider_name} temporarily unavailable)"
            )
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

            except pybreaker.CircuitBreakerError:
                logger.warning(
                    f"Circuit breaker OPEN for provider '{provider_name}'. Trying next fallback..."
                )
                continue

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
EOT

# ----------------------------------------------------------------------
# 2. Fix health_checker.py – use normalized names
# ----------------------------------------------------------------------
cat > app/services/payment_providers/health_checker.py <<'EOT'
"""Active health-check polling for circuit breaker recovery.
References:
- Health checks: https://microservices.io/patterns/observability/health-check.html
- Prometheus: Gauge metric for health status.
"""
import asyncio
import logging
import re
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


def normalize_provider_name(name: str) -> str:
    """Normalize provider name for registry lookup."""
    return re.sub(r'_+', '', name).lower()


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
        provider_names = list(BasePaymentProvider.keys())
        for provider_key in provider_names:
            try:
                # Normalize the key for breaker registry lookup
                normalized = normalize_provider_name(provider_key)
                breaker = breaker_registry.get_breaker(normalized)
                is_healthy = await self._probe_provider_health(provider_key)

                PROVIDER_HEALTH_GAUGE.labels(provider=provider_key).set(1 if is_healthy else 0)

                if breaker and hasattr(breaker, "current_state"):
                    if breaker.current_state.name == "open" and is_healthy:
                        logger.info(
                            f"Health check passed for primary provider '{provider_key}'. "
                            "Resetting circuit breaker to CLOSED."
                        )
                        breaker.close()
            except Exception as e:
                logger.error(f"Error checking provider '{provider_key}': {e}")

    async def _probe_provider_health(self, provider_key: str) -> bool:
        try:
            provider_cls = BasePaymentProvider[provider_key]
            provider_instance = provider_cls()
            if hasattr(provider_instance, "ping"):
                return await provider_instance.ping()
            return True
        except Exception as e:
            logger.warning(f"Health probe failed for {provider_key}: {e}")
            return False


health_checker = ProviderHealthChecker(check_interval=10)
EOT

# ----------------------------------------------------------------------
# 3. Rebuild, test, and push logs to Gist on failure
# ----------------------------------------------------------------------
echo "✅ Fixed provider name normalization."
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
