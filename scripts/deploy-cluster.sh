#!/bin/bash
set -e

# Setup Logging
LOG_FILE="deploy_$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== K3s Cluster Deployment Script ==="
echo "Logs are being saved to $LOG_FILE"

# Pre-flight Check
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/pre-flight-check.sh" ]; then
    bash "$SCRIPT_DIR/pre-flight-check.sh" || exit 1
else
    echo "Warning: pre-flight-check.sh not found."
fi

# Helper Functions
confirm_action() {
    read -p "$1 (y/n)? " choice
    case "$choice" in 
      y|Y ) echo "Proceeding...";;
      n|N ) echo "Aborted by user."; exit 1;;
      * ) echo "Invalid input."; exit 1;;
    esac
}

rollback_master() {
    echo "Deployment failed!"
    read -p "Do you want to destroy the Master resources created in this session? (y/n) " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Destroying resources..."
        terraform destroy -var-file="master.tfvars" -auto-approve
    else
        echo "Resources left intact for debugging."
    fi
}

# ------------------------------------------------
# Phase 1: Deploy Master Node
# ------------------------------------------------
echo "Deploying K3s Master Node..."
terraform workspace select master || terraform workspace new master

echo "Running Terraform Plan for Master..."
terraform plan -var-file="master.tfvars" -out=master.tfplan

echo "Please review the plan above."
if [ "$1" != "--yes" ]; then
    confirm_action "Do you want to apply the Master node plan?"
fi

if ! terraform apply "master.tfplan"; then
    rollback_master
    exit 1
fi

echo "Master node applied successfully. Waiting for services..."
# Note: k3s.tf now includes a 'wait_for_ssh' check, so the VM is definitely up.

# Ambil K3s token dari master
MASTER_IP=$(terraform output -raw vm_ip_configured)
echo "Master IP: $MASTER_IP"

# SSH ke master dan ambil token
echo "Retrieving K3s token from master..."
MAX_RETRIES=10
COUNT=0
K3S_TOKEN=""

# Retry logic for token retrieval (in case K3s is still starting up)
while [ $COUNT -lt $MAX_RETRIES ]; do
    if K3S_TOKEN=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$MASTER_IP "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null); then
        if [ -n "$K3S_TOKEN" ]; then
            break
        fi
    fi
    echo "Waiting for K3s token... ($((COUNT+1))/$MAX_RETRIES)"
    sleep 10
    COUNT=$((COUNT+1))
done

if [ -z "$K3S_TOKEN" ]; then
    echo "Error: Failed to retrieve K3s token. K3s might not be running."
    rollback_master
    exit 1
fi
echo "K3s Token retrieved successfully"

# ------------------------------------------------
# Phase 2: Deploy Worker Nodes
# ------------------------------------------------
for i in 1 2; do
  echo "Deploying Worker Node $i..."
  terraform workspace select worker-$i || terraform workspace new worker-$i
  
  terraform plan \
    -var-file="worker-$i.tfvars" \
    -var="k3s_server_url=https://$MASTER_IP:6443" \
    -var="k3s_token=$K3S_TOKEN" \
    -out="worker-$i.tfplan"

  if [ "$1" != "--yes" ]; then
      confirm_action "Do you want to apply the Worker $i plan?"
  fi
  
  if ! terraform apply "worker-$i.tfplan"; then
      echo "Worker $i deployment failed."
      read -p "Do you want to destroy worker-$i? (y/n) " w_choice
      if [[ "$w_choice" =~ ^[Yy]$ ]]; then
          terraform destroy \
            -var-file="worker-$i.tfvars" \
            -var="k3s_server_url=https://$MASTER_IP:6443" \
            -var="k3s_token=$K3S_TOKEN" \
            -auto-approve
      fi
      exit 1
  fi
done

echo "=== Cluster Deployment Complete ==="
echo "Master IP: $MASTER_IP"
echo "Access cluster: ssh ubuntu@$MASTER_IP"
echo "Get kubeconfig: scp ubuntu@$MASTER_IP:/etc/rancher/k3s/k3s.yaml ."
