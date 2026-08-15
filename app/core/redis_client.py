"""Helper to access Redis client from app.state."""
from fastapi import FastAPI
import redis.asyncio as aioredis

def get_redis_client(app: FastAPI) -> aioredis.Redis:
    """Get Redis client from app.state."""
    return app.state.redis
