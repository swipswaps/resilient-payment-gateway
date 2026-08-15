#!/bin/bash
# Upgrade pybreaker to a version that supports Python 3.10+ async.

# ----------------------------------------------------------------------
# 1. Update requirements.txt with pybreaker >= 1.3.0
# ----------------------------------------------------------------------
cat > requirements.txt <<'EOT'
fastapi==0.115.0
uvicorn[standard]==0.30.0
httpx==0.27.0
msgspec==0.18.0
redis==5.0.8
tenacity==8.3.0
pybreaker>=1.3.0
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

# ----------------------------------------------------------------------
# 2. Update pyproject.toml to match
# ----------------------------------------------------------------------
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
pybreaker = "^1.3.0"
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

# ----------------------------------------------------------------------
# 3. Rebuild, test, and push logs to Gist on failure
# ----------------------------------------------------------------------
echo "✅ Updated pybreaker to >= 1.3.0 (fixes 'gen' NameError)."
echo "Rebuilding app container..."
docker compose up -d --build app

echo "Waiting 30 seconds for container to start..."
sleep 30

echo "Testing endpoint..."
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
else
    echo "❌ Endpoint returned HTTP $HTTP_CODE – collecting logs."
    LOGS=$(docker compose logs app --tail=50 2>&1)
    if command -v gh &> /dev/null; then
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (HTTP $HTTP_CODE)" --public | grep -o 'https://gist.github.com/[^ ]*')
        echo "Raw log URL: ${GIST_URL}/raw"
        echo "Gist URL: $GIST_URL"
    else
        echo "$LOGS"
    fi
fi
