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
LOG_FILE="$LOG_DIR/terraform-destroy-$(date +%Y%m%d-%H%M%S).log"

# Parse arguments
AUTO_APPROVE=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --auto-approve    Skip interactive approval"
            echo "  --force           Force destroy even with errors"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║          Terraform Destroy - Infrastructure Cleanup     ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
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

# Check if terraform directory exists
if [ ! -d "$TF_DIR" ]; then
    print_status "error" "Terraform directory not found: $TF_DIR"
    exit 1
fi

cd "$TF_DIR"
print_status "ok" "Changed to Terraform directory: $TF_DIR"
echo ""

# Check if state file exists
if [ ! -f "terraform.tfstate" ]; then
    print_status "warn" "No terraform state file found"
    echo -e "${YELLOW}Nothing to destroy${NC}"
    exit 0
fi

# Show current resources
echo -e "${BLUE}[1/4]${NC} Checking current infrastructure..."
echo ""

RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l)

if [ "$RESOURCE_COUNT" -eq 0 ]; then
    print_status "warn" "No resources found in state"
    echo -e "${YELLOW}Nothing to destroy${NC}"
    exit 0
fi

print_status "ok" "Found $RESOURCE_COUNT resources to destroy"
echo ""
echo -e "${CYAN}Resources:${NC}"
terraform state list | sed 's/^/  • /'
echo ""

# Create state backup
echo -e "${BLUE}[2/4]${NC} Creating state backup..."
BACKUP_FILE="terraform.tfstate.backup-destroy-$(date +%Y%m%d-%H%M%S)"
cp terraform.tfstate "$BACKUP_FILE"
print_status "ok" "State backed up to: $BACKUP_FILE"
echo ""

# Show destroy plan
echo -e "${BLUE}[3/4]${NC} Generating destroy plan..."
echo ""

if terraform plan -destroy 2>&1 | tee -a "$LOG_FILE"; then
    print_status "ok" "Destroy plan generated"
else
    print_status "error" "Failed to generate destroy plan"
    exit 1
fi
echo ""

# Confirmation
echo -e "${BLUE}[4/4]${NC} Destroying infrastructure..."
echo ""

if [ "$AUTO_APPROVE" = false ]; then
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  WARNING ⚠️                       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}This will PERMANENTLY DESTROY all infrastructure!${NC}"
    echo -e "${YELLOW}• All VMs will be deleted${NC}"
    echo -e "${YELLOW}• All volumes will be removed${NC}"
    echo -e "${YELLOW}• All data will be lost${NC}"
    echo ""
    echo -e "${RED}This action CANNOT be undone!${NC}"
    echo ""
    read -p "Type 'yes' to confirm destruction: " -r REPLY
    echo ""
    
    if [[ ! $REPLY = "yes" ]]; then
        print_status "warn" "Destruction cancelled by user"
        exit 0
    fi
    
    echo -e "${YELLOW}Final confirmation required!${NC}"
    read -p "Type 'destroy' to proceed: " -r REPLY2
    echo ""
    
    if [[ ! $REPLY2 = "destroy" ]]; then
        print_status "warn" "Destruction cancelled by user"
        exit 0
    fi
fi

echo -e "${RED}Starting destruction...${NC}"
echo ""

START_TIME=$(date +%s)

# Destroy with error handling
DESTROY_ARGS="-auto-approve"
if [ "$FORCE" = true ]; then
    DESTROY_ARGS="$DESTROY_ARGS -refresh=false"
fi

if terraform destroy $DESTROY_ARGS 2>&1 | tee -a "$LOG_FILE"; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Infrastructure Destroyed Successfully ✅        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}Destruction completed in ${DURATION}s${NC}"
    echo ""
    
    # Verify cleanup
    echo -e "${BLUE}Verifying cleanup...${NC}"
    
    # Check for remaining VMs
    REMAINING_VMS=$(sudo virsh list --all 2>/dev/null | grep -c "ubuntu" || echo "0")
    if [ "$REMAINING_VMS" -eq 0 ]; then
        print_status "ok" "No VMs remaining"
    else
        print_status "warn" "$REMAINING_VMS VMs still exist"
    fi
    

    # Check for remaining volumes
    POOL_NAME="${POOL_NAME:-k3s_infra_pool}"
    if sudo virsh pool-info "$POOL_NAME" &>/dev/null; then
        REMAINING_VOLUMES=$(sudo virsh vol-list "$POOL_NAME" 2>/dev/null | grep -c "ubuntu" || echo "0")
        if [ "$REMAINING_VOLUMES" -eq 0 ]; then
            print_status "ok" "No volumes remaining"
        else
            print_status "warn" "$REMAINING_VOLUMES volumes still exist"
            echo -e "${YELLOW}      Clean up with: sudo virsh vol-delete <volume-name> --pool $POOL_NAME${NC}"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}Cleanup Summary:${NC}"
    echo "  • State backup: $BACKUP_FILE"
    echo "  • Log file: $LOG_FILE"
    echo ""
    
    exit 0
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Destruction Failed ❌                      ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Destruction failed after ${DURATION}s${NC}"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo "  1. Check log file: ${YELLOW}cat $LOG_FILE${NC}"
    echo "  2. Review state: ${YELLOW}terraform show${NC}"
    echo "  3. List resources: ${YELLOW}terraform state list${NC}"
    echo "  4. Check VMs: ${YELLOW}sudo virsh list --all${NC}"
    echo ""
    echo -e "${YELLOW}Manual cleanup (if needed):${NC}"
    echo "  1. Force destroy: ${YELLOW}$0 --force --auto-approve${NC}"
    echo "  2. Remove from state: ${YELLOW}terraform state rm <resource>${NC}"
    echo "  3. Manual VM cleanup: ${YELLOW}sudo virsh destroy <vm-name> && sudo virsh undefine <vm-name>${NC}"
    echo ""
    
    exit 1
fi