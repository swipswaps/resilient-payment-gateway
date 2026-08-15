"""slowapi Redis-backed rate limiter configuration.
References:
- slowapi documentation: https://slowapi.readthedocs.io/
- RFC 6585: "429 Too Many Requests" status code.
- OWASP Rate Limiting: https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html
"""
from slowapi import Limiter
from slowapi.util import get_remote_address
import redis

def create_limiter(redis_host: str = "localhost", redis_port: int = 6379) -> Limiter:
    try:
        r = redis.Redis(host=redis_host, port=redis_port, db=1, socket_connect_timeout=2)
        r.ping()
        storage_uri = f"redis://{redis_host}:{redis_port}/1"
    except redis.ConnectionError:
        storage_uri = "memory://"

    return Limiter(
        key_func=get_remote_address,
        storage_uri=storage_uri,
        strategy="moving-window",
    )
