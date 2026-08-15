"""Webhook dispatcher with HMAC-SHA256 signing and Redis retry queue.
References:
- RFC 2104: HMAC (Keyed-Hashing for Message Authentication)
- RFC 7231: HTTP POST for event delivery.
- OWASP: Webhook security best practices.
"""
import hmac
import hashlib
import json
import logging
import time
from typing import Any, Dict, List, Optional
import httpx
import msgspec
import redis.asyncio as aioredis

logger = logging.getLogger(__name__)

class WebhookEventPayload(msgspec.Struct):
    event_type: str
    payment_id: str
    timestamp: float
    data: Dict[str, Any]

class WebhookDispatcher:
    def __init__(
        self,
        secret_key: str = "super-secret-webhook-key",
        redis_client: Optional[aioredis.Redis] = None,
    ):
        self.secret_key = secret_key
        self.subscribers: List[str] = []
        self.redis = redis_client

    def register_endpoint(self, url: str) -> None:
        if url not in self.subscribers:
            self.subscribers.append(url)

    def generate_signature(self, payload_bytes: bytes) -> str:
        return hmac.new(
            self.secret_key.encode("utf-8"),
            payload_bytes,
            hashlib.sha256,
        ).hexdigest()

    async def dispatch_event(
        self,
        event_type: str,
        payment_id: str,
        data: Dict[str, Any],
        target_urls: Optional[List[str]] = None,
    ) -> None:
        urls = target_urls or self.subscribers
        if not urls:
            return

        payload = WebhookEventPayload(
            event_type=event_type,
            payment_id=payment_id,
            timestamp=time.time(),
            data=data,
        )
        payload_bytes = msgspec.json.encode(payload)
        signature = self.generate_signature(payload_bytes)

        headers = {
            "Content-Type": "application/json",
            "X-Signature-256": signature,
            "X-Event-Type": event_type,
        }

        failed_urls: List[str] = []
        async with httpx.AsyncClient(timeout=5.0) as client:
            for url in urls:
                try:
                    await client.post(url, content=payload_bytes, headers=headers)
                except httpx.HTTPError:
                    failed_urls.append(url)

        if failed_urls and self.redis:
            await self._enqueue_retry(event_type, payment_id, data, failed_urls)

    async def _enqueue_retry(
        self,
        event_type: str,
        payment_id: str,
        data: Dict[str, Any],
        urls: List[str],
    ) -> None:
        item = {
            "event_type": event_type,
            "payment_id": payment_id,
            "data": data,
            "urls": urls,
            "timestamp": time.time(),
        }
        await self.redis.lpush("webhook:retry:queue", json.dumps(item))
        logger.warning(f"Queued webhook retry for {event_type}:{payment_id} ({len(urls)} endpoints)")
