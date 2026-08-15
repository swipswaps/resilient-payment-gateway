#!/bin/bash
# Full diagnostic script with gates, logs, and endpoint test.

echo "=========================================="
echo "GATE 1: Container Status"
echo "=========================================="
docker compose ps
echo ""

echo "=========================================="
echo "GATE 2: App Container Logs (last 50 lines)"
echo "=========================================="
docker compose logs app --tail=50
echo ""

echo "=========================================="
echo "GATE 3: Endpoint Health Check"
echo "=========================================="
RESPONSE=$(curl -s -X POST http://localhost:8000/api/v1/payments/execute \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>&1)

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Endpoint responded with 200 OK – system is healthy."
    echo "Response: $RESPONSE"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "❌ Endpoint unreachable – container likely crashed or not listening."
    echo "Curl error: $RESPONSE"
else
    echo "⚠️  Endpoint returned HTTP $HTTP_CODE – check logs above."
    echo "Response: $RESPONSE"
fi

echo ""
echo "=========================================="
echo "GATE 4: Full Logs (if endpoint failed)"
echo "=========================================="
if [ "$HTTP_CODE" != "200" ]; then
    echo "--- Full app logs ---"
    docker compose logs app
fi
