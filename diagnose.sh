#!/bin/bash
# Diagnostic script with gates – checks container status, logs, and endpoint.
echo "=== GATE 1: Container Status ==="
docker compose ps
echo ""

echo "=== GATE 2: App Container Logs (last 50 lines) ==="
docker compose logs app --tail=50
echo ""

echo "=== GATE 3: Endpoint Health Check ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Endpoint responded with 200 OK – system is healthy."
elif [ "$HTTP_CODE" = "000" ]; then
    echo "❌ Endpoint unreachable – container likely crashed or not listening."
else
    echo "⚠️  Endpoint returned HTTP $HTTP_CODE – check logs above."
fi
