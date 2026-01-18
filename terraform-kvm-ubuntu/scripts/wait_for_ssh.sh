#!/bin/bash
set +e

echo "=== Waiting for SSH to be Ready ==="
echo "This may take 2-5 minutes for cloud-init to complete..."
echo ""

VM_NAME="$1"
TARGET_IP="$2"
SSH_USER="$3"
SSH_KEY_PATH="${4:-/dev/null}" # Optional key path check
MAX_WAIT=600  # 10 minutes
ELAPSED=0

# Determine virsh command
VIRSH_CMD="virsh"
if ! virsh list --all >/dev/null 2>&1; then
  VIRSH_CMD="sudo virsh"
fi

# If no IP provided, try to detect it
if [ -z "$TARGET_IP" ]; then
  echo "⚠ No IP address configured, attempting to detect..."
  
  # Try to get IP from virsh
  for i in {1..30}; do
    # Try agent first
    # FILTERED to exclude localhost/loopback
    DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source agent 2>/dev/null | grep -oP '(\d+\.){3}\d+' | grep -v '127.0.0.1' | head -1)
    
    if [ -z "$DETECTED_IP" ]; then
        # Try lease
        DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | grep -v '127.0.0.1' | head -1)
    fi

    if [ -n "$DETECTED_IP" ]; then
      echo "✓ Detected IP: $DETECTED_IP"
      TARGET_IP="$DETECTED_IP"
      break
    fi
    
    echo "  Attempt $i/30: Waiting for IP address..."
    sleep 5
  done
  
  if [ -z "$TARGET_IP" ]; then
    echo "✗ Could not detect IP address"
    echo "Please check manually: $VIRSH_CMD domifaddr $VM_NAME"
    exit 1
  fi
fi

echo "Target: $SSH_USER@$TARGET_IP"
echo "Timeout: $MAX_WAIT seconds"
echo ""

# Wait for network first
echo "Waiting for network connectivity..."
NETWORK_READY=false

for i in {1..60}; do
  if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
    echo "✓ Network is reachable"
    NETWORK_READY=true
    break
  fi
  
  if [ $((i % 10)) -eq 0 ]; then
    echo "  Still waiting for network... ($i/60)"
  fi
  
  sleep 2
done

if [ "$NETWORK_READY" = false ]; then
  echo "✗ Network not reachable after 120 seconds"
  exit 1
fi

# Wait for SSH
echo ""
echo "Waiting for SSH service..."

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"
if [ "$SSH_KEY_PATH" != "/dev/null" ] && [ -f "$SSH_KEY_PATH" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY_PATH"
fi

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo 'SSH Ready'" >/dev/null 2>&1; then
    echo "✓ SSH is ready! (waited $ELAPSED seconds)"
    echo ""
    
    # Get system info
    echo "=== VM System Information ==="
    ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "hostname; uname -a; uptime" 2>/dev/null
    echo ""
    
    # Check cloud-init status
    echo "=== Cloud-Init Status ==="
    ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "cloud-init status" 2>/dev/null || echo "Cloud-init status not available"
    echo ""
    
    # Check if K3s is installed
    if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "command -v kubectl" >/dev/null 2>&1; then
      echo "=== K3s Status ==="
      ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "sudo kubectl get nodes 2>/dev/null" || echo "K3s not ready yet"
      echo ""
    fi
    
    echo "✓ VM is fully accessible via SSH"
    echo ""
    echo "Connect now:"
    echo "  ssh $SSH_USER@$TARGET_IP"
    
    exit 0
  fi
  
  if [ $((ELAPSED % 30)) -eq 0 ]; then
    echo "  Still waiting for SSH... ($ELAPSED/$MAX_WAIT seconds)"
    
    # Show what's happening
    if [ $((ELAPSED % 60)) -eq 0 ]; then
      echo "  Checking SSH port..."
      nc -zv -w 2 "$TARGET_IP" 22 2>&1 | grep -E "(succeeded|open)" || echo "    Port 22 not open yet"
    fi
  fi
  
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""
echo "✗ SSH not ready after $MAX_WAIT seconds"
echo ""
echo "Troubleshooting steps:"
echo "  1. Check VM console: $VIRSH_CMD console $VM_NAME"
echo "  2. Check cloud-init logs: ssh $SSH_USER@$TARGET_IP 'tail -100 /var/log/cloud-init-output.log'"
echo "  3. Check SSH service: ssh $SSH_USER@$TARGET_IP 'sudo systemctl status ssh'"
echo "  4. Check firewall: ssh $SSH_USER@$TARGET_IP 'sudo ufw status'"
echo ""
echo "The VM may still be completing cloud-init setup."
echo "Try connecting manually in a few minutes."

exit 1
