#!/bin/bash
# Heredoc to fix zensical version – no sed, no placeholders.

cat > requirements.txt <<'EOT'
fastapi==0.115.0
uvicorn[standard]==0.30.0
httpx==0.27.0
msgspec==0.18.0
redis==5.0.8
tenacity==8.3.0
pybreaker==1.2.0
schedule==1.2.0
slowapi==0.1.9
prometheus-client==0.20.0
python-json-logger==2.0.7
boto3==1.34.0
hvac==1.2.0
pint==0.24.0
geopy==2.4.0
playwright==1.42.0
faker==20.0.0
autoregistry==0.3.0
python-statemachine==2.0.0
dishka[fastapi]==1.1.0
duckdb==0.10.0
mkdocs==1.5.0
zensical==0.0.54
complexify==1.0.0
EOT

cat > pyproject.toml <<'EOT'
[tool.poetry]
name = "payment-gateway"
version = "0.1.0"
description = "Resilient payment gateway with state machines, circuit breakers, and audit logging."
authors = ["Your Name <you@example.com>"]

[tool.poetry.dependencies]
python = "^3.10"
fastapi = "^0.115.0"
uvicorn = {extras = ["standard"], version = "^0.30.0"}
httpx = "^0.27.0"
msgspec = "^0.18.0"
redis = "^5.0.8"
tenacity = "^8.3.0"
pybreaker = "^1.2.0"
schedule = "^1.2.0"
slowapi = "^0.1.9"
prometheus-client = "^0.20.0"
python-json-logger = "^2.0.7"
boto3 = "^1.34.0"
hvac = "^1.2.0"
pint = "^0.24.0"
geopy = "^2.4.0"
playwright = "^1.42.0"
faker = "^20.0.0"
autoregistry = "^0.3.0"
python-statemachine = "^2.0.0"
dishka = {extras = ["fastapi"], version = "^1.1.0"}
duckdb = "^0.10.0"
mkdocs = "^1.5.0"
zensical = "^0.0.54"
complexify = "^1.0.0"

[tool.poetry.group.dev.dependencies]
pytest = "^7.4.0"
pytest-asyncio = "^0.21.0"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
EOT

cat > docker-compose.yml <<'EOT'
services:
  redis:
    image: redis:alpine
    ports:
      - "6379:6379"

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./prometheus/alerts:/etc/prometheus/alerts
    depends_on:
      - alertmanager

  alertmanager:
    image: prom/alertmanager:latest
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards
      - ./grafana/dashboards:/etc/grafana/provisioning/dashboards/json
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources
    depends_on:
      - prometheus

  app:
    build: .
    ports:
      - "8000:8000"
    depends_on:
      - redis
      - prometheus
    environment:
      - REDIS_URL=redis://redis:6379/0
EOT

echo "Files updated. Now rebuild with: docker compose up -d --build"
