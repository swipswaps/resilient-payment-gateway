"""Async bridge for schedule library with Redis distributed locking and retries.
References:
- schedule library: https://schedule.readthedocs.io/
- Redis SETNX for distributed locks: https://redis.io/docs/manual/patterns/distributed-locks/
- RFC 2119: "MUST" for lock acquisition.
"""
import asyncio
import functools
import json
import logging
import time
from typing import Any, Callable, Optional
import redis.asyncio as aioredis
import schedule

logger = logging.getLogger(__name__)

class AsyncJobScheduler:
    def __init__(self, redis_client: aioredis.Redis, check_interval: float = 1.0):
        self.redis = redis_client
        self.check_interval = check_interval
        self._task: Optional[asyncio.Task] = None
        self._running = False

    def schedule_every(
        self,
        interval_seconds: int,
        job_id: str,
        lock_timeout: int = 60,
        max_retries: int = 3,
    ) -> Callable:
        def decorator(async_func: Callable[..., Any]) -> Callable[..., Any]:
            @functools.wraps(async_func)
            def sync_trigger():
                try:
                    loop = asyncio.get_running_loop()
                    loop.create_task(
                        self._run_locked_job(async_func, job_id, lock_timeout, max_retries)
                    )
                except RuntimeError:
                    logger.error(f"No event loop available to trigger job {job_id}")

            schedule.every(interval_seconds).seconds.do(sync_trigger)
            return async_func
        return decorator

    async def _run_locked_job(
        self,
        async_func: Callable,
        job_id: str,
        lock_timeout: int,
        max_retries: int,
    ) -> None:
        lock_key = f"scheduler:lock:{job_id}"
        acquired = await self.redis.set(lock_key, "1", nx=True, ex=lock_timeout)
        if not acquired:
            logger.debug(f"Job {job_id} skipped: lock held by another worker")
            return

        try:
            for attempt in range(1, max_retries + 1):
                try:
                    await async_func()
                    await self.redis.set(
                        f"scheduler:last_run:{job_id}",
                        json.dumps({"timestamp": time.time(), "status": "success"}),
                    )
                    logger.info(f"Job {job_id} completed successfully")
                    return
                except Exception as exc:
                    logger.warning(f"Job {job_id} attempt {attempt}/{max_retries} failed: {exc}")
                    if attempt < max_retries:
                        await asyncio.sleep(2 ** attempt)
                    else:
                        await self.redis.set(
                            f"scheduler:last_run:{job_id}",
                            json.dumps({"timestamp": time.time(), "status": "failed", "error": str(exc)}),
                        )
                        logger.error(f"Job {job_id} exhausted all retries")
        finally:
            await self.redis.delete(lock_key)

    async def start(self) -> None:
        self._running = True
        self._task = asyncio.create_task(self._loop())
        logger.info("AsyncJobScheduler started")

    async def stop(self) -> None:
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        schedule.clear()
        logger.info("AsyncJobScheduler stopped")

    async def _loop(self) -> None:
        while self._running:
            try:
                schedule.run_pending()
            except Exception as exc:
                logger.error(f"Scheduler loop error: {exc}")
            await asyncio.sleep(self.check_interval)
