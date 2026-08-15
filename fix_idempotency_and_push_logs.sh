#!/bin/bash
# Fix idempotency.py decode issue, rebuild, test, and push logs to Gist.

cat > app/core/idempotency.py <<'EOT'
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
EOT

echo "✅ idempotency.py fixed – handles both str and bytes from Redis."
echo "Rebuilding app container..."
docker compose up -d --build app

echo "Waiting 30 seconds for container to start..."
sleep 30

echo "🔍 Testing payment endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

echo "📤 Capturing logs and pushing to Gist..."
LOGS=$(docker compose logs app --tail=50 2>&1)
GIST_URL=""
if command -v gh &> /dev/null; then
    GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (fix_idempotency)" --public | grep -o 'https://gist.github.com/[^ ]*')
    if [ -n "$GIST_URL" ]; then
        echo "Raw log URL: ${GIST_URL}/raw"
        echo "Gist URL: $GIST_URL"
    else
        echo "⚠️  Gist creation failed."
    fi
else
    echo "⚠️  gh not installed – cannot push logs."
fi

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ SUCCESS – endpoint responded with 200 OK."
    echo "Response:"
    curl -s -X POST http://localhost:8000/api/v1/payments/execute \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-001" \
      -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' | python -m json.tool
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – check logs above."
fi
