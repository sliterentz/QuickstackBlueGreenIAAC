#!/bin/bash
set +e  # Don't exit on error, we want to collect diagnostics

# Arguments
VM_NAME="$1"
VM_HOSTNAME="$2"
SANITIZED_HOSTNAME="$3"
RAW_IP_ADDRESS="$4"
NODE_IP="$5"
SSH_USER="$6"
NETWORK_NAME="${7:-default}"
POOL_NAME="${8:-k3s_infra_pool}"

# Redirect detailed output to log file
LOG_FILE="${LOG_FILE:-.health_check.log}"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Deployment Health Check ==="
echo "Timestamp: $(date)"
echo "VM Name: $VM_NAME"
echo "Hostname: $VM_HOSTNAME"
echo "Sanitized Name: $SANITIZED_HOSTNAME"

# FIXED: Extract IP properly if not already done
if [ -z "$NODE_IP" ] && [ -n "$RAW_IP_ADDRESS" ]; then
  # Extract IP from CIDR notation if present
  NODE_IP=$(echo "$RAW_IP_ADDRESS" | cut -d'/' -f1)
  echo "Extracted Node IP: $NODE_IP"
fi

TARGET_IP="$NODE_IP"
MAX_WAIT=300  # 5 minutes
ELAPSED=0

# Validate variables
if [ -z "$VM_NAME" ]; then
  echo "✗ CRITICAL: VM_NAME is empty"
  exit 1
fi

echo "VM Name to check: $VM_NAME"
echo ""

# ========================================================================
# PHASE 0: LIBVIRT CONNECTION CHECK
# ========================================================================
echo "=== Phase 0: Libvirt Connection Check ==="

# Check if we can connect to libvirt
if ! virsh version >/dev/null 2>&1; then
  echo "✗ Cannot connect to libvirt"
  echo "Checking libvirt service status..."
  sudo systemctl status libvirtd --no-pager || true
  echo ""
  echo "Attempting to start libvirtd..."
  sudo systemctl start libvirtd || true
  sleep 3
  
  if ! virsh version >/dev/null 2>&1; then
    echo "✗ Still cannot connect to libvirt"
    exit 1
  fi
fi

echo "✓ Libvirt connection OK"
echo "Libvirt version: $(virsh version | head -1)"
echo ""

# ========================================================================
# PHASE 1: VM EXISTENCE AND STATE CHECK
# ========================================================================
echo "=== Phase 1: VM Existence Check ==="

VIRSH_CMD="virsh"
if ! virsh list --all >/dev/null 2>&1; then
  echo "⚠ Permission denied, trying with sudo..."
  VIRSH_CMD="sudo virsh"
fi

echo "Listing all VMs..."
$VIRSH_CMD list --all
echo ""

VM_EXISTS=false
if $VIRSH_CMD list --all --name | grep -q "^$VM_NAME$"; then
  VM_EXISTS=true
  echo "✓ VM '$VM_NAME' exists"
else
  echo "✗ CRITICAL: VM '$VM_NAME' not found in virsh list"
  echo ""
  echo "Available VMs:"
  $VIRSH_CMD list --all --name
  echo ""
  
  # Check if VM was just created
  echo "Waiting 10 seconds for VM to register..."
  sleep 10
  
  if $VIRSH_CMD list --all --name | grep -q "^$VM_NAME$"; then
    VM_EXISTS=true
    echo "✓ VM '$VM_NAME' now exists"
  else
    echo "✗ VM still not found after waiting"
    exit 1
  fi
fi

# ========================================================================
# PHASE 2: WAIT FOR VM TO START
# ========================================================================
echo ""
echo "=== Phase 2: Waiting for VM to Start ==="
echo "Waiting up to $MAX_WAIT seconds..."

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if $VIRSH_CMD list --state-running --name | grep -q "^$VM_NAME$"; then
    echo "✓ VM is running (waited $ELAPSED seconds)"
    break
  fi
  
  # Check VM state
  VM_STATE=$($VIRSH_CMD domstate "$VM_NAME" 2>/dev/null || echo "unknown")
  
  if [ "$VM_STATE" = "shut off" ] || [ "$VM_STATE" = "crashed" ]; then
    echo "⚠ VM is in '$VM_STATE' state, attempting to start..."
    $VIRSH_CMD start "$VM_NAME" 2>&1 || true
    sleep 5
  fi
  
  if [ $((ELAPSED % 10)) -eq 0 ]; then
    echo "  Still waiting... ($ELAPSED/$MAX_WAIT seconds) - State: $VM_STATE"
  fi
  
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# Final check
if ! $VIRSH_CMD list --state-running --name | grep -q "^$VM_NAME$"; then
  echo "✗ VM failed to start within $MAX_WAIT seconds"
  exit 1
fi

# ========================================================================
# PHASE 3: VM DETAILS AND DIAGNOSTICS
# ========================================================================
echo ""
echo "=== Phase 3: VM Details ==="

echo "VM State:"
$VIRSH_CMD domstate "$VM_NAME"
echo ""

echo "VM Info:"
$VIRSH_CMD dominfo "$VM_NAME" | grep -E "(State|CPU|Memory|UUID)"
echo ""

# ========================================================================
# PHASE 4: NETWORK CONNECTIVITY CHECK (IMPROVED IP DISCOVERY)
# ========================================================================
echo "=== Phase 4: Network Connectivity ==="

get_vm_ip() {
  local vm="$1"
  local ip=""
  
  # 1) virsh domifaddr (source: agent) - Most reliable if agent is running
  # FILTERED to exclude localhost/loopback
  ip=$($VIRSH_CMD domifaddr "$vm" --source agent 2>/dev/null | grep -oP '(\d+\.){3}\d+' | grep -v '127.0.0.1' | head -1)
  
  if [[ -z "$ip" ]]; then
    # 2) virsh domifaddr (source: lease) - Good for DHCP
    ip=$($VIRSH_CMD domifaddr "$vm" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | grep -v '127.0.0.1' | head -1)
  fi
  
  if [[ -z "$ip" ]]; then
    # 3) dnsmasq leases directly
    # Find the MAC address first
    local mac=$($VIRSH_CMD domiflist "$vm" | grep -oP '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    if [[ -n "$mac" ]]; then
        ip=$(grep "$mac" /var/lib/libvirt/dnsmasq/*.leases 2>/dev/null | awk '{print $3}' | head -1)
    fi
  fi
  
  if [[ -z "$ip" ]]; then
    # 4) fallback: arp scan on virbr0 (requires arp-scan or arp)
    local mac=$($VIRSH_CMD domiflist "$vm" | grep -oP '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
    if [[ -n "$mac" ]]; then
        ip=$(arp -an | grep "$mac" | awk '{print $2}' | tr -d '()' | head -1)
    fi
  fi
  
  echo "$ip"
}

if [ -z "$TARGET_IP" ]; then
  echo "⚠ No static IP configured, attempting to detect..."
  echo ""
  
  # Try loop to get IP
  IP_WAIT=0
  IP_MAX_WAIT=120
  
  while [ $IP_WAIT -lt $IP_MAX_WAIT ]; do
    DETECTED_IP=$(get_vm_ip "$VM_NAME")
    
    if [ -n "$DETECTED_IP" ]; then
      echo "✓ Detected IP: $DETECTED_IP"
      TARGET_IP="$DETECTED_IP"
      break
    fi
    
    if [ $((IP_WAIT % 10)) -eq 0 ]; then
      echo "  Waiting for IP address... ($IP_WAIT/$IP_MAX_WAIT seconds)"
    fi
    
    sleep 5
    IP_WAIT=$((IP_WAIT + 5))
  done
  
  if [ -z "$TARGET_IP" ]; then
    echo "⚠ Could not detect IP address automatically after $IP_MAX_WAIT seconds"
    echo "The VM may be using DHCP and the IP is not yet assigned."
    echo "Please wait a few moments and check manually: virsh domifaddr $VM_NAME"
  fi
fi

if [ -n "$TARGET_IP" ]; then
  echo ""
  echo "Testing connectivity to $TARGET_IP..."
  
  # Wait for network to be ready
  NETWORK_WAIT=0
  NETWORK_MAX_WAIT=120
  NETWORK_READY=false
  
  while [ $NETWORK_WAIT -lt $NETWORK_MAX_WAIT ]; do
    if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
      echo "✓ Network is reachable (waited $NETWORK_WAIT seconds)"
      NETWORK_READY=true
      break
    fi
    
    if [ $((NETWORK_WAIT % 10)) -eq 0 ]; then
      echo "  Waiting for network... ($NETWORK_WAIT/$NETWORK_MAX_WAIT seconds)"
    fi
    
    sleep 2
    NETWORK_WAIT=$((NETWORK_WAIT + 2))
  done
  
  if [ "$NETWORK_READY" = false ]; then
    echo "✗ Network not reachable after $NETWORK_MAX_WAIT seconds"
  fi
fi

# ========================================================================
# PHASE 5: CLOUD-INIT STATUS CHECK
# ========================================================================
echo ""
echo "=== Phase 5: Cloud-Init Status ==="

if [ -n "$TARGET_IP" ] && [ "$NETWORK_READY" = true ]; then
  echo "Checking cloud-init status..."
  echo "(This requires SSH access, may take a moment)"
  echo ""
  
  # Wait a bit for SSH to be ready
  sleep 10
  
  # Try to check cloud-init status via SSH
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
  
  if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "cloud-init status" 2>/dev/null; then
    echo "✓ Cloud-init status retrieved"
  else
    echo "⚠ Cannot retrieve cloud-init status yet"
    echo "  This is normal during initial boot"
  fi
else
  echo "⚠ Skipping cloud-init check (network not ready)"
fi

# ========================================================================
# PHASE 6: SSH CONNECTIVITY TEST
# ========================================================================
echo ""
echo "=== Phase 6: SSH Connectivity ==="

if [ -n "$TARGET_IP" ] && [ "$NETWORK_READY" = true ]; then
  echo "Testing SSH connectivity to $SSH_USER@$TARGET_IP..."
  
  SSH_WAIT=0
  SSH_MAX_WAIT=180  # 3 minutes for SSH to be ready
  SSH_READY=false
  
  while [ $SSH_WAIT -lt $SSH_MAX_WAIT ]; do
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
       "$SSH_USER@$TARGET_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
      echo "✓ SSH is accessible (waited $SSH_WAIT seconds)"
      SSH_READY=true
      break
    fi
    
    if [ $((SSH_WAIT % 15)) -eq 0 ]; then
      echo "  Waiting for SSH... ($SSH_WAIT/$SSH_MAX_WAIT seconds)"
      
      # Check if port 22 is open
      if [ $((SSH_WAIT % 30)) -eq 0 ]; then
        if nc -zv -w 2 "$TARGET_IP" 22 2>&1 | grep -q "succeeded\|open"; then
          echo "  Port 22 is open, SSH service may be starting..."
        else
          echo "  Port 22 not yet open..."
        fi
      fi
    fi
    
    sleep 3
    SSH_WAIT=$((SSH_WAIT + 3))
  done
  
  if [ "$SSH_READY" = false ]; then
    echo "✗ SSH not accessible after $SSH_MAX_WAIT seconds"
  fi
else
  echo "⚠ Skipping SSH test (network not ready)"
fi

# ========================================================================
# SUMMARY
# ========================================================================
echo ""
echo "=== Health Check Summary ==="
echo "VM Name: $VM_NAME"
echo "VM State: $($VIRSH_CMD domstate "$VM_NAME")"

if [ -n "$TARGET_IP" ]; then
  echo "IP Address: $TARGET_IP"
  
  if [ "$NETWORK_READY" = true ]; then
    echo "Network: ✓ Reachable"
  else
    echo "Network: ✗ Not reachable"
  fi
  
  if [ "$SSH_READY" = true ]; then
    echo "SSH: ✓ Accessible"
  else
    echo "SSH: ✗ Not accessible yet"
  fi
else
  echo "IP Address: Not configured/detected (DHCP pending)"
fi

echo ""
echo "=== Next Steps ==="
echo ""

if [ -n "$TARGET_IP" ] && [ "$SSH_READY" = true ]; then
  echo "✓ VM is ready for use!"
  echo "Connect to VM: ssh $SSH_USER@$TARGET_IP"
else
  echo "⚠ VM is running but SSH/Network issues detected"
  echo "Check logs: $LOG_FILE"
fi

exit 0
