"""Provider fallback chain and metrics.
References:
- Circuit Breaker pattern (Fowler).
- OWASP: Resilience and failover.
"""
import logging
from typing import List, Dict
from prometheus_client import Counter

logger = logging.getLogger(__name__)

PAYMENT_FALLBACK_TOTAL = Counter(
    "payment_provider_fallback_total",
    "Total provider failover attempts triggered by open circuits or transient failures",
    ["primary_provider", "fallback_provider"]
)

DEFAULT_PROVIDER_CHAIN: Dict[str, List[str]] = {
    "stripe_payment_provider": ["paypal_payment_provider", "mock_payment_provider"],
    "paypal_payment_provider": ["stripe_payment_provider", "mock_payment_provider"],
    "mock_payment_provider": []
}

def get_provider_chain(primary_provider: str) -> List[str]:
    fallbacks = DEFAULT_PROVIDER_CHAIN.get(primary_provider, [])
    return [primary_provider] + fallbacks
