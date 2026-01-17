#!/bin/bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform-kvm-ubuntu"

# Logging
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/terraform-apply-$(date +%Y%m%d-%H%M%S).log"

# Parse arguments
AUTO_APPROVE=false
PLAN_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --plan-file)
            PLAN_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --auto-approve    Skip interactive approval"
            echo "  --plan-file FILE  Use existing plan file"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Before terraform apply, add:
echo "Checking for volume conflicts..."
cd terraform-kvm-ubuntu
# Check if state exists and has cloudinit resource
if [ -f terraform.tfstate ]; then
    if grep -q "libvirt_cloudinit_disk.commoninit" terraform.tfstate; then
        echo "⚠ Found existing cloudinit resource in state"
        echo "Removing from state to allow recreation..."
        terraform state rm libvirt_cloudinit_disk.commoninit 2>/dev/null || true
    fi
fi

cd ..

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Terraform Apply - Safe Deployment             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}Log file: $LOG_FILE${NC}"
echo ""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    
    if [ "$status" = "ok" ]; then
        echo -e "${GREEN}✓${NC} $message"
    elif [ "$status" = "warn" ]; then
        echo -e "${YELLOW}⚠${NC} $message"
    else
        echo -e "${RED}✗${NC} $message"
    fi
}

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if terraform directory exists
if [ ! -d "$TF_DIR" ]; then
    print_status "error" "Terraform directory not found: $TF_DIR"
    log_message "ERROR: Terraform directory not found: $TF_DIR"
    exit 1
fi

cd "$TF_DIR"
print_status "ok" "Changed to Terraform directory: $TF_DIR"
log_message "Changed to Terraform directory: $TF_DIR"
echo ""

# Step 1: Pre-deployment checks
echo -e "${BLUE}[1/7]${NC} Running pre-deployment checks..."
log_message "Starting pre-deployment checks"

# Check if libvirtd is running
if ! systemctl is-active --quiet libvirtd; then
    print_status "error" "libvirtd service is not running"
    log_message "Starting pre-deployment checks"
    echo -e "${YELLOW}Start with: sudo systemctl start libvirtd${NC}"
    exit 1
fi
print_status "ok" "libvirtd service is running"
log_message "libvirtd service is running"

# Check storage pool
POOL_NAME="${POOL_NAME:-k3s_infra_pool}"
if ! sudo virsh pool-info "$POOL_NAME" &>/dev/null; then
    print_status "error" "Storage pool '$POOL_NAME' not found"
    log_message "ERROR: Storage pool '$POOL_NAME' not found"
    echo -e "${YELLOW}Run pre-flight check: sudo ./scripts/pre-flight-check.sh${NC}"
    exit 1
fi
print_status "ok" "libvirtd service is running"
log_message "libvirtd service is running"

# Check storage pool
POOL_NAME="${POOL_NAME:-k3s_infra_pool}"
log_message "Checking storage pool: $POOL_NAME"

if ! sudo virsh pool-info "$POOL_NAME" &>/dev/null; then
    print_status "error" "Storage pool '$POOL_NAME' not found"
    log_message "ERROR: Storage pool '$POOL_NAME' not found"
    echo -e "${YELLOW}Run pre-flight check: sudo ./scripts/pre-flight-check.sh${NC}"
    exit 1
fi

# Fixed: Check if pool is active using pool-info instead of pool-list --active
POOL_STATE=$(sudo virsh pool-info "$POOL_NAME" 2>/dev/null | grep "State:" | awk '{print $2}')
log_message "Storage pool state: $POOL_STATE"

if [ "$POOL_STATE" != "running" ]; then
    print_status "warn" "Storage pool '$POOL_NAME' is not active. Starting..."
    log_message "Attempting to start storage pool"
    
    if sudo virsh pool-start "$POOL_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Storage pool started successfully"
        log_message "Storage pool started successfully"
    else
        # Pool might already be active, check again
        POOL_STATE=$(sudo virsh pool-info "$POOL_NAME" 2>/dev/null | grep "State:" | awk '{print $2}')
        if [ "$POOL_STATE" = "running" ]; then
            print_status "ok" "Storage pool is already active"
            log_message "Storage pool is already active"
        else
            print_status "error" "Failed to start storage pool"
            log_message "ERROR: Failed to start storage pool"
            exit 1
        fi
    fi
else
    print_status "ok" "Storage pool '$POOL_NAME' is ready"
    log_message "Storage pool is ready"
fi

# Check network
NETWORK_NAME="${NETWORK_NAME:-default}"
log_message "Checking network: $NETWORK_NAME"

if ! sudo virsh net-info "$NETWORK_NAME" &>/dev/null; then
    print_status "error" "Network '$NETWORK_NAME' not found"
    log_message "ERROR: Network '$NETWORK_NAME' not found"
    exit 1
fi

# Fixed: Check if network is active using net-info instead of net-list --active
NET_STATE=$(sudo virsh net-info "$NETWORK_NAME" 2>/dev/null | grep "Active:" | awk '{print $2}')
log_message "Network state: $NET_STATE"

if [ "$NET_STATE" != "yes" ]; then
    print_status "warn" "Network '$NETWORK_NAME' is not active. Starting..."
    log_message "Attempting to start network"
    
    if sudo virsh net-start "$NETWORK_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Network started successfully"
        log_message "Network started successfully"
    else
        # Network might already be active, check again
        NET_STATE=$(sudo virsh net-info "$NETWORK_NAME" 2>/dev/null | grep "Active:" | awk '{print $2}')
        if [ "$NET_STATE" = "yes" ]; then
            print_status "ok" "Network is already active"
            log_message "Network is already active"
        else
            print_status "error" "Failed to start network"
            log_message "ERROR: Failed to start network"
            exit 1
        fi
    fi
else
    print_status "ok" "Network '$NETWORK_NAME' is ready"
    log_message "Network is ready"
fi
echo ""

# Step 2: Check Terraform initialization
echo -e "${BLUE}[2/7]${NC} Checking Terraform initialization..."
log_message "Checking Terraform initialization"

if [ ! -d ".terraform" ]; then
    print_status "warn" "Terraform not initialized. Running terraform init..."
    log_message "Running terraform init"
    
    if terraform init -upgrade 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Terraform initialized successfully"
        log_message "Terraform initialized successfully"
    else
        print_status "error" "Terraform initialization failed"
        log_message "ERROR: Terraform initialization failed"
        exit 1
    fi
else
    print_status "ok" "Terraform is initialized"
    log_message "Terraform is initialized"
fi
echo ""

# Step 3: Validate configuration
echo -e "${BLUE}[3/7]${NC} Validating Terraform configuration..."
log_message "Validating Terraform configuration"

if terraform validate 2>&1 | tee -a "$LOG_FILE"; then
    print_status "ok" "Configuration is valid"
    log_message "Configuration is valid"
else
    print_status "error" "Configuration validation failed"
    log_message "ERROR: Configuration validation failed"
    exit 1
fi
echo ""

# Step 4: Create backup of existing state
echo -e "${BLUE}[4/7]${NC} Creating state backup..."
log_message "Creating state backup"

if [ -f "terraform.tfstate" ]; then
    BACKUP_FILE="terraform.tfstate.backup-$(date +%Y%m%d-%H%M%S)"
    cp terraform.tfstate "$BACKUP_FILE"
    print_status "ok" "State backed up to: $BACKUP_FILE"
    log_message "State backed up to: $BACKUP_FILE"
else
    print_status "ok" "No existing state to backup (fresh deployment)"
    log_message "No existing state to backup"
fi
echo ""

# Step 5: Run plan if no plan file provided
if [ -z "$PLAN_FILE" ]; then
    echo -e "${BLUE}[5/7]${NC} Running Terraform plan..."
    echo -e "${CYAN}This may take a few minutes...${NC}"
    log_message "Running Terraform plan"
    echo ""
    
    PLAN_FILE="tfplan-apply-$(date +%Y%m%d-%H%M%S).out"
    
    if terraform plan -out="$PLAN_FILE" 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Plan created successfully"
        log_message "Plan created successfully: $PLAN_FILE"
    else
        print_status "error" "Plan creation failed"
        log_message "ERROR: Plan creation failed"        
        exit 1
    fi
else
    echo -e "${BLUE}[5/7]${NC} Using existing plan file..."
    log_message "Using existing plan file: $PLAN_FILE"

    if [ ! -f "$PLAN_FILE" ]; then
        print_status "error" "Plan file not found: $PLAN_FILE"
        log_message "ERROR: Plan file not found: $PLAN_FILE"
        exit 1
    fi
    print_status "ok" "Plan file found: $PLAN_FILE"
fi
echo ""

# Step 6: Show plan summary
echo -e "${BLUE}[6/7]${NC} Reviewing deployment plan..."
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}                    DEPLOYMENT PLAN                       ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

terraform show -no-color "$PLAN_FILE" | grep -E "Plan:|will be|# " | head -30

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 7: Confirmation and apply
echo -e "${BLUE}[7/7]${NC} Applying Terraform configuration..."
echo ""

if [ "$AUTO_APPROVE" = false ]; then
    echo -e "${YELLOW}⚠️  WARNING: This will create/modify/destroy infrastructure${NC}"
    echo -e "${YELLOW}⚠️  Review the plan above carefully${NC}"
    echo ""
    read -p "Do you want to proceed? (yes/no): " -r REPLY
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "warn" "Deployment cancelled by user"
        echo ""
        echo -e "${CYAN}Plan file saved for later use: $PLAN_FILE${NC}"
        echo -e "${CYAN}Apply later with: terraform apply \"$PLAN_FILE\"${NC}"
        exit 0
    fi
fi

echo -e "${CYAN}Starting deployment...${NC}"
echo ""

# Set parallelism for better performance
PARALLELISM=10

# Apply with progress tracking
START_TIME=$(date +%s)

if terraform apply \
    -parallelism=$PARALLELISM \
    ${AUTO_APPROVE:+-auto-approve} \
    "$PLAN_FILE" \
    2>&1 | tee -a "$LOG_FILE"; then
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))
    SECONDS=$((DURATION % 60))
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Deployment Completed Successfully ✅          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Deployment Statistics:${NC}"
    echo "  • Duration: ${MINUTES}m ${SECONDS}s"
    echo "  • Log file: $LOG_FILE"
    echo ""
    
    # Show outputs
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                  DEPLOYMENT OUTPUTS                      ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    terraform output -json 2>/dev/null | jq -r 'to_entries[] | "\(.key): \(.value.value)"' || terraform output
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    

    # Post-deployment verification
    echo -e "${CYAN}Running post-deployment verification...${NC}"
    echo ""
    
    # Get VM name from state
    VM_NAME=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type=="libvirt_domain") | .values.name' 2>/dev/null || echo "")
    
    if [ -n "$VM_NAME" ]; then
        echo -e "${BLUE}Checking VM status...${NC}"
        
        if sudo virsh list --all | grep -q "$VM_NAME"; then
            VM_STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
            
            if [ "$VM_STATE" = "running" ]; then
                print_status "ok" "VM '$VM_NAME' is running"
                
                # Get VM IP
                VM_IP=$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || echo "")
                
                if [ -n "$VM_IP" ]; then
                    echo "      IP Address: $VM_IP"
                    
                    # Test SSH connectivity
                    echo -e "${BLUE}Testing SSH connectivity...${NC}"
                    if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "ubuntu@$VM_IP" "echo 'SSH connection successful'" &>/dev/null; then
                        print_status "ok" "SSH connection successful"
                    else
                        print_status "warn" "SSH connection not yet available (VM may still be booting)"
                        echo -e "${YELLOW}      Wait a few minutes and try: ssh ubuntu@$VM_IP${NC}"
                    fi
                fi
            else
                print_status "warn" "VM '$VM_NAME' state: $VM_STATE"
            fi
        else
            print_status "warn" "VM '$VM_NAME' not found in virsh list"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}✅ Deployment completed successfully!${NC}"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Wait 2-3 minutes for cloud-init to complete"
    echo "  2. Check VM status: ${YELLOW}sudo virsh list --all${NC}"
    echo "  3. View VM console: ${YELLOW}sudo virsh console $VM_NAME${NC}"
    echo "  4. SSH to VM: ${YELLOW}ssh ubuntu@<VM_IP>${NC}"
    echo "  5. Check logs: ${YELLOW}cat $LOG_FILE${NC}"
    echo ""
    
    # Clean up plan file
    rm -f "$PLAN_FILE"
    
    exit 0
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Deployment Failed ❌                       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Deployment failed after ${DURATION}s${NC}"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo "  1. Check log file: ${YELLOW}cat $LOG_FILE${NC}"
    echo "  2. Review Terraform state: ${YELLOW}terraform show${NC}"
    echo "  3. Check libvirt logs: ${YELLOW}sudo journalctl -u libvirtd -n 50${NC}"
    echo "  4. Verify resources: ${YELLOW}sudo virsh list --all${NC}"
    echo ""
    echo -e "${YELLOW}To rollback (if needed):${NC}"
    echo "  ${YELLOW}terraform destroy -auto-approve${NC}"
    echo ""
    
    exit 1
fi