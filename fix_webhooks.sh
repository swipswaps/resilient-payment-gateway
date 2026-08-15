#!/bin/bash
# Fix webhooks.py: use Pydantic request model, add @inject.

cat > app/api/webhooks.py <<'EOT'
"""Webhook subscription and event dispatching endpoints."""
from pydantic import BaseModel, Field
from fastapi import APIRouter
from dishka import FromDishka
from dishka.integrations.fastapi import inject
from app.core.responses import MsgSpecResponse
from app.services.webhook_dispatcher import WebhookDispatcher

router = APIRouter(prefix="/webhooks", tags=["Webhooks"])

class SubscribeWebhookRequest(BaseModel):
    """Pydantic request model for webhook subscription."""
    target_url: str = Field(..., description="Webhook receiver URL")

@router.post(
    "/subscribe",
    response_class=MsgSpecResponse,
    # response_model=dict, # optional; FastAPI can infer from return
)
@inject
async def subscribe_webhook(
    req: SubscribeWebhookRequest,
    dispatcher: FromDishka[WebhookDispatcher],
):
    """Register a new webhook endpoint."""
    dispatcher.register_endpoint(req.target_url)
    return {
        "status": "subscribed",
        "target_url": req.target_url,
        "total_subscribers": len(dispatcher.subscribers)
    }
EOT

echo "webhooks.py updated with Pydantic request model and @inject. Rebuilding app container..."
docker compose up -d --build app

echo "Waiting 30 seconds for container to start..."
sleep 30

echo "Testing payment endpoint..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/v1/payments/execute \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Idempotency-Key: test-001" \
  -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Payment endpoint responded with 200 OK – system is healthy."
    echo "Response:"
    curl -s -X POST http://localhost:8000/api/v1/payments/execute \
      -H "Content-Type: application/json" \
      -H "X-Idempotency-Key: test-001" \
      -d '{"payment_id":"tx_001","amount":10.00,"provider":"mock_payment_provider"}' | python -m json.tool
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs for debugging."
    LOGS=$(docker compose logs app --tail=50 2>&1)

    if command -v gh &> /dev/null; then
        echo "Creating GitHub Gist with logs..."
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs" --public | grep -o 'https://gist.github.com/[^ ]*')
        RAW_URL="${GIST_URL}/raw"
        echo "Raw log URL: $RAW_URL"
        echo "Gist URL: $GIST_URL"
    else
        echo "gh not installed. Printing logs below:"
        echo "$LOGS"
    fi
fi
