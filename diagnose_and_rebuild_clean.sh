#!/bin/bash
# Clean rebuild with full diagnostics.

echo "🔄 Stopping and removing all containers..."
docker compose down -v

echo "🔄 Clean rebuilding app with --no-cache..."
docker compose build --no-cache app
docker compose up -d

echo "⏳ Waiting 15 seconds for container to start..."
sleep 15

echo "📊 Container status:"
docker compose ps

echo "📋 Recent logs (last 50 lines):"
LOGS=$(docker compose logs app --tail=50 2>&1)
echo "$LOGS"

if [ -z "$LOGS" ]; then
    echo "⚠️  No logs found – container may have exited immediately."
    echo "Checking container exit status..."
    docker compose ps -a | grep app
    echo "Full docker ps -a:"
    docker ps -a | grep app
else
    echo "📤 Pushing logs to Gist..."
    if command -v gh &> /dev/null; then
        GIST_URL=$(echo "$LOGS" | gh gist create - -d "Payment gateway app logs (diagnostic)" --public | grep -o 'https://gist.github.com/[^ ]*')
        if [ -n "$GIST_URL" ]; then
            echo "Raw log URL: ${GIST_URL}/raw"
            echo "Gist URL: $GIST_URL"
        else
            echo "⚠️  Gist creation failed – printing logs below:"
            echo "$LOGS"
        fi
    else
        echo "⚠️  gh not installed – printing logs:"
        echo "$LOGS"
    fi
fi

echo "✅ Diagnostic complete. If the container is not running, share the logs above."
