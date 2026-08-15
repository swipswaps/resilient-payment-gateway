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
