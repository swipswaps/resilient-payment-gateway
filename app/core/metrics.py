"""Prometheus metrics for payment transactions, latency, and idempotency.
References:
- Prometheus client: https://github.com/prometheus/client_python
- RFC 2119: "SHOULD" for metrics naming.
"""
from prometheus_client import Counter, Histogram

PAYMENT_TRANSACTIONS_TOTAL = Counter(
    "payment_transactions_total",
    "Total count of processed payment transactions",
    ["provider", "status"]
)

PAYMENT_EXECUTION_LATENCY = Histogram(
    "payment_execution_duration_seconds",
    "Duration of payment provider charge processing in seconds",
    ["provider"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
)

IDEMPOTENCY_CACHE_REQUESTS_TOTAL = Counter(
    "idempotency_cache_requests_total",
    "Total number of idempotency key evaluations tagged by cache hit status",
    ["hit"]
)
