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
SSH_KEY_PATH="${9:-}"
SSH_PORT="${10:-22}"

# Redirect detailed output to log file
LOG_FILE="${LOG_FILE:-.health_check.log}"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Deployment Health Check ==="
echo "Timestamp: $(date)"
echo "VM Name: $VM_NAME"
echo "Hostname: $VM_HOSTNAME"
echo "Sanitized Name: $SANITIZED_HOSTNAME"

NETWORK_MAX_WAIT="${NETWORK_MAX_WAIT:-120}"
SSH_PORT_MAX_WAIT="${SSH_PORT_MAX_WAIT:-240}"
SSH_AUTH_MAX_WAIT="${SSH_AUTH_MAX_WAIT:-300}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_ATTEMPT_TIMEOUT="${SSH_ATTEMPT_TIMEOUT:-20}"
SSH_CHECK_INTERVAL="${SSH_CHECK_INTERVAL:-5}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-no}"
SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-/dev/null}"

classify_ssh_error() {
  local msg="${1:-}"
  msg=$(echo "$msg" | tr -d '\r')
  if echo "$msg" | grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"; then
    echo "host_key_verification_failed"
  elif echo "$msg" | grep -qiE "Permission denied"; then
    echo "permission_denied"
  elif echo "$msg" | grep -qiE "No route to host|Network is unreachable|Destination Host Unreachable"; then
    echo "network_unreachable"
  elif echo "$msg" | grep -qiE "Connection refused"; then
    echo "connection_refused"
  elif echo "$msg" | grep -qiE "Connection timed out|Operation timed out|timed out"; then
    echo "connection_timeout"
  elif echo "$msg" | grep -qiE "Could not resolve hostname|Temporary failure in name resolution|Name or service not known"; then
    echo "dns_failure"
  elif echo "$msg" | grep -qiE "No such file or directory"; then
    echo "file_missing"
  elif echo "$msg" | grep -qiE "bad permissions"; then
    echo "key_bad_permissions"
  else
    echo "unknown"
  fi
}

tcp_probe() {
  local host="${1:-}"
  local port="${2:-22}"
  local timeout_s="${3:-5}"
  timeout "$timeout_s" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>&1
}

build_ssh_opts() {
  local opts=""
  opts="$opts -F /dev/null"
  opts="$opts -o StrictHostKeyChecking=$SSH_STRICT_HOST_KEY_CHECKING"
  opts="$opts -o UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE"
  opts="$opts -o ConnectTimeout=$SSH_CONNECT_TIMEOUT"
  opts="$opts -o ServerAliveInterval=5"
  opts="$opts -o ServerAliveCountMax=3"
  opts="$opts -o BatchMode=yes"
  opts="$opts -o IdentitiesOnly=yes"
  opts="$opts -o PreferredAuthentications=publickey"
  opts="$opts -o LogLevel=ERROR"
  if [ -n "$SSH_KEY_PATH" ]; then
    if [ -f "$SSH_KEY_PATH" ]; then
      local key_perms=""
      key_perms=$(stat -c "%a" "$SSH_KEY_PATH" 2>/dev/null || stat -f "%Lp" "$SSH_KEY_PATH" 2>/dev/null)
      if [ -n "$key_perms" ] && [ "$key_perms" != "600" ] && [ "$key_perms" != "400" ]; then
        chmod 600 "$SSH_KEY_PATH" 2>/dev/null || true
      fi
      opts="$opts -i $SSH_KEY_PATH"
    else
      echo "⚠ SSH key path provided but file not found: $SSH_KEY_PATH" >&2
    fi
  fi
  echo "$opts"
}

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
LIBVIRT_URI="qemu:///system"
VIRSH_CMD="virsh -c $LIBVIRT_URI"

if ! $VIRSH_CMD version >/dev/null 2>&1; then
  echo "✗ Cannot connect to libvirt as current user (no sudo fallback)"
  echo "  Try: virsh -c qemu:///system version"
  exit 1
fi

echo "✓ Libvirt connection OK"
echo "Libvirt version: $($VIRSH_CMD version | head -1)"
echo ""

# ========================================================================
# PHASE 1: VM EXISTENCE AND STATE CHECK
# ========================================================================
echo "=== Phase 1: VM Existence Check ==="

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
  NETWORK_READY=false
  LAST_NETWORK_CLASS=""
  LAST_NETWORK_DETAIL=""
  
  while [ $NETWORK_WAIT -lt $NETWORK_MAX_WAIT ]; do
    if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
      echo "✓ Network is reachable (waited $NETWORK_WAIT seconds)"
      NETWORK_READY=true
      break
    fi
    
    TCP_DETAIL=$(tcp_probe "$TARGET_IP" "$SSH_PORT" 3)
    TCP_RC=$?
    if [ $TCP_RC -eq 0 ]; then
      echo "✓ Network is reachable (TCP $SSH_PORT open) (waited $NETWORK_WAIT seconds)"
      NETWORK_READY=true
      break
    fi
    TCP_CLASS=$(classify_ssh_error "$TCP_DETAIL")
    if [ "$TCP_CLASS" = "connection_refused" ]; then
      echo "✓ Network is reachable (TCP reachable, port refused) (waited $NETWORK_WAIT seconds)"
      NETWORK_READY=true
      break
    fi
    LAST_NETWORK_CLASS="$TCP_CLASS"
    LAST_NETWORK_DETAIL="$TCP_DETAIL"

    if [ $((NETWORK_WAIT % 10)) -eq 0 ]; then
      echo "  Waiting for network... ($NETWORK_WAIT/$NETWORK_MAX_WAIT seconds)"
      if [ -n "$LAST_NETWORK_CLASS" ] && [ "$LAST_NETWORK_CLASS" != "unknown" ]; then
        echo "  Last TCP probe: $LAST_NETWORK_CLASS"
      fi
    fi
    
    sleep 2
    NETWORK_WAIT=$((NETWORK_WAIT + 2))
  done
  
  if [ "$NETWORK_READY" = false ]; then
    echo "✗ Network not reachable after $NETWORK_MAX_WAIT seconds"
    if [ -n "$LAST_NETWORK_DETAIL" ]; then
      echo "  Last TCP probe detail: $(echo "$LAST_NETWORK_DETAIL" | head -1)"
    fi
    ip route get "$TARGET_IP" 2>/dev/null | sed 's/^/  Route: /' || true
    
    DETECTED_IP=$(get_vm_ip "$VM_NAME")
    if [ -n "$DETECTED_IP" ] && [ "$DETECTED_IP" != "$TARGET_IP" ]; then
      echo "⚠ Detected IP differs from configured IP"
      echo "  Configured: $TARGET_IP"
      echo "  Detected:   $DETECTED_IP"
      TARGET_IP="$DETECTED_IP"
      echo ""
      echo "Retrying connectivity check to detected IP..."
      
      NETWORK_WAIT=0
      NETWORK_READY=false
      LAST_NETWORK_CLASS=""
      LAST_NETWORK_DETAIL=""
      while [ $NETWORK_WAIT -lt $NETWORK_MAX_WAIT ]; do
        if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
          echo "✓ Network is reachable (waited $NETWORK_WAIT seconds)"
          NETWORK_READY=true
          break
        fi
        TCP_DETAIL=$(tcp_probe "$TARGET_IP" "$SSH_PORT" 3)
        TCP_RC=$?
        if [ $TCP_RC -eq 0 ]; then
          echo "✓ Network is reachable (TCP $SSH_PORT open) (waited $NETWORK_WAIT seconds)"
          NETWORK_READY=true
          break
        fi
        TCP_CLASS=$(classify_ssh_error "$TCP_DETAIL")
        if [ "$TCP_CLASS" = "connection_refused" ]; then
          echo "✓ Network is reachable (TCP reachable, port refused) (waited $NETWORK_WAIT seconds)"
          NETWORK_READY=true
          break
        fi
        LAST_NETWORK_CLASS="$TCP_CLASS"
        LAST_NETWORK_DETAIL="$TCP_DETAIL"
        sleep 2
        NETWORK_WAIT=$((NETWORK_WAIT + 2))
      done
    fi
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
  SSH_OPTS="$(build_ssh_opts)"
  CLOUDINIT_OUT=$(timeout "$SSH_ATTEMPT_TIMEOUT" ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "cloud-init status 2>/dev/null" 2>&1)
  if echo "$CLOUDINIT_OUT" | grep -q "status:"; then
    echo "$CLOUDINIT_OUT"
    echo "✓ Cloud-init status retrieved"
  else
    CLOUDINIT_CLASS=$(classify_ssh_error "$CLOUDINIT_OUT")
    echo "⚠ Cannot retrieve cloud-init status yet ($CLOUDINIT_CLASS)"
    if [ -n "$CLOUDINIT_OUT" ]; then
      echo "  Detail: $(echo "$CLOUDINIT_OUT" | head -1)"
    fi
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
  SSH_OPTS="$(build_ssh_opts)"
  SSH_READY=false
  SSH_PORT_READY=false
  LAST_TCP_CLASS=""
  LAST_TCP_DETAIL=""
  PORT_WAIT=0

  while [ $PORT_WAIT -lt $SSH_PORT_MAX_WAIT ]; do
    TCP_DETAIL=$(tcp_probe "$TARGET_IP" "$SSH_PORT" 5)
    TCP_RC=$?
    if [ $TCP_RC -eq 0 ]; then
      echo "✓ Port $SSH_PORT is open (waited $PORT_WAIT seconds)"
      SSH_PORT_READY=true
      break
    fi
    LAST_TCP_CLASS=$(classify_ssh_error "$TCP_DETAIL")
    LAST_TCP_DETAIL="$TCP_DETAIL"
    if [ $((PORT_WAIT % 20)) -eq 0 ]; then
      echo "  Waiting for SSH port... ($PORT_WAIT/$SSH_PORT_MAX_WAIT seconds)"
      if [ -n "$LAST_TCP_CLASS" ] && [ "$LAST_TCP_CLASS" != "unknown" ]; then
        echo "  Last TCP probe: $LAST_TCP_CLASS"
      fi
    fi
    sleep "$SSH_CHECK_INTERVAL"
    PORT_WAIT=$((PORT_WAIT + SSH_CHECK_INTERVAL))
  done

  if [ "$SSH_PORT_READY" = true ]; then
    AUTH_WAIT=0
    LAST_SSH_CLASS=""
    LAST_SSH_DETAIL=""
    PERM_DENIED_COUNT=0

    while [ $AUTH_WAIT -lt $SSH_AUTH_MAX_WAIT ]; do
      SSH_DETAIL=$(timeout "$SSH_ATTEMPT_TIMEOUT" ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo 'SSH OK'" 2>&1)
      SSH_RC=$?
      if [ $SSH_RC -eq 0 ]; then
        echo "✓ SSH is accessible (waited $AUTH_WAIT seconds)"
        SSH_READY=true
        break
      fi

      LAST_SSH_CLASS=$(classify_ssh_error "$SSH_DETAIL")
      LAST_SSH_DETAIL="$SSH_DETAIL"
      if [ "$LAST_SSH_CLASS" = "permission_denied" ]; then
        PERM_DENIED_COUNT=$((PERM_DENIED_COUNT + 1))
      fi

      if [ $((AUTH_WAIT % 30)) -eq 0 ]; then
        echo "  Waiting for SSH auth... ($AUTH_WAIT/$SSH_AUTH_MAX_WAIT seconds)"
        if [ -n "$LAST_SSH_CLASS" ] && [ "$LAST_SSH_CLASS" != "unknown" ]; then
          echo "  Last SSH error: $LAST_SSH_CLASS"
          echo "  Detail: $(echo "$LAST_SSH_DETAIL" | head -1)"
        fi
      fi

      if [ "$PERM_DENIED_COUNT" -ge 3 ]; then
        break
      fi

      sleep "$SSH_CHECK_INTERVAL"
      AUTH_WAIT=$((AUTH_WAIT + SSH_CHECK_INTERVAL))
    done
  fi

  if [ "$SSH_PORT_READY" = false ]; then
    echo "✗ Port $SSH_PORT not accessible after $SSH_PORT_MAX_WAIT seconds"
    if [ -n "$LAST_TCP_DETAIL" ]; then
      echo "  Last TCP probe detail: $(echo "$LAST_TCP_DETAIL" | head -1)"
    fi
  elif [ "$SSH_READY" = false ]; then
    echo "✗ SSH not accessible after $SSH_AUTH_MAX_WAIT seconds"
    if [ -n "$LAST_SSH_CLASS" ]; then
      echo "  Last SSH error: $LAST_SSH_CLASS"
    fi
    if [ -n "$LAST_SSH_DETAIL" ]; then
      echo "  Last SSH detail: $(echo "$LAST_SSH_DETAIL" | head -1)"
    fi
  fi

  if [ "$SSH_READY" = false ]; then
    echo ""
    echo "Diagnostics:"
    $VIRSH_CMD domifaddr "$VM_NAME" 2>/dev/null || true
    $VIRSH_CMD domiflist "$VM_NAME" 2>/dev/null || true
    if command -v ip >/dev/null 2>&1; then
      ip neigh show "$TARGET_IP" 2>/dev/null | sed 's/^/  Neigh: /' || true
    fi
    if [ "$SSH_STRICT_HOST_KEY_CHECKING" != "no" ] && [ "$SSH_KNOWN_HOSTS_FILE" != "/dev/null" ]; then
      echo "  Note: host key mismatch can be resolved by cleaning known_hosts entry."
      echo "  Example: ssh-keygen -f \"$SSH_KNOWN_HOSTS_FILE\" -R \"$TARGET_IP\""
    fi
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
  
  if [ "${SSH_PORT_READY:-false}" = true ]; then
    echo "SSH Port ($SSH_PORT): ✓ Open"
  else
    echo "SSH Port ($SSH_PORT): ✗ Not accessible yet"
    if [ -n "${LAST_TCP_CLASS:-}" ] && [ "${LAST_TCP_CLASS:-}" != "unknown" ]; then
      echo "SSH Port Detail: $LAST_TCP_CLASS"
    fi
  fi
  
  if [ "$SSH_READY" = true ]; then
    echo "SSH: ✓ Accessible"
  else
    echo "SSH: ✗ Not accessible yet"
    if [ -n "${LAST_SSH_CLASS:-}" ] && [ "${LAST_SSH_CLASS:-}" != "unknown" ]; then
      echo "SSH Detail: $LAST_SSH_CLASS"
    fi
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
  if [ -n "$TARGET_IP" ] && [ "${NETWORK_READY:-false}" != "true" ]; then
    echo "Suggested: verify routing/bridge, then re-check IP via: $VIRSH_CMD domifaddr $VM_NAME"
  elif [ -n "$TARGET_IP" ] && [ "${SSH_PORT_READY:-false}" != "true" ]; then
    case "${LAST_TCP_CLASS:-unknown}" in
      network_unreachable)
        echo "Suggested: check host route/firewall to $TARGET_IP and libvirt network state"
        ;;
      connection_timeout)
        echo "Suggested: port $SSH_PORT may be filtered (guest/host firewall). Check guest firewall via console"
        ;;
      connection_refused)
        echo "Suggested: sshd may not be running yet. Check via console: sudo systemctl status ssh"
        ;;
      *)
        echo "Suggested: check SSH service and firewall on guest; check libvirt network on host"
        ;;
    esac
  elif [ -n "$TARGET_IP" ] && [ "$SSH_READY" != "true" ]; then
    case "${LAST_SSH_CLASS:-unknown}" in
      permission_denied)
        echo "Suggested: verify SSH username/key injection and authorized_keys on guest"
        ;;
      host_key_verification_failed)
        echo "Suggested: fix known_hosts mismatch or set SSH_STRICT_HOST_KEY_CHECKING=no for automation"
        ;;
      key_bad_permissions)
        echo "Suggested: fix key permission to 600/400 and retry"
        ;;
      *)
        echo "Suggested: inspect SSH logs on guest: journalctl -u ssh -n 50"
        ;;
    esac
  fi
  echo "Check logs: $LOG_FILE"
fi

exit 0
