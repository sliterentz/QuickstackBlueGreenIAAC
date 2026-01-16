#!/bin/bash

# Configuration
NAMESPACE="${1:-n8n}"
KUBECONFIG="${2:-../kubeconfig}"

echo "Starting n8n deployment verification in namespace: $NAMESPACE"

# 1. Check Pod Status
echo "Checking Pod status..."
kubectl --kubeconfig=$KUBECONFIG get pods -n $NAMESPACE
PODS_RUNNING=$(kubectl --kubeconfig=$KUBECONFIG get pods -n $NAMESPACE --field-selector=status.phase=Running | wc -l)
if [ "$PODS_RUNNING" -lt 4 ]; then
  echo "WARNING: Expected at least 4 running pods (main, worker, webhook, redis, postgres), found $PODS_RUNNING"
else
  echo "SUCCESS: Pods are running."
fi

# 2. Check Services
echo "Checking Services..."
kubectl --kubeconfig=$KUBECONFIG get svc -n $NAMESPACE

# 3. Check Database Connection
echo "Verifying Database Connection..."
POSTGRES_POD=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE -l app=postgres -o jsonpath="{.items[0].metadata.name}")
if [ -z "$POSTGRES_POD" ]; then
  echo "ERROR: Postgres pod not found!"
else
  kubectl --kubeconfig=$KUBECONFIG exec -n $NAMESPACE $POSTGRES_POD -- pg_isready -U n8n_user
  if [ $? -eq 0 ]; then
    echo "SUCCESS: Postgres is ready and accepting connections."
  else
    echo "ERROR: Postgres connection failed."
  fi
fi

# 4. Check Redis Connection
echo "Verifying Redis Connection..."
REDIS_POD=$(kubectl --kubeconfig=$KUBECONFIG get pod -n $NAMESPACE -l app=redis -o jsonpath="{.items[0].metadata.name}")
if [ -z "$REDIS_POD" ]; then
  echo "ERROR: Redis pod not found!"
else
  kubectl --kubeconfig=$KUBECONFIG exec -n $NAMESPACE $REDIS_POD -- redis-cli ping
  if [ $? -eq 0 ]; then
    echo "SUCCESS: Redis responded PONG."
  else
    echo "ERROR: Redis connection failed."
  fi
fi

# 5. Check Ingress
echo "Checking Ingress..."
kubectl --kubeconfig=$KUBECONFIG get ingress -n $NAMESPACE

echo "Verification completed."
