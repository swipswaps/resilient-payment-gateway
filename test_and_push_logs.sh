#!/bin/bash
# Test endpoint and push logs to Gist.

echo "🔍 Testing payment endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ SUCCESS – endpoint responded with 200 OK."
    echo "Response:"
    curl -s -X POST http://localhost:8000/api/v1/payments/execute \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-001" \
      -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' | python -m json.tool

    echo "📋 Container logs (last 20 lines):"
    docker compose logs app --tail=20
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs."
    LOGS=$(docker compose logs app --tail=50 2>&1)

    if [ -z "$LOGS" ]; then
        echo "⚠️  No logs available. Container may still be starting or logging to a file."
        echo "Container status:"
        docker compose ps
        echo "Attempting to tail logs in real-time (press Ctrl+C to stop)..."
        timeout 10 docker compose logs -f app || true
    else
        echo "📤 Pushing logs to Gist..."
        if command -v gh &> /dev/null; then
            GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (HTTP $HTTP_CODE)" --public | grep -o 'https://gist.github.com/[^ ]*')
            if [ -n "$GIST_URL" ]; then
                echo "Raw log URL: ${GIST_URL}/raw"
                echo "Gist URL: $GIST_URL"
            else
                echo "⚠️  Gist creation failed – printing logs below:"
                echo "$LOGS"
            fi
        else
            echo "⚠️  gh not installed – printing logs:"
            echo "$LOGS"
        fi
    fi
fi
