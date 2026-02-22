#!/bin/bash
# File: /home/ripjim/pando_box/QuickstackBlueGreenIAAC/scripts/fix_vm_network.sh

# ============================================================================
# Script: VM Network Diagnosis and Fix
# Purpose: Diagnose and fix network connectivity issues for libvirt VMs
# ============================================================================

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
VM_NAME="${1:-k3s-master-01}"
LOG_FILE="/var/log/vm-network-fix-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/var/backups/libvirt-configs"

# Fungsi: Print status dengan warna
print_status() {
    local type=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $type in
        "info")    echo -e "${BLUE}[$timestamp INFO]${NC} $message" | tee -a "$LOG_FILE" ;;
        "success") echo -e "${GREEN}[$timestamp SUCCESS]${NC} $message" | tee -a "$LOG_FILE" ;;
        "warn")    echo -e "${YELLOW}[$timestamp WARN]${NC} $message" | tee -a "$LOG_FILE" ;;
        "error")   echo -e "${RED}[$timestamp ERROR]${NC} $message" | tee -a "$LOG_FILE" ;;
    esac
}

# Fungsi: Backup konfigurasi VM
backup_vm_config() {
    print_status "info" "Backing up VM configuration..."
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="${BACKUP_DIR}/${VM_NAME}-$(date +%Y%m%d-%H%M%S).xml"
    
    if sudo virsh dumpxml "$VM_NAME" > "$backup_file" 2>/dev/null; then
        print_status "success" "Configuration backed up to: $backup_file"
        return 0
    else
        print_status "error" "Failed to backup VM configuration"
        return 1
    fi
}

# Fungsi: Verifikasi status VM
verify_vm_status() {
    print_status "info" "=== Step 1: Verifying VM Status ==="
    
    # Check if VM exists
    if ! sudo virsh list --all | grep -q "$VM_NAME"; then
        print_status "error" "VM '$VM_NAME' not found"
        print_status "info" "Available VMs:"
        sudo virsh list --all | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Check VM state
    local vm_state=$(sudo virsh domstate "$VM_NAME" 2>/dev/null)
    print_status "info" "VM State: $vm_state"
    
    if [[ "$vm_state" != "running" ]]; then
        print_status "warn" "VM is not running. Attempting to start..."
        if sudo virsh start "$VM_NAME" >> "$LOG_FILE" 2>&1; then
            print_status "success" "VM started successfully"
            sleep 10  # Wait for VM to initialize
        else
            print_status "error" "Failed to start VM"
            return 1
        fi
    else
        print_status "success" "VM is running"
    fi
    
    # Display VM info
    print_status "info" "VM Information:"
    sudo virsh dominfo "$VM_NAME" | tee -a "$LOG_FILE"
    
    return 0
}

# Fungsi: Diagnosis konfigurasi jaringan VM
diagnose_vm_network() {
    print_status "info" "=== Step 2: Diagnosing VM Network Configuration ==="
    
    # Get network interface configuration
    print_status "info" "Network interfaces configured for VM:"
    sudo virsh domiflist "$VM_NAME" | tee -a "$LOG_FILE"
    
    # Get detailed network configuration from XML
    print_status "info" "Detailed network configuration:"
    sudo virsh dumpxml "$VM_NAME" | grep -A 15 "<interface" | tee -a "$LOG_FILE"
    
    # Check for MAC address
    local mac_address=$(sudo virsh dumpxml "$VM_NAME" | grep "mac address" | head -1 | sed "s/.*'\(.*\)'.*/\1/")
    if [[ -n "$mac_address" ]]; then
        print_status "info" "VM MAC Address: $mac_address"
    else
        print_status "error" "No MAC address found for VM"
        return 1
    fi
    
    # Try to get IP address using different methods
    print_status "info" "Attempting to retrieve IP address..."
    
    # Method 1: virsh domifaddr
    print_status "info" "Method 1: Using virsh domifaddr"
    sudo virsh domifaddr "$VM_NAME" --source lease 2>&1 | tee -a "$LOG_FILE"
    sudo virsh domifaddr "$VM_NAME" --source agent 2>&1 | tee -a "$LOG_FILE"
    sudo virsh domifaddr "$VM_NAME" --source arp 2>&1 | tee -a "$LOG_FILE"
    
    return 0
}

# Fungsi: Diagnosis jaringan virtual libvirt
diagnose_libvirt_network() {
    print_status "info" "=== Step 3: Diagnosing Libvirt Virtual Networks ==="
    
    # List all networks
    print_status "info" "Available virtual networks:"
    sudo virsh net-list --all | tee -a "$LOG_FILE"
    
    # Get network name from VM config
    local network_name=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $3; exit}')
    
    if [[ -z "$network_name" ]]; then
        print_status "error" "Could not determine network name from VM configuration"
        network_name="default"
        print_status "info" "Using default network: $network_name"
    else
        print_status "info" "VM is connected to network: $network_name"
    fi
    
    # Check network state
    local net_state=$(sudo virsh net-info "$network_name" 2>/dev/null | grep "Active:" | awk '{print $2}')
    print_status "info" "Network '$network_name' state: $net_state"
    
    if [[ "$net_state" != "yes" ]]; then
        print_status "warn" "Network is not active"
        return 1
    fi
    
    # Display network configuration
    print_status "info" "Network configuration:"
    sudo virsh net-dumpxml "$network_name" | tee -a "$LOG_FILE"
    
    # Check DHCP leases
    print_status "info" "DHCP leases for network '$network_name':"
    sudo virsh net-dhcp-leases "$network_name" 2>&1 | tee -a "$LOG_FILE"
    
    # Check bridge configuration
    local bridge_name=$(sudo virsh net-info "$network_name" 2>/dev/null | grep "Bridge:" | awk '{print $2}')
    if [[ -n "$bridge_name" ]]; then
        print_status "info" "Bridge name: $bridge_name"
        print_status "info" "Bridge status:"
        ip link show "$bridge_name" 2>&1 | tee -a "$LOG_FILE"
        
        # Show bridge details
        if command -v brctl &> /dev/null; then
            print_status "info" "Bridge details (brctl):"
            sudo brctl show "$bridge_name" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    
    return 0
}

# Fungsi: Check QEMU Guest Agent
check_qemu_guest_agent() {
    print_status "info" "=== Step 4: Checking QEMU Guest Agent ==="
    
    # Check if guest agent channel exists
    if sudo virsh dumpxml "$VM_NAME" | grep -q "qemu-guest-agent"; then
        print_status "info" "QEMU Guest Agent channel is configured"
        
        # Try to ping guest agent
        if sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-ping"}' &>/dev/null; then
            print_status "success" "QEMU Guest Agent is responding"
            
            # Get network interfaces from guest agent
            print_status "info" "Network interfaces from guest agent:"
            sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-network-get-interfaces"}' 2>&1 | tee -a "$LOG_FILE"
        else
            print_status "warn" "QEMU Guest Agent is not responding"
            print_status "info" "Guest agent might not be installed or running in the VM"
        fi
    else
        print_status "warn" "QEMU Guest Agent channel not configured"
        print_status "info" "Consider adding guest agent for better VM management"
    fi
    
    return 0
}

# Fungsi: Restart network services
restart_network_services() {
    print_status "info" "=== Step 5: Restarting Network Services ==="
    
    local network_name=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $3; exit}')
    [[ -z "$network_name" ]] && network_name="default"
    
    # Restart libvirtd
    print_status "info" "Restarting libvirtd service..."
    if sudo systemctl restart libvirtd; then
        print_status "success" "libvirtd restarted successfully"
        sleep 5
    else
        print_status "error" "Failed to restart libvirtd"
        return 1
    fi
    
    # Restart virtual network
    print_status "info" "Restarting virtual network '$network_name'..."
    
    # Destroy network
    if sudo virsh net-destroy "$network_name" 2>/dev/null; then
        print_status "info" "Network stopped"
    else
        print_status "warn" "Network was not running or failed to stop"
    fi
    
    sleep 2
    
    # Start network
    if sudo virsh net-start "$network_name" 2>/dev/null; then
        print_status "success" "Network started successfully"
    else
        print_status "warn" "Network might already be running"
    fi
    
    sleep 3
    
    # Verify network is active
    if sudo virsh net-list | grep -q "$network_name.*active"; then
        print_status "success" "Network is active"
    else
        print_status "error" "Network failed to start"
        return 1
    fi
    
    return 0
}

# Fungsi: Restart VM network interface
restart_vm_network() {
    print_status "info" "=== Step 6: Restarting VM Network Interface ==="
    
    # Get interface name
    local interface=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $1; exit}')
    
    if [[ -z "$interface" ]]; then
        print_status "error" "Could not determine interface name"
                return 1
    fi
    
    print_status "info" "Interface: $interface"
    
    # Detach and reattach network interface
    print_status "info" "Detaching network interface..."
    if sudo virsh detach-interface "$VM_NAME" network --current 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "Interface detached"
        sleep 3
        
        # Get MAC address for reattachment
        local mac_address=$(sudo virsh dumpxml "$VM_NAME" | grep "mac address" | head -1 | sed "s/.*'\(.*\)'.*/\1/")
        local network_name=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $3; exit}')
        [[ -z "$network_name" ]] && network_name="default"
        
        print_status "info" "Reattaching network interface..."
        if sudo virsh attach-interface "$VM_NAME" network "$network_name" --mac "$mac_address" --current 2>&1 | tee -a "$LOG_FILE"; then
            print_status "success" "Interface reattached"
            sleep 5
        else
            print_status "error" "Failed to reattach interface"
            return 1
        fi
    else
        print_status "warn" "Failed to detach interface (might not be necessary)"
    fi
    
    return 0
}

# Fungsi: Reboot VM
reboot_vm() {
    print_status "info" "=== Step 7: Rebooting VM ==="
    
    read -p "Reboot VM '$VM_NAME'? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "info" "VM reboot skipped"
        return 0
    fi
    
    print_status "info" "Rebooting VM..."
    if sudo virsh reboot "$VM_NAME" >> "$LOG_FILE" 2>&1; then
        print_status "success" "VM reboot initiated"
        
        # Wait for VM to come back up
        print_status "info" "Waiting for VM to reboot (60 seconds)..."
        sleep 60
        
        # Verify VM is running
        local vm_state=$(sudo virsh domstate "$VM_NAME" 2>/dev/null)
        if [[ "$vm_state" == "running" ]]; then
            print_status "success" "VM is running after reboot"
        else
            print_status "warn" "VM state after reboot: $vm_state"
        fi
    else
        print_status "error" "Failed to reboot VM"
        return 1
    fi
    
    return 0
}

# Fungsi: Verify IP address assignment
verify_ip_assignment() {
    print_status "info" "=== Step 8: Verifying IP Address Assignment ==="
    
    local max_attempts=10
    local attempt=1
    local ip_found=false
    
    while [[ $attempt -le $max_attempts ]]; do
        print_status "info" "Attempt $attempt/$max_attempts to retrieve IP address..."
        
        # Try different methods
        local ip_address=""
        
        # Method 1: DHCP leases
        local network_name=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $3; exit}')
        [[ -z "$network_name" ]] && network_name="default"
        
        ip_address=$(sudo virsh net-dhcp-leases "$network_name" 2>/dev/null | grep "$VM_NAME" | awk '{print $5}' | cut -d'/' -f1)
        
        if [[ -n "$ip_address" ]]; then
            print_status "success" "IP address found via DHCP leases: $ip_address"
            ip_found=true
            break
        fi
        
        # Method 2: virsh domifaddr with different sources
        for source in lease agent arp; do
            ip_address=$(sudo virsh domifaddr "$VM_NAME" --source "$source" 2>/dev/null | awk 'NR>2 {print $4}' | cut -d'/' -f1)
            if [[ -n "$ip_address" ]]; then
                print_status "success" "IP address found via $source: $ip_address"
                ip_found=true
                break 2
            fi
        done
        
        # Method 3: ARP table
        local mac_address=$(sudo virsh dumpxml "$VM_NAME" | grep "mac address" | head -1 | sed "s/.*'\(.*\)'.*/\1/")
        if [[ -n "$mac_address" ]]; then
            ip_address=$(arp -n | grep -i "$mac_address" | awk '{print $1}')
            if [[ -n "$ip_address" ]]; then
                print_status "success" "IP address found via ARP: $ip_address"
                ip_found=true
                break
            fi
        fi
        
        ((attempt++))
        sleep 10
    done
    
    if [[ "$ip_found" == true ]]; then
        print_status "success" "VM IP Address: $ip_address"
        echo "$ip_address" > "/tmp/${VM_NAME}_ip.txt"
        return 0
    else
        print_status "error" "Failed to retrieve IP address after $max_attempts attempts"
        return 1
    fi
}

# Fungsi: Test SSH connectivity
test_ssh_connectivity() {
    print_status "info" "=== Step 9: Testing SSH Connectivity ==="
    
    local ip_file="/tmp/${VM_NAME}_ip.txt"
    if [[ ! -f "$ip_file" ]]; then
        print_status "error" "IP address file not found. Run verify_ip_assignment first."
        return 1
    fi
    
    local ip_address=$(cat "$ip_file")
    print_status "info" "Testing SSH to: $ip_address"
    
    # Check if port 22 is open
    print_status "info" "Checking if port 22 is open..."
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$ip_address/22" 2>/dev/null; then
        print_status "success" "Port 22 is open"
    else
        print_status "error" "Port 22 is not accessible"
        print_status "info" "SSH service might not be running or firewall is blocking"
        return 1
    fi
    
    # Try SSH connection (without password, just to test)
    print_status "info" "Testing SSH connection (will timeout if no key configured)..."
    if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "ubuntu@$ip_address" "echo 'SSH connection successful'" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "SSH connection successful"
    else
        print_status "warn" "SSH connection failed (might need SSH key configuration)"
        print_status "info" "To connect manually: ssh ubuntu@$ip_address"
    fi
    
    return 0
}

# Fungsi: Check firewall rules
check_firewall_rules() {
    print_status "info" "=== Step 10: Checking Firewall Rules ==="
    
    # Check iptables
    print_status "info" "IPTables rules:"
    sudo iptables -L -n -v | grep -E "FORWARD|INPUT" | tee -a "$LOG_FILE"
    
    # Check if firewalld is running
    if systemctl is-active --quiet firewalld; then
        print_status "info" "Firewalld is active"
        print_status "info" "Firewalld zones:"
        sudo firewall-cmd --list-all-zones | tee -a "$LOG_FILE"
    else
        print_status "info" "Firewalld is not active"
    fi
    
    # Check libvirt network rules
    local network_name=$(sudo virsh domiflist "$VM_NAME" | awk 'NR>2 {print $3; exit}')
    [[ -z "$network_name" ]] && network_name="default"
    
    print_status "info" "Libvirt network rules for '$network_name':"
    sudo iptables -t nat -L -n -v | grep "$network_name" | tee -a "$LOG_FILE"
    
    return 0
}

# Fungsi: Advanced troubleshooting
advanced_troubleshooting() {
    print_status "info" "=== Advanced Troubleshooting ==="
    
    # Check console logs
    print_status "info" "Checking VM console logs..."
    sudo virsh console "$VM_NAME" --force &
    local console_pid=$!
    sleep 5
    kill $console_pid 2>/dev/null || true
    
    # Check dmesg for network issues
    print_status "info" "Checking host dmesg for network issues..."
    sudo dmesg | tail -50 | grep -i "network\|bridge\|virt" | tee -a "$LOG_FILE"
    
    # Check libvirt logs
    print_status "info" "Checking libvirt logs..."
    sudo journalctl -u libvirtd --since "10 minutes ago" --no-pager | tail -50 | tee -a "$LOG_FILE"
    
    # Check VM XML for issues
    print_status "info" "Validating VM XML configuration..."
    if sudo virt-xml-validate <(sudo virsh dumpxml "$VM_NAME") 2>&1 | tee -a "$LOG_FILE"; then
        print_status "success" "VM XML is valid"
    else
        print_status "warn" "VM XML validation issues detected"
    fi
    
    return 0
}

# Fungsi: Generate fix report
generate_fix_report() {
    print_status "info" "=== Generating Fix Report ==="
    
    local report_file="/tmp/vm-network-fix-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "============================================================"
        echo "VM Network Fix Report"
        echo "============================================================"
        echo "Date: $(date)"
        echo "VM Name: $VM_NAME"
        echo ""
        echo "--- VM Status ---"
        sudo virsh dominfo "$VM_NAME" 2>/dev/null || echo "Failed to get VM info"
        echo ""
        echo "--- Network Configuration ---"
        sudo virsh domiflist "$VM_NAME" 2>/dev/null || echo "Failed to get interface list"
        echo ""
        echo "--- IP Address ---"
        if [[ -f "/tmp/${VM_NAME}_ip.txt" ]]; then
            cat "/tmp/${VM_NAME}_ip.txt"
        else
            echo "IP address not found"
        fi
        echo ""
        echo "--- DHCP Leases ---"
        local network_name=$(sudo virsh domiflist "$VM_NAME" 2>/dev/null | awk 'NR>2 {print $3; exit}')
        [[ -z "$network_name" ]] && network_name="default"
        sudo virsh net-dhcp-leases "$network_name" 2>/dev/null || echo "Failed to get DHCP leases"
        echo ""
        echo "--- Network Status ---"
        sudo virsh net-list --all 2>/dev/null || echo "Failed to list networks"
        echo ""
        echo "============================================================"
    } > "$report_file"
    
    print_status "success" "Fix report generated: $report_file"
    cat "$report_file"
    
    return 0
}

# Fungsi: Main execution
main() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     VM Network Diagnosis and Fix Tool                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    print_status "info" "Starting network diagnosis for VM: $VM_NAME"
    print_status "info" "Log file: $LOG_FILE"
    echo ""
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Backup VM configuration
    backup_vm_config || {
        print_status "warn" "Failed to backup configuration, continuing anyway..."
    }
    
    # Step 1: Verify VM Status
    if ! verify_vm_status; then
        print_status "error" "VM status verification failed"
        exit 1
    fi
    
    echo ""
    
    # Step 2: Diagnose VM Network
    diagnose_vm_network
    
    echo ""
    
    # Step 3: Diagnose Libvirt Network
    diagnose_libvirt_network
    
    echo ""
    
    # Step 4: Check QEMU Guest Agent
    check_qemu_guest_agent
    
    echo ""
    
    # Ask if user wants to proceed with fixes
    read -p "Proceed with network fixes? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "info" "Fix process cancelled by user"
        generate_fix_report
        exit 0
    fi
    
    echo ""
    
    # Step 5: Restart Network Services
    if restart_network_services; then
        print_status "success" "Network services restarted"
    else
        print_status "warn" "Network service restart had issues"
    fi
    
    echo ""
    
    # Step 6: Restart VM Network Interface
    if restart_vm_network; then
        print_status "success" "VM network interface restarted"
    else
        print_status "warn" "VM network interface restart had issues"
    fi
    
    echo ""
    
    # Step 7: Reboot VM (optional)
    reboot_vm
    
    echo ""
    
    # Step 8: Verify IP Assignment
    if verify_ip_assignment; then
        print_status "success" "IP address successfully retrieved"
    else
        print_status "error" "Failed to retrieve IP address"
        print_status "info" "Running advanced troubleshooting..."
        advanced_troubleshooting
        generate_fix_report
        exit 1
    fi
    
    echo ""
    
    # Step 9: Test SSH Connectivity
    test_ssh_connectivity
    
    echo ""
    
    # Step 10: Check Firewall Rules
    check_firewall_rules
    
    echo ""
    
    # Generate final report
    generate_fix_report
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Network Fix Process Completed                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Display final status
    if [[ -f "/tmp/${VM_NAME}_ip.txt" ]]; then
        local ip_address=$(cat "/tmp/${VM_NAME}_ip.txt")
        print_status "success" "VM IP Address: $ip_address"
        print_status "info" "Connect via SSH: ssh ubuntu@$ip_address"
    fi
    
    print_status "info" "Full log available at: $LOG_FILE"
    
    return 0
}

# Run main function
main "$@"