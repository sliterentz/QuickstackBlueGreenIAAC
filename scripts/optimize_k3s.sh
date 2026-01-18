#!/bin/bash
set -e

echo "=== Starting K3s Cluster Optimization ==="

# 1. Fix Metrics Server (Add insecure-tls and resources)
echo "[1/3] Patching Metrics Server..."
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"},
  {"op": "add", "path": "/spec/template/spec/containers/0/resources", "value": {"requests": {"cpu": "100m", "memory": "70Mi"}, "limits": {"cpu": "200m", "memory": "200Mi"}}}
]' || echo "Metrics server patch failed or already applied"

# Force restart metrics server
kubectl delete pod -n kube-system -l k8s-app=metrics-server --wait=false

# 2. Optimize Traefik (Scale to 2, Add resources)
echo "[2/3] Optimizing Traefik..."
kubectl scale deployment traefik -n kube-system --replicas=2 || echo "Traefik deployment not found, skipping scale"
kubectl patch deployment traefik -n kube-system --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/resources", "value": {"requests": {"cpu": "200m", "memory": "100Mi"}, "limits": {"cpu": "500m", "memory": "500Mi"}}}
]' || echo "Traefik patch failed, skipping"

# Restart Helm jobs if Traefik is missing
if ! kubectl get deployment traefik -n kube-system >/dev/null 2>&1; then
  echo "Restarting Traefik Helm install jobs..."
  kubectl delete pod -n kube-system -l job-name=helm-install-traefik --wait=false || true
  kubectl delete pod -n kube-system -l job-name=helm-install-traefik-crd --wait=false || true
fi

# 3. Optimize CoreDNS (Scale to 2, Add resources)
echo "[3/3] Optimizing CoreDNS..."
kubectl scale deployment coredns -n kube-system --replicas=2
kubectl patch deployment coredns -n kube-system --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/resources", "value": {"requests": {"cpu": "100m", "memory": "70Mi"}, "limits": {"cpu": "200m", "memory": "170Mi"}}}
]'

echo "=== Waiting for deployments to stabilize ==="
kubectl rollout status deployment/metrics-server -n kube-system --timeout=60s || true
kubectl rollout status deployment/traefik -n kube-system --timeout=60s || true
kubectl rollout status deployment/coredns -n kube-system --timeout=60s || true

echo "=== Final Status ==="
kubectl get pod -n kube-system
kubectl top node || echo "Metrics API still initializing..."

echo "Optimization Complete!"
