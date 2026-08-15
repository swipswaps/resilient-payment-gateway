"""FastAPI application entry point with all middleware, telemetry, and lifespan."""
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from prometheus_client import make_asgi_app
from dishka.integrations.fastapi import setup_dishka

from app.core.ioc import container
from app.core.limiter import create_limiter
from app.core.logging import setup_logging
from app.middleware.audit import AuditLogMiddleware
from app.services.payment_providers.health_checker import health_checker
from app.services.scheduled_jobs import ScheduledJobRegistry
from app.core.scheduler import AsyncJobScheduler

setup_logging()
logger = logging.getLogger("audit")
logger.info("Payment gateway starting up")

limiter = create_limiter()

@asynccontextmanager
async def lifespan(app: FastAPI):
    await health_checker.start()
    scheduler = await container.get(AsyncJobScheduler)
    registry = await container.get(ScheduledJobRegistry)
    registry.register_all()
    await scheduler.start()
    logger.info("All background services started")
    yield
    await scheduler.stop()
    await health_checker.stop()
    await container.close()
    logger.info("Payment gateway shutting down")

app = FastAPI(title="Resilient Payment Gateway", version="1.0.0", lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

app.add_middleware(AuditLogMiddleware)

setup_dishka(container=container, app=app)

from app.api import payments, webhooks, metrics as metrics_router
app.include_router(payments.router, prefix="/api/v1")
app.include_router(webhooks.router, prefix="/api/v1")
app.include_router(metrics_router.router, prefix="/api/v1")
