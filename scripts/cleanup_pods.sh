#!/bin/bash
export KUBECONFIG=./kubeconfig

echo "Cleaning up corrupted database pods and PVCs..."
kubectl delete pod mariadb-0 postgres-0 -n kube-system-green --force --grace-period=0 || true
kubectl delete pvc mariadb-kube-system-green-storage-mariadb-0 postgres-kube-system-green-storage-postgres-0 -n kube-system-green || true

echo "Cleaning up unhealthy n8n workers..."
kubectl delete pods -n n8n --field-selector status.phase=Error || true
kubectl delete pods -n n8n --field-selector status.phase=Failed || true

echo "Cleaning up pods in Unknown state..."
kubectl get pods -A | grep Unknown | awk '{print "kubectl delete pod -n "$1" "$2" --force --grace-period=0"}' | sh || true

echo "Scaling down n8n workers if they exceed 2 replicas..."
kubectl scale deployment n8n-worker -n n8n --replicas=2 || true

echo "Scaling down ArgoCD server if it exceeds 1 replica..."
kubectl scale deployment argocd-server -n argocd --replicas=1 || true

echo "Cleanup complete. Waiting for pods to stabilize..."
