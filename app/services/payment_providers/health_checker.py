"""Active health-check polling for provider recovery (no circuit breaker).
References:
- Health checks: https://microservices.io/patterns/observability/health-check.html
- Prometheus: Gauge metric for health status.
"""
import asyncio
import logging
import re
from prometheus_client import Gauge
from app.services.payment_providers.base import BasePaymentProvider

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
                is_healthy = await self._probe_provider_health(provider_key)
                PROVIDER_HEALTH_GAUGE.labels(provider=provider_key).set(1 if is_healthy else 0)
                if is_healthy:
                    logger.debug(f"Provider '{provider_key}' is healthy")
                else:
                    logger.warning(f"Provider '{provider_key}' is unhealthy")
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
