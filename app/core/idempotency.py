"""Redis-backed idempotency service.
References:
- RFC 7231: HTTP idempotent methods.
- OWASP: Idempotency key best practices.
"""
import json
from typing import Optional, Tuple
import redis.asyncio as aioredis

class IdempotencyService:
    def __init__(self, redis_client: aioredis.Redis, ttl_seconds: int = 86400):
        self.redis = redis_client
        self.ttl = ttl_seconds

    def _redis_key(self, idempotency_key: str) -> str:
        return f"idempotency:{idempotency_key}"

    async def get_cached_response(self, idempotency_key: str) -> Optional[Tuple[int, dict]]:
        data = await self.redis.get(self._redis_key(idempotency_key))
        if data:
            # Redis with decode_responses=True returns str, not bytes
            if isinstance(data, bytes):
                data = data.decode("utf-8")
            payload = json.loads(data)
            return payload["status_code"], payload["body"]
        return None

    async def lock_and_check(self, idempotency_key: str) -> bool:
        lock_key = f"lock:{idempotency_key}"
        acquired = await self.redis.set(lock_key, "1", nx=True, ex=30)
        return bool(acquired)

    async def save_response(self, idempotency_key: str, status_code: int, body: dict) -> None:
        payload = json.dumps({"status_code": status_code, "body": body})
        await self.redis.set(self._redis_key(idempotency_key), payload, ex=self.ttl)
        await self.redis.delete(f"lock:{idempotency_key}")
