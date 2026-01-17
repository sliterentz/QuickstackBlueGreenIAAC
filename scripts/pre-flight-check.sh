#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/terraform-kvm-preflight-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Terraform KVM Pre-Flight Validation Check          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$status" = "ok" ]; then
        echo -e "${GREEN}✓${NC} $message"
        echo "[$timestamp] [OK] $message" >> "$LOG_FILE"
    elif [ "$status" = "warn" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
        echo "[$timestamp] [WARN] $message" >> "$LOG_FILE"
    else
        echo -e "${RED}✗${NC} $message"
        echo "[$timestamp] [ERROR] $message" >> "$LOG_FILE"
    fi
}

# Function to check command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if running as root or with sudo
echo -e "${BLUE}[0/9]${NC} Checking privileges..."
if [ "$EUID" -ne 0 ]; then 
    print_status "error" "This script must be run as root or with sudo"
    echo -e "${YELLOW}Usage: sudo $0${NC}"
    exit 1
fi
print_status "ok" "Running with appropriate privileges (UID: $EUID)"

# Check system information
echo -e "\n${BLUE}[1/9]${NC} Checking system information..."
OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d'"' -f2)
OS_VERSION=$(grep "^VERSION=" /etc/os-release | cut -d'"' -f2)
KERNEL_VERSION=$(uname -r)
print_status "ok" "OS: $OS_NAME $OS_VERSION"
echo "      Kernel: $KERNEL_VERSION"

# Check virtualization support
echo -e "\n${BLUE}[2/9]${NC} Checking virtualization support..."
if grep -qE 'vmx|svm' /proc/cpuinfo; then
    print_status "ok" "CPU virtualization support detected"
    VT_TYPE=$(grep -oE 'vmx|svm' /proc/cpuinfo | head -1)
    echo "      Type: $([ "$VT_TYPE" = "vmx" ] && echo "Intel VT-x" || echo "AMD-V")"
else
    print_status "error" "CPU virtualization support not detected"
    echo -e "${YELLOW}Please enable VT-x/AMD-V in BIOS${NC}"
    exit 1
fi

# Check KVM module
if lsmod | grep -q kvm; then
    print_status "ok" "KVM kernel module is loaded"
else
    print_status "warn" "KVM kernel module not loaded. Loading..."
    modprobe kvm
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
    print_status "ok" "KVM kernel module loaded"
fi

# Check KVM/Libvirt installation
echo -e "\n${BLUE}[3/9]${NC} Checking KVM/Libvirt installation..."
if command_exists virsh; then
    print_status "ok" "Libvirt is installed"
    LIBVIRT_VERSION=$(virsh --version)
    echo "      Version: $LIBVIRT_VERSION"
else
    print_status "error" "Libvirt is not installed"
    echo -e "${YELLOW}Install with: sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils${NC}"
    exit 1
fi

echo "=== Installing QEMU Dependencies ==="
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "Cannot detect OS"
  exit 1
fi

echo "Detected OS: $OS"
echo ""

case $OS in
  ubuntu|debian)
    echo "Installing QEMU for Ubuntu/Debian..."
    sudo apt-get update
    sudo apt-get install -y qemu-system-x86 qemu-utils
    ;;
    
  rhel|centos|fedora|almalinux)
    echo "Installing QEMU for RHEL/CentOS/Fedora..."
    if command -v dnf &>/dev/null; then
      sudo dnf install -y qemu-kvm qemu-img
    else
      sudo yum install -y qemu-kvm qemu-img
    fi
    ;;
    
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

echo ""
echo "✓ QEMU installed successfully"
echo ""

# Check QEMU installation
if command_exists qemu-system-x86_64; then
    print_status "ok" "QEMU is installed"
    QEMU_VERSION=$(qemu-system-x86_64 --version | head -1 | awk '{print $4}')
    echo "      Version: $QEMU_VERSION"
else
    print_status "warn" "QEMU not found in PATH"
fi

# Check libvirt service
echo -e "\n${BLUE}[4/9]${NC} Checking libvirt service status..."
if systemctl is-active --quiet libvirtd; then
    print_status "ok" "Libvirtd service is running"
else
    print_status "warn" "Libvirtd service is not running. Starting..."
    systemctl start libvirtd || {
        print_status "error" "Failed to start libvirtd service"
        systemctl status libvirtd --no-pager
        exit 1
    }
    systemctl enable libvirtd
    print_status "ok" "Libvirtd service started and enabled"
fi

# Wait for libvirtd to be fully ready
sleep 2

# Check libvirt connection
echo -e "\n${BLUE}[5/9]${NC} Checking libvirt connection..."
if virsh version &>/dev/null; then
    print_status "ok" "Can connect to libvirt daemon"
else
    print_status "error" "Cannot connect to libvirt daemon"
    echo -e "${YELLOW}Checking libvirt socket...${NC}"
    ls -la /var/run/libvirt/libvirt-sock* 2>/dev/null || true
    exit 1
fi

# Check Terraform installation
echo -e "\n${BLUE}[6/9]${NC} Checking Terraform installation..."
if command_exists terraform; then
    print_status "ok" "Terraform is installed"
    if command_exists jq; then
        TF_VERSION=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | awk '{print $2}')
    else
        TF_VERSION=$(terraform version | head -1 | awk '{print $2}')
    fi
    echo "      Version: $TF_VERSION"
else
    print_status "error" "Terraform is not installed"
    echo -e "${YELLOW}Install from: https://www.terraform.io/downloads${NC}"
    exit 1
fi

# Check required tools
echo -e "\n${BLUE}[7/9]${NC} Checking required tools..."
REQUIRED_TOOLS=("jq" "curl" "wget" "ssh" "ssh-keygen")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if command_exists "$tool"; then
        print_status "ok" "$tool is installed"
    else
        print_status "warn" "$tool is not installed"
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Install missing tools with: sudo apt install -y ${MISSING_TOOLS[*]}${NC}"
fi
# Check storage pool
echo -e "\n${BLUE}[8/9]${NC} Checking storage pool configuration..."
POOL_NAME="${POOL_NAME:-k3s_infra_pool}"
POOL_PATH="/var/lib/libvirt/images/${POOL_NAME}"

# Function to check if pool is truly active
is_pool_active() {
    local pool=$1
    # Check multiple ways to ensure pool is active
    if virsh pool-list --all 2>/dev/null | grep -w "$pool" | grep -qw "active"; then
        return 0
    elif virsh pool-info "$pool" 2>/dev/null | grep -q "State:.*running"; then
        return 0
    else
        return 1
    fi
}

# Check if pool exists
if virsh pool-info "$POOL_NAME" &>/dev/null; then
    print_status "ok" "Storage pool '$POOL_NAME' exists"
    
    # Get pool state
    POOL_STATE=$(virsh pool-info "$POOL_NAME" 2>/dev/null | grep "State:" | awk '{print $2}')
    echo "      Current State: $POOL_STATE"
    
    # Check if pool is active using multiple methods
    if is_pool_active "$POOL_NAME"; then
        print_status "ok" "Storage pool '$POOL_NAME' is active"
    else
        print_status "warn" "Storage pool '$POOL_NAME' is inactive (State: $POOL_STATE). Attempting to start..."
        
        # Try to start the pool
        START_OUTPUT=$(virsh pool-start "$POOL_NAME" 2>&1)
        START_EXIT_CODE=$?
        
        if [ $START_EXIT_CODE -eq 0 ]; then
            print_status "ok" "Storage pool '$POOL_NAME' started successfully"
        else
            # Check if error is because pool is already active
            if echo "$START_OUTPUT" | grep -qi "already active\|already started"; then
                print_status "ok" "Storage pool '$POOL_NAME' is already active"
            elif echo "$START_OUTPUT" | grep -qi "state: running"; then
                print_status "ok" "Storage pool '$POOL_NAME' is already running"
            else
                print_status "error" "Failed to start storage pool '$POOL_NAME'"
                echo "      Error details:"
                echo "$START_OUTPUT" | sed 's/^/      /'
                
                # Show detailed pool info for debugging
                echo ""
                echo -e "${YELLOW}Detailed pool information:${NC}"
                virsh pool-info "$POOL_NAME" 2>&1 | sed 's/^/      /'
                
                # Check pool XML configuration
                echo ""
                echo -e "${YELLOW}Pool XML configuration:${NC}"
                virsh pool-dumpxml "$POOL_NAME" 2>&1 | sed 's/^/      /'
                
                # Check directory permissions
                if [ -d "$POOL_PATH" ]; then
                    echo ""
                    echo -e "${YELLOW}Directory permissions:${NC}"
                    ls -ld "$POOL_PATH" | sed 's/^/      /'
                fi
                
                # Don't exit immediately, try to fix
                echo ""
                echo -e "${YELLOW}Attempting to fix pool configuration...${NC}"
                
                # Try to destroy and redefine pool
                virsh pool-destroy "$POOL_NAME" 2>/dev/null || true
                sleep 2
                
                # Redefine pool
                if virsh pool-define-as --name "$POOL_NAME" --type dir --target "$POOL_PATH" 2>/dev/null; then
                    print_status "ok" "Pool redefined successfully"
                    
                    # Try to start again
                    if virsh pool-start "$POOL_NAME" 2>/dev/null; then
                        print_status "ok" "Pool started successfully after redefine"
                    else
                        print_status "error" "Still cannot start pool after redefine"
                        exit 1
                    fi
                else
                    print_status "error" "Failed to redefine pool"
                    exit 1
                fi
            fi
        fi
    fi
    
    # Verify pool is now active
    sleep 1
    if is_pool_active "$POOL_NAME"; then
        print_status "ok" "Verified: Storage pool '$POOL_NAME' is active"
        
        # Refresh pool to update volume list
        if virsh pool-refresh "$POOL_NAME" &>/dev/null; then
            print_status "ok" "Pool refreshed successfully"
        fi
    else
        print_status "error" "Pool verification failed - pool is not active"
        virsh pool-info "$POOL_NAME" 2>&1 | sed 's/^/      /'
        exit 1
    fi
    
else
    print_status "warn" "Storage pool '$POOL_NAME' does not exist. Creating..."
    
    # Create directory if not exists
    if [ ! -d "$POOL_PATH" ]; then
        mkdir -p "$POOL_PATH"
        print_status "ok" "Created pool directory: $POOL_PATH"
    fi
    
    # Set proper permissions
    chmod 711 "$POOL_PATH"
    chown root:root "$POOL_PATH"
    
    # Set SELinux context if SELinux is enabled
    if command_exists semanage && sestatus 2>/dev/null | grep -q "enabled"; then
        chcon -t virt_image_t "$POOL_PATH" 2>/dev/null || true
        print_status "ok" "SELinux context set for pool directory"
    fi
    
    # Define pool
    if virsh pool-define-as --name "$POOL_NAME" --type dir --target "$POOL_PATH" 2>/dev/null; then
        print_status "ok" "Pool '$POOL_NAME' defined"
    else
        print_status "error" "Failed to define pool '$POOL_NAME'"
        exit 1
    fi
    
    # Build pool (create directory structure)
    BUILD_OUTPUT=$(virsh pool-build "$POOL_NAME" 2>&1)
    if [ $? -eq 0 ]; then
        print_status "ok" "Pool '$POOL_NAME' built"
    else
        if echo "$BUILD_OUTPUT" | grep -qi "already exists"; then
            print_status "ok" "Pool directory already exists (skipping build)"
        else
            print_status "warn" "Pool build had issues: $BUILD_OUTPUT"
        fi
    fi
    
    # Start pool
    if virsh pool-start "$POOL_NAME" 2>/dev/null; then
        print_status "ok" "Pool '$POOL_NAME' started"
    else
        print_status "error" "Failed to start pool '$POOL_NAME'"
        virsh pool-info "$POOL_NAME" 2>&1 | sed 's/^/      /'
        exit 1
    fi
    
    # Enable autostart
    if virsh pool-autostart "$POOL_NAME" 2>/dev/null; then
        print_status "ok" "Pool '$POOL_NAME' set to autostart"
    else
        print_status "warn" "Failed to set autostart for pool '$POOL_NAME'"
    fi
    
    # Verify pool is active
    sleep 1
    if is_pool_active "$POOL_NAME"; then
        print_status "ok" "Pool creation verified successfully"
    else
        print_status "error" "Pool was created but is not active"
        exit 1
    fi
fi

# Verify pool path and permissions
if [ -d "$POOL_PATH" ]; then
    print_status "ok" "Pool directory exists: $POOL_PATH"
    
    POOL_PERMS=$(stat -c "%a" "$POOL_PATH")
    POOL_OWNER=$(stat -c "%U:%G" "$POOL_PATH")
    echo "      Permissions: $POOL_PERMS"
    echo "      Owner: $POOL_OWNER"
    
    # Check if permissions are acceptable (711, 755, or 750)
    if [[ "$POOL_PERMS" =~ ^(711|755|750)$ ]]; then
        print_status "ok" "Pool directory has acceptable permissions"
    else
        print_status "warn" "Fixing pool directory permissions from $POOL_PERMS to 711..."
        chmod 711 "$POOL_PATH"
        print_status "ok" "Pool directory permissions fixed"
    fi
    
    # Verify directory is writable by libvirt
    if sudo -u libvirt-qemu test -w "$POOL_PATH" 2>/dev/null; then
        print_status "ok" "Pool directory is writable by libvirt-qemu user"
    else
        print_status "warn" "Pool directory may not be writable by libvirt-qemu"
        echo -e "${YELLOW}      Adjusting permissions...${NC}"
        chmod 755 "$POOL_PATH"
        chown root:libvirt "$POOL_PATH" 2>/dev/null || chown root:kvm "$POOL_PATH" 2>/dev/null || true
    fi
else
    print_status "error" "Pool directory does not exist: $POOL_PATH"
    exit 1
fi

# Check available disk space
AVAILABLE_SPACE=$(df -BG "$POOL_PATH" | awk 'NR==2 {print $4}' | sed 's/G//')
USED_SPACE=$(df -BG "$POOL_PATH" | awk 'NR==2 {print $3}' | sed 's/G//')
TOTAL_SPACE=$(df -BG "$POOL_PATH" | awk 'NR==2 {print $2}' | sed 's/G//')
REQUIRED_SPACE=20

echo "      Total: ${TOTAL_SPACE}GB | Used: ${USED_SPACE}GB | Available: ${AVAILABLE_SPACE}GB"

if [ "$AVAILABLE_SPACE" -ge "$REQUIRED_SPACE" ]; then
    print_status "ok" "Sufficient disk space available: ${AVAILABLE_SPACE}GB"
else
    print_status "warn" "Low disk space: ${AVAILABLE_SPACE}GB (recommended: ${REQUIRED_SPACE}GB+)"
    echo -e "${YELLOW}      Consider freeing up disk space before deployment${NC}"
fi

# Show pool volumes if any
VOLUME_COUNT=$(virsh vol-list "$POOL_NAME" 2>/dev/null | grep -c "^\ " || echo "0")
if [ "$VOLUME_COUNT" -gt 0 ]; then
    echo "      Existing volumes: $VOLUME_COUNT"
fi

# Check network configuration
echo -e "\n${BLUE}[9/9]${NC} Checking network configuration..."
NETWORK_NAME="${NETWORK_NAME:-default}"

if virsh net-info "$NETWORK_NAME" &>/dev/null; then
    print_status "ok" "Network '$NETWORK_NAME' exists"
    
    # Check if network is active
    if virsh net-list --active 2>/dev/null | grep -q "$NETWORK_NAME"; then
        print_status "ok" "Network '$NETWORK_NAME' is active"
    else
        print_status "warn" "Network '$NETWORK_NAME' is inactive. Starting..."
        
        # Check if network is already active (race condition)
        if virsh net-info "$NETWORK_NAME" 2>/dev/null | grep -q "Active:.*yes"; then
            print_status "ok" "Network '$NETWORK_NAME' is already active"
        else
            if virsh net-start "$NETWORK_NAME" 2>/dev/null; then
                print_status "ok" "Network '$NETWORK_NAME' started"
            else
                # Check error message
                ERROR_MSG=$(virsh net-start "$NETWORK_NAME" 2>&1 || true)
                if echo "$ERROR_MSG" | grep -q "already active"; then
                    print_status "ok" "Network '$NETWORK_NAME' is already active"
                else
                    print_status "error" "Failed to start network '$NETWORK_NAME'"
                    echo "$ERROR_MSG"
                    exit 1
                fi
            fi
        fi
    fi
    
    # Enable autostart
    if ! virsh net-info "$NETWORK_NAME" | grep -q "Autostart:.*yes"; then
        virsh net-autostart "$NETWORK_NAME" &>/dev/null || true
        print_status "ok" "Network '$NETWORK_NAME' set to autostart"
    fi
    
    # Show network details
    NET_BRIDGE=$(virsh net-info "$NETWORK_NAME" | grep "Bridge:" | awk '{print $2}')
    echo "      Bridge: $NET_BRIDGE"
else
    print_status "error" "Network '$NETWORK_NAME' does not exist"
    echo -e "${YELLOW}Create default network with:${NC}"
    echo "  virsh net-define /usr/share/libvirt/networks/default.xml"
    echo "  virsh net-start default"
    echo "  virsh net-autostart default"
    exit 1
fi


# Check Terraform state
echo -e "\n${BLUE}[10/10]${NC} Checking Terraform configuration..."

# Check if we're in terraform directory
if [ -f "main.tf" ] || ls *.tf &>/dev/null; then
    print_status "ok" "Terraform configuration files found"
    
    # Count terraform files
    TF_FILE_COUNT=$(ls -1 *.tf 2>/dev/null | wc -l)
    echo "      Configuration files: $TF_FILE_COUNT"
    
    # Check for terraform.tfvars or *.auto.tfvars
    if [ -f "terraform.tfvars" ] || ls *.auto.tfvars &>/dev/null 2>&1; then
        print_status "ok" "Variable files found"
    else
        print_status "warn" "No terraform.tfvars or *.auto.tfvars found"
        echo -e "${YELLOW}      Consider creating terraform.tfvars from example.tfvars${NC}"
    fi
    
    # Check if terraform is initialized
    if [ -d ".terraform" ]; then
        print_status "ok" "Terraform is initialized"
        
        # Check provider lock file
        if [ -f ".terraform.lock.hcl" ]; then
            print_status "ok" "Provider lock file exists"
        else
            print_status "warn" "Provider lock file not found"
        fi
    else
        print_status "warn" "Terraform not initialized"
        echo -e "${YELLOW}      Run: terraform init${NC}"
    fi
    
    # Check terraform state
    if [ -f "terraform.tfstate" ]; then
        print_status "ok" "Terraform state file exists"
        
        # Validate state file
        if terraform state list &>/dev/null 2>&1; then
            RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l)
            print_status "ok" "State file is valid ($RESOURCE_COUNT resources)"
        else
            print_status "warn" "State file may be corrupted or empty"
        fi
        
        # Check state backup
        if [ -f "terraform.tfstate.backup" ]; then
            BACKUP_AGE=$(stat -c %Y "terraform.tfstate.backup")
            CURRENT_TIME=$(date +%s)
            AGE_HOURS=$(( (CURRENT_TIME - BACKUP_AGE) / 3600 ))
            echo "      State backup age: ${AGE_HOURS}h"
        fi
    else
        print_status "ok" "No existing state file (fresh deployment)"
    fi
else
    print_status "warn" "No Terraform configuration files found in current directory"
    echo -e "${YELLOW}      Make sure you're in the correct directory${NC}"
fi

# Additional checks for SSH keys
echo -e "\n${BLUE}[11/11]${NC} Checking SSH configuration..."
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

if [ -f "$SSH_KEY_PATH" ]; then
    print_status "ok" "SSH private key found: $SSH_KEY_PATH"
    
    # Check key permissions
    KEY_PERMS=$(stat -c "%a" "$SSH_KEY_PATH")
    if [ "$KEY_PERMS" = "600" ]; then
        print_status "ok" "SSH key has correct permissions: $KEY_PERMS"
    else
        print_status "warn" "SSH key permissions should be 600 (current: $KEY_PERMS)"
        echo -e "${YELLOW}      Fix with: chmod 600 $SSH_KEY_PATH${NC}"
    fi
    
    if [ -f "$SSH_PUB_KEY_PATH" ]; then
        print_status "ok" "SSH public key found: $SSH_PUB_KEY_PATH"
    else
        print_status "warn" "SSH public key not found"
    fi
else
    print_status "warn" "Default SSH key not found at $SSH_KEY_PATH"
    echo -e "${YELLOW}      Generate with: ssh-keygen -t rsa -b 4096 -C 'your_email@example.com'${NC}"
fi

# Summary section
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}  ║          Pre-Flight Check Completed Successfully       ║${NC}"
echo -e "${GREEN}  ╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}                    SYSTEM SUMMARY                        ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}System Information:${NC}"
echo "  • OS: $OS_NAME $OS_VERSION"
echo "  • Kernel: $KERNEL_VERSION"
echo "  • Virtualization: $([ "$VT_TYPE" = "vmx" ] && echo "Intel VT-x" || echo "AMD-V")"
echo ""
echo -e "${CYAN}Software Versions:${NC}"
echo "  • Libvirt: $LIBVIRT_VERSION"
echo "  • Terraform: $TF_VERSION"
if command_exists qemu-system-x86_64; then
    echo "  • QEMU: $QEMU_VERSION"
fi
echo ""
echo -e "${CYAN}Storage Configuration:${NC}"
echo "  • Pool Name: $POOL_NAME"
echo "  • Pool Path: $POOL_PATH"
echo "  • Total Space: ${TOTAL_SPACE}GB"
echo "  • Available: ${AVAILABLE_SPACE}GB"
echo "  • Used: ${USED_SPACE}GB"
echo ""
echo -e "${CYAN}Network Configuration:${NC}"
echo "  • Network: $NETWORK_NAME (Active)"
if [ -n "$NET_BRIDGE" ]; then
    echo "  • Bridge: $NET_BRIDGE"
fi
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}✅ System is ready for Terraform deployment${NC}"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo "  1. Initialize Terraform (if not done): ${YELLOW}terraform init${NC}"
echo "  2. Validate configuration: ${YELLOW}terraform validate${NC}"
echo "  3. Plan deployment: ${YELLOW}terraform plan${NC}"
echo "  4. Apply configuration: ${YELLOW}terraform apply${NC}"
echo ""
echo -e "${CYAN}Log file saved to: ${YELLOW}$LOG_FILE${NC}"
echo ""

exit 0