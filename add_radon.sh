#!/bin/bash
# Add radon to requirements.txt and pyproject.toml

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
radon==6.0.1
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
radon = "^6.0.1"

[tool.poetry.group.dev.dependencies]
pytest = "^7.4.0"
pytest-asyncio = "^0.21.0"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
EOT

echo "radon added. Rebuild with: docker compose up -d --build"
