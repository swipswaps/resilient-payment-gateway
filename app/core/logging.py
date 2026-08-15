"""Structured logging configuration for audit trail.
References:
- Python logging HOWTO: https://docs.python.org/3/howto/logging.html
- RFC 5424: Structured syslog format.
- 12‑Factor App: Logs as event streams.
"""
import logging
import sys
from pythonjsonlogger import jsonlogger

def setup_logging():
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    formatter = jsonlogger.JsonFormatter(
        fmt='%(asctime)s %(levelname)s %(correlation_id)s %(message)s',
        datefmt='%Y-%m-%dT%H:%M:%SZ',
        json_ensure_ascii=False
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    audit_logger = logging.getLogger("audit")
    audit_logger.propagate = True
