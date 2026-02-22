
#!/bin/bash
set -euo pipefail

# ============================================================================
# ENHANCED SSH WAIT SCRIPT WITH PROGRESSIVE HEALTH CHECKS
# ============================================================================
# Version: 2.0
# Description: Waits for SSH to become fully operational with comprehensive
#              diagnostics and progressive health checks
# ============================================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*"
}

log_stage() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

# ============================================================================
# INPUT PARAMETERS VALIDATION
# ============================================================================
VM_NAME="${1:-}"
TARGET_IP="${2:-}"
SSH_USER="${3:-ubuntu}"
SSH_KEY_PATH="${4:-}"

# Validate required parameters
if [ -z "$VM_NAME" ]; then
    log_error "VM name not specified"
    echo "Usage: $0 <vm_name> <target_ip> [ssh_user] [ssh_key_path]"
    exit 1
fi

# Configuration
MAX_WAIT_NETWORK=120      # 2 minutes for network
MAX_WAIT_PORT=180         # 3 minutes for SSH port
MAX_WAIT_AUTH=300         # 5 minutes for SSH auth
MAX_WAIT_CLOUDINIT=600    # 10 minutes for cloud-init
CHECK_INTERVAL=5

# Timing (avoid unbound variables with set -u)
ELAPSED_NETWORK=0
ELAPSED_PORT=0
ELAPSED_AUTH=0
ELAPSED_CLOUDINIT=0

VIRSH_CMD="virsh -c qemu:///system"
if ! $VIRSH_CMD version >/dev/null 2>&1; then
    VIRSH_CMD=""
fi

# ============================================================================
# HEADER
# ============================================================================
log_stage "SSH READINESS CHECK"
echo "Timestamp: $(date)"
echo "VM Name: $VM_NAME"
echo "Target IP: ${TARGET_IP:-auto-detect}"
echo "SSH User: $SSH_USER"
echo "SSH Key: ${SSH_KEY_PATH:-default}"
echo ""

# ============================================================================
# STAGE 0: IP ADDRESS DETECTION (IF NOT PROVIDED)
# ============================================================================
if [ -z "$TARGET_IP" ]; then
    log_stage "STAGE 0: IP ADDRESS DETECTION"
    
    ELAPSED=0
    MAX_DETECT_TIME=150  # 2.5 minutes
    IP_DETECTED=false
    
    while [ $ELAPSED -lt $MAX_DETECT_TIME ]; do
        # Try QEMU agent first (more reliable)
        if [ -z "$VIRSH_CMD" ]; then
            break
        fi

        DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source agent 2>/dev/null | \
                      grep -oP '(\d+\.){3}\d+' | \
                      grep -v '^127\.' | \
                      grep -v '^169\.254\.' | \
                      head -1)
        
        # Fallback to DHCP lease
        if [ -z "$DETECTED_IP" ]; then
            DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source lease 2>/dev/null | \
                          grep -oP '(\d+\.){3}\d+' | \
                          grep -v '^127\.' | \
                          grep -v '^169\.254\.' | \
                          head -1)
        fi
        
        if [ -n "$DETECTED_IP" ]; then
            log_success "IP address detected: $DETECTED_IP"
            TARGET_IP="$DETECTED_IP"
            IP_DETECTED=true
            break
        fi
        
        if [ $((ELAPSED % 15)) -eq 0 ]; then
            log_info "Waiting for IP address... ($ELAPSED/$MAX_DETECT_TIME seconds)"
        fi
        
        sleep 5
        ELAPSED=$((ELAPSED + 5))
    done
    
    if [ "$IP_DETECTED" = false ]; then
        log_error "Could not detect IP address after $MAX_DETECT_TIME seconds"
        echo ""
        echo "Diagnostic commands:"
            if [ -n "$VIRSH_CMD" ]; then
                echo "  $VIRSH_CMD domifaddr $VM_NAME"
                echo "  $VIRSH_CMD domifaddr $VM_NAME --source agent"
                echo "  $VIRSH_CMD console $VM_NAME"
            fi
        exit 1
    fi
fi

# ============================================================================
# STAGE 1: NETWORK CONNECTIVITY CHECK
# ============================================================================
log_stage "STAGE 1: NETWORK CONNECTIVITY"

ELAPSED=0
NETWORK_READY=false

log_info "Testing ICMP connectivity to $TARGET_IP..."

while [ $ELAPSED -lt $MAX_WAIT_NETWORK ]; do
    if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
        log_success "Network is reachable (ICMP response received)"
        NETWORK_READY=true
        break
    fi
    
    if [ $((ELAPSED % 20)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log_info "Still waiting for network... ($ELAPSED/$MAX_WAIT_NETWORK seconds)"
        
        # Show VM state
        VM_STATE=$($VIRSH_CMD domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        echo "  VM State: $VM_STATE"
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$NETWORK_READY" = false ]; then
    log_error "Network not reachable after $MAX_WAIT_NETWORK seconds"
    echo ""
    echo "Diagnostics:"
    
    # Check VM state
    VM_STATE=$($VIRSH_CMD domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    echo "  VM State: $VM_STATE"
    
    # Try to detect current IP
    CURRENT_IP=$($VIRSH_CMD domifaddr "$VM_NAME" 2>/dev/null | \
                 grep -oP '(\d+\.){3}\d+' | \
                 grep -v '^127\.' | head -1)
    
    if [ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "$TARGET_IP" ]; then
        log_warning "Detected IP ($CURRENT_IP) differs from target ($TARGET_IP)"
        echo ""
        echo "Retrying with detected IP..."
        TARGET_IP="$CURRENT_IP"
        
        # Retry with new IP
        for i in {1..10}; do
            if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
                log_success "Network reachable with detected IP"
                NETWORK_READY=true
                break
            fi
            sleep 2
        done
    fi
    
    if [ "$NETWORK_READY" = false ]; then
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Check VM console: $VIRSH_CMD console $VM_NAME"
        echo "  2. Verify network: $VIRSH_CMD net-list --all"
        echo "  3. Check VM network config: $VIRSH_CMD domiflist $VM_NAME"
        exit 1
    fi
fi

ELAPSED_NETWORK=$ELAPSED

# ============================================================================
# STAGE 2: SSH PORT AVAILABILITY CHECK
# ============================================================================
log_stage "STAGE 2: SSH PORT AVAILABILITY"

ELAPSED=0
PORT_OPEN=false

log_info "Checking if port 22 is open on $TARGET_IP..."

while [ $ELAPSED -lt $MAX_WAIT_PORT ]; do
    # Test TCP connection to port 22
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$TARGET_IP/22" 2>/dev/null; then
        log_success "Port 22 is open and accepting connections"
        PORT_OPEN=true
        break
    fi
    
    if [ $((ELAPSED % 20)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log_info "Still waiting for SSH port... ($ELAPSED/$MAX_WAIT_PORT seconds)"
        
        # Try netcat as alternative check
        if command -v nc >/dev/null 2>&1; then
            if nc -zv -w 2 "$TARGET_IP" 22 2>&1 | grep -q "succeeded\|open"; then
                log_success "Port 22 is open (detected via netcat)"
                PORT_OPEN=true
                break
            fi
        fi
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$PORT_OPEN" = false ]; then
    log_error "SSH port not available after $MAX_WAIT_PORT seconds"
    echo ""
    echo "Diagnostics:"
    
    # Check if SSH service is running via console
    log_info "Attempting to check SSH service status..."
    
    # Try to get service status (this requires console access or agent)
    echo "  Run manually: $VIRSH_CMD console $VM_NAME"
    echo "  Then check: sudo systemctl status ssh"
    echo ""
    echo "Common causes:"
    echo "  - SSH service not started yet"
    echo "  - Firewall blocking port 22"
    echo "  - Cloud-init still configuring system"
    exit 1
fi

ELAPSED_PORT=$ELAPSED

# ============================================================================
# STAGE 3: SSH AUTHENTICATION CHECK
# ============================================================================
log_stage "STAGE 3: SSH AUTHENTICATION"

# Build SSH options
SSH_OPTS="-F /dev/null -o StrictHostKeyChecking=no"

SSH_OPTS="$SSH_OPTS -o UserKnownHostsFile=/dev/null"
SSH_OPTS="$SSH_OPTS -o ConnectTimeout=10"
SSH_OPTS="$SSH_OPTS -o ServerAliveInterval=5"
SSH_OPTS="$SSH_OPTS -o ServerAliveCountMax=3"
SSH_OPTS="$SSH_OPTS -o BatchMode=yes"
SSH_OPTS="$SSH_OPTS -o LogLevel=ERROR"

# Add SSH key if provided and exists
if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    log_info "Using SSH key: $SSH_KEY_PATH"
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY_PATH"
    
    # Verify key permissions
    KEY_PERMS=$(stat -c "%a" "$SSH_KEY_PATH" 2>/dev/null || stat -f "%Lp" "$SSH_KEY_PATH" 2>/dev/null)
    if [ "$KEY_PERMS" != "600" ] && [ "$KEY_PERMS" != "400" ]; then
        log_warning "SSH key has insecure permissions: $KEY_PERMS"
        log_info "Fixing permissions to 600..."
        chmod 600 "$SSH_KEY_PATH" 2>/dev/null || true
    fi
elif [ -n "$SSH_KEY_PATH" ]; then
    log_warning "SSH key not found: $SSH_KEY_PATH"
    log_info "Will attempt authentication with default keys"
fi

ELAPSED=0
AUTH_SUCCESS=false

log_info "Testing SSH authentication to $SSH_USER@$TARGET_IP..."

while [ $ELAPSED -lt $MAX_WAIT_AUTH ]; do
    # Test SSH authentication with simple command
    if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo 'SSH_AUTH_OK'" >/dev/null 2>&1; then
        log_success "SSH authentication successful"
        AUTH_SUCCESS=true
        break
    fi
    
    if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        log_info "Still waiting for SSH authentication... ($ELAPSED/$MAX_WAIT_AUTH seconds)"
        
        # Try to get more details about the failure
        if [ $((ELAPSED % 60)) -eq 0 ]; then
            log_info "Attempting verbose connection test..."
            
            # Test with verbose output (capture stderr)
            SSH_ERROR=$(ssh -v $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo test" 2>&1 | \
                       grep -i "permission denied\|no such file\|connection refused\|connection timed out\|operation timed out\|timed out\|no route to host\|network is unreachable\|host key verification failed\|remote host identification has changed" | \
                       head -1)
            
            if [ -n "$SSH_ERROR" ]; then
                log_warning "SSH error: $SSH_ERROR"
            fi
        fi
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$AUTH_SUCCESS" = false ]; then
    log_error "SSH authentication failed after $MAX_WAIT_AUTH seconds"
    echo ""
    echo "Diagnostics:"
    
    # Test basic connectivity
    log_info "Testing basic SSH connectivity (without auth)..."
    SSH_PROBE=$(timeout 10 ssh -v $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo test" 2>&1 | \
       grep -i "Authentication failed\|Permission denied\|Host key verification failed\|REMOTE HOST IDENTIFICATION HAS CHANGED\|no route to host\|network is unreachable" | \
       head -1 || true)
    if [ -n "$SSH_PROBE" ]; then
        if echo "$SSH_PROBE" | grep -qiE "Authentication failed|Permission denied"; then
            log_warning "SSH server is responding but authentication is failing"
            echo ""
            echo "Possible causes:"
            echo "  1. SSH key not properly injected by cloud-init"
            echo "  2. Wrong username (current: $SSH_USER)"
            echo "  3. SSH key mismatch"
            echo "  4. User home directory permissions issue"
        elif echo "$SSH_PROBE" | grep -qiE "Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED"; then
            log_error "SSH blocked by host key verification"
            echo ""
            echo "Possible causes:"
            echo "  1. Host key changed (recreated VM)"
            echo "  2. Stale known_hosts entry"
            echo ""
            echo "Suggested fix:"
            echo "  ssh-keygen -R $TARGET_IP"
        elif echo "$SSH_PROBE" | grep -qiE "no route to host|network is unreachable"; then
            log_error "Network path to SSH is unreachable"
            echo ""
            echo "Possible causes:"
            echo "  1. Routing/bridge issue"
            echo "  2. Host firewall blocking"
            echo "  3. Wrong target IP"
        else
            log_warning "SSH probe detected: $SSH_PROBE"
        fi
    else
        log_warning "SSH server may not be fully initialized"
        echo ""
        echo "Possible causes:"
        echo "  1. SSH service still starting"
        echo "  2. Cloud-init still configuring SSH"
        echo "  3. System still booting"
    fi
    
    echo ""
    echo "Troubleshooting steps:"
    echo "  1. Check cloud-init logs:"
    echo "     $VIRSH_CMD console $VM_NAME"
    echo "     sudo tail -100 /var/log/cloud-init-output.log"
    echo ""
    echo "  2. Verify SSH key in VM:"
    echo "     sudo cat /home/$SSH_USER/.ssh/authorized_keys"
    echo ""
    echo "  3. Check SSH service:"
    echo "     sudo systemctl status ssh"
    echo "     sudo journalctl -u ssh -n 50"
    echo ""
    echo "  4. Test with password (if enabled):"
    echo "     ssh $SSH_USER@$TARGET_IP"
    echo ""
    
    exit 1
fi

ELAPSED_AUTH=$ELAPSED

# ============================================================================
# STAGE 4: CLOUD-INIT COMPLETION CHECK
# ============================================================================
log_stage "STAGE 4: CLOUD-INIT COMPLETION"

ELAPSED=0
CLOUDINIT_DONE=false

log_info "Waiting for cloud-init to complete..."

while [ $ELAPSED -lt $MAX_WAIT_CLOUDINIT ]; do
    # Check cloud-init status
    CLOUDINIT_STATUS=$(ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
                       "cloud-init status 2>/dev/null" || echo "unknown")
    
    if echo "$CLOUDINIT_STATUS" | grep -q "status: done"; then
        log_success "Cloud-init completed successfully"
        CLOUDINIT_DONE=true
        break
    elif echo "$CLOUDINIT_STATUS" | grep -q "status: error"; then
        log_warning "Cloud-init completed with errors"
        
        # Get error details
        log_info "Retrieving cloud-init error details..."
        ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
            "cloud-init status --long 2>/dev/null" || true
        
        echo ""
        log_warning "Continuing despite cloud-init errors..."
        CLOUDINIT_DONE=true
        break
    elif echo "$CLOUDINIT_STATUS" | grep -q "status: running"; then
        if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
            log_info "Cloud-init still running... ($ELAPSED/$MAX_WAIT_CLOUDINIT seconds)"
            
            # Show what cloud-init is doing
            if [ $((ELAPSED % 60)) -eq 0 ]; then
                log_info "Current cloud-init stage:"
                ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
                    "cloud-init status --long 2>/dev/null | head -5" || true
            fi
        fi
    elif echo "$CLOUDINIT_STATUS" | grep -q "status: disabled"; then
        log_warning "Cloud-init is disabled on this system"
        CLOUDINIT_DONE=true
        break
    else
        if [ $((ELAPSED % 30)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
            log_info "Waiting for cloud-init status... ($ELAPSED/$MAX_WAIT_CLOUDINIT seconds)"
            log_info "Status: $CLOUDINIT_STATUS"
        fi
    fi
    
    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$CLOUDINIT_DONE" = false ]; then
    log_warning "Cloud-init did not complete within $MAX_WAIT_CLOUDINIT seconds"
    log_info "System may still be initializing, but SSH is accessible"
    echo ""
    
    # Get current status
    log_info "Current cloud-init status:"
    ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
        "cloud-init status --long 2>/dev/null" || echo "  Status unavailable"
    
    echo ""
    log_warning "Continuing anyway as SSH is functional..."
fi

ELAPSED_CLOUDINIT=$ELAPSED

# ============================================================================
# STAGE 5: SYSTEM INFORMATION GATHERING
# ============================================================================
log_stage "STAGE 5: SYSTEM INFORMATION"

log_info "Gathering system information..."
echo ""

# Get basic system info
echo "=== System Details ==="
ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "
    echo 'Hostname: \$(hostname)'
    echo 'OS: \$(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')'
    echo 'Kernel: \$(uname -r)'
    echo 'Architecture: \$(uname -m)'
    echo 'Uptime: \$(uptime -p 2>/dev/null || uptime)'
    echo 'IP Address: \$(hostname -I | awk '{print \$1}')'
" 2>/dev/null || log_warning "Could not retrieve all system information"

echo ""
echo "=== Resource Usage ==="
ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "
    echo 'Memory:'
    free -h | grep -E 'Mem:|Swap:' | awk '{print \"  \" \$0}'
    echo ''
    echo 'Disk:'
    df -h / | tail -1 | awk '{print \"  Root: \" \$3 \" used / \" \$2 \" total (\" \$5 \" used)\"}'
    echo ''
    echo 'CPU Load:'
    uptime | awk -F'load average:' '{print \"  \" \$2}'
" 2>/dev/null || log_warning "Could not retrieve resource information"

echo ""
echo "=== Cloud-Init Final Status ==="
ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
    "cloud-init status --long 2>/dev/null" || echo "  Status not available"

# Check for K3s if it should be installed
echo ""
echo "=== K3s Status ==="
if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "command -v k3s >/dev/null 2>&1"; then
    log_success "K3s is installed"
    
    # Get K3s version
    K3S_VERSION=$(ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
                  "k3s --version 2>/dev/null | head -1" || echo "unknown")
    echo "  Version: $K3S_VERSION"
    
    # Check K3s service
    if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
       "sudo systemctl is-active k3s >/dev/null 2>&1"; then
        log_success "K3s service is running"
        
        # Try to get node status
        echo ""
        echo "  Node Status:"
        ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
            "sudo k3s kubectl get nodes 2>/dev/null" | sed 's/^/    /' || \
            echo "    (Node not ready yet)"
    else
        log_warning "K3s service is not running yet"
        echo "  Status: $(ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" \
                     'sudo systemctl status k3s --no-pager -l 2>/dev/null | head -3' || echo 'unknown')"
    fi
else
    log_info "K3s is not installed (may not be required for this node)"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
log_stage "SSH READINESS CHECK COMPLETE"

log_success "VM is fully accessible and operational!"

echo ""
echo "=== Connection Summary ==="
echo "  VM Name: $VM_NAME"
echo "  IP Address: $TARGET_IP"
echo "  SSH User: $SSH_USER"
echo "  SSH Command: ssh $SSH_USER@$TARGET_IP"
if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    echo "  With Key: ssh -i $SSH_KEY_PATH $SSH_USER@$TARGET_IP"
fi
echo ""

# Calculate total time
TOTAL_TIME=$((ELAPSED_NETWORK + ELAPSED_PORT + ELAPSED_AUTH + ELAPSED_CLOUDINIT))
TOTAL_MINUTES=$((TOTAL_TIME / 60))
TOTAL_SECONDS=$((TOTAL_TIME % 60))

echo "=== Timing Breakdown ==="
echo "  Network Ready: ${ELAPSED_NETWORK}s"
echo "  SSH Port Open: ${ELAPSED_PORT}s"
echo "  SSH Auth Success: ${ELAPSED_AUTH}s"
echo "  Cloud-init Complete: ${ELAPSED_CLOUDINIT}s"
echo "  Total Time: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
echo ""

log_success "All checks passed successfully!"
echo ""

exit 0
