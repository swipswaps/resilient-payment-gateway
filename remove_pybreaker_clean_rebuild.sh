#!/bin/bash
# Remove pybreaker entirely – no sed, no placeholders.

# ----------------------------------------------------------------------
# 1. Overwrite requirements.txt (no pybreaker)
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
# 2. Overwrite pyproject.toml (no pybreaker)
# ----------------------------------------------------------------------
cat > pyproject.toml <<'EOT'
[tool.poetry]
name = "payment-gateway"
version = "0.1.0"
description = "Resilient payment gateway with state machines, circuit breakers, and audit logging."
authors = ["Your Name <you@example.com>"]

[tool.poetry.dependencies]
python = "^3.10"
fastapi = "^0.115.0"
uvicorn = {extras = ["standard"], version = "^0.30.0"}
httpx = "^0.27.0"
msgspec = "^0.18.0"
redis = "^5.0.8"
tenacity = "^8.3.0"
schedule = "^1.2.0"
slowapi = "^0.1.9"
prometheus-client = "^0.20.0"
python-json-logger = "^2.0.7"
boto3 = "^1.34.0"
hvac = "^1.2.0"
pint = "^0.24.0"
geopy = "^2.4.0"
playwright = "^1.42.0"
faker = "^20.0.0"
autoregistry = "^0.3.0"
python-statemachine = "^2.0.0"
dishka = {extras = ["fastapi"], version = "^1.1.0"}
duckdb = "^0.10.0"
mkdocs = "^1.5.0"
zensical = "^0.0.54"
radon = "^6.0.1"

[tool.poetry.group.dev.dependencies]
pytest = "^7.4.0"
pytest-asyncio = "^0.21.0"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
EOT

# ----------------------------------------------------------------------
# 3. Overwrite base.py (remove pybreaker, keep tenacity retries)
# ----------------------------------------------------------------------
cat > app/services/payment_providers/base.py <<'EOT'
"""Base payment provider with tenacity retries (no pybreaker).
References:
- Autoregistry: https://github.com/cod3monk/autoregistry
- tenacity: https://tenacity.readthedocs.io/
"""
import logging
from abc import ABC, abstractmethod
from typing import Optional
from autoregistry import Registry
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential_jitter,
    before_sleep_log,
)
from app.services.payment_providers.exceptions import TransientPaymentError

logger = logging.getLogger(__name__)

class BasePaymentProvider(Registry, ABC):
    @abstractmethod
    async def _execute_charge(self, payment_id: str, amount: float, currency: str) -> bool:
        pass

    async def ping(self) -> bool:
        """Default health probe (should be overridden by providers)."""
        return True

    async def get_transaction_status(self, payment_id: str) -> Optional[str]:
        """Query provider for status; returns 'succeeded', 'failed', 'pending', or None."""
        return None

    @retry(
        retry=retry_if_exception_type(TransientPaymentError),
        stop=stop_after_attempt(3),
        wait=wait_exponential_jitter(initial=0.5, max=5.0),
        before_sleep=before_sleep_log(logger, logging.WARNING),
        reraise=True,
    )
    async def _retryable_charge(self, payment_id: str, amount: float, currency: str) -> bool:
        return await self._execute_charge(payment_id, amount, currency)

    async def process_charge_with_resilience(self, payment_id: str, amount: float, currency: str) -> bool:
        """Executes charge with tenacity retries only (circuit breaker removed)."""
        return await self._retryable_charge(payment_id, amount, currency)

    @abstractmethod
    async def process_refund(self, payment_id: str, amount: float) -> bool:
        pass
EOT

# ----------------------------------------------------------------------
# 4. Overwrite payment_service.py (remove pybreaker imports)
# ----------------------------------------------------------------------
cat > app/services/payment_service.py <<'EOT'
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
EOT

# ----------------------------------------------------------------------
# 5. Remove circuit_breaker.py (optional – not imported anymore)
# ----------------------------------------------------------------------
rm -f app/services/payment_providers/circuit_breaker.py

# ----------------------------------------------------------------------
# 6. Clean rebuild and test
# ----------------------------------------------------------------------
echo "✅ Removed pybreaker, rewrote base.py and payment_service.py."
echo "Performing clean rebuild (no cache)..."
docker compose down
docker compose build --no-cache app
docker compose up -d

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
