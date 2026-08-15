"""Payment provider plugins (mock and Stripe) with transient and permanent error simulation."""
import random
from typing import Optional, Dict
from app.services.payment_providers.base import BasePaymentProvider
from app.services.payment_providers.exceptions import TransientPaymentError, PermanentPaymentError

class MockPaymentProvider(BasePaymentProvider):
    def __init__(self, simulate_transient_failures: int = 0):
        self.transient_attempts_remaining = simulate_transient_failures
        self._status_map: Dict[str, str] = {}

    async def _execute_charge(self, payment_id: str, amount: float, currency: str) -> bool:
        if self.transient_attempts_remaining > 0:
            self.transient_attempts_remaining -= 1
            raise TransientPaymentError("Gateway timeout (504 Gateway Timeout)")
        self._status_map[payment_id] = "succeeded"
        return True

    async def process_refund(self, payment_id: str, amount: float) -> bool:
        return True

    async def get_transaction_status(self, payment_id: str) -> Optional[str]:
        return self._status_map.get(payment_id, None)

class StripePaymentProvider(BasePaymentProvider):
    async def _execute_charge(self, payment_id: str, amount: float, currency: str) -> bool:
        # Simulate transient and permanent failures
        if random.random() < 0.1:
            raise TransientPaymentError("Stripe 503 Service Unavailable")
        if random.random() < 0.05:
            raise PermanentPaymentError("Stripe: card declined")
        return True

    async def process_refund(self, payment_id: str, amount: float) -> bool:
        return True

    async def ping(self) -> bool:
        # Real implementation would hit Stripe's /health endpoint.
        return True
