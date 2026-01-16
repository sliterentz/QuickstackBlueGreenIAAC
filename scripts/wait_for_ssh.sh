#!/bin/bash
set -e

HOST=$1
PORT=${2:-22}
TIMEOUT=${3:-300} # 5 minutes default timeout

if [ -z "$HOST" ]; then
  echo "Usage: $0 <host> [port] [timeout]"
  exit 1
fi

echo "Waiting for SSH on $HOST:$PORT to be available (Timeout: ${TIMEOUT}s)..."

START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
    echo "Timeout reached. SSH is not available on $HOST:$PORT."
    exit 1
  fi

  # Use timeout and bash /dev/tcp to check connection
  if timeout 2 bash -c "</dev/tcp/$HOST/$PORT" >/dev/null 2>&1; then
    echo "SUCCESS: SSH port $PORT on $HOST is open!"
    # Optional: Wait a few more seconds for the service to be fully ready
    sleep 5
    exit 0
  fi

  if [ $((ELAPSED_TIME % 30)) -eq 0 ] && [ $ELAPSED_TIME -ne 0 ]; then
    echo "Still waiting... ($ELAPSED_TIME/${TIMEOUT}s). Check if VM is running and IP $HOST is correct."
  fi
  sleep 5
done
