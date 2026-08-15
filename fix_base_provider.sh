#!/bin/bash
# Add missing Optional import to base.py

cat > app/services/payment_providers/base.py <<'EOT'
"""Base payment provider with tenacity retries and pybreaker circuit breaker.
References:
- Autoregistry: https://github.com/cod3monk/autoregistry
- tenacity: https://tenacity.readthedocs.io/
- pybreaker: https://github.com/danielfm/pybreaker
- PEP 484: Type Hints (Optional)
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
from app.services.payment_providers.circuit_breaker import breaker_registry

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
        provider_key = self.__class__.__name__.lower()
        breaker = breaker_registry.get_breaker(provider_key)
        return await breaker.call_async(
            self._retryable_charge, payment_id, amount, currency
        )

    @abstractmethod
    async def process_refund(self, payment_id: str, amount: float) -> bool:
        pass
EOT

echo "app/services/payment_providers/base.py fixed. Rebuilding app container..."
docker compose up -d --build app
