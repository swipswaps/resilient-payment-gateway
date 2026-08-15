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
