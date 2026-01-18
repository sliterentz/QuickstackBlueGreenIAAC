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

# Source domain manager
source "$SCRIPT_DIR/domain_manager.sh"

# Function to check if resource exists in Terraform state
check_terraform_resource() {
    local resource_address="$1"
    
    cd "$PROJECT_ROOT"
    
    if terraform state show "$resource_address" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to sync existing domain with Terraform
sync_domain_with_terraform() {
    local domain_name="$1"
    
    echo -e "${CYAN}Syncing domain '$domain_name' with Terraform state...${NC}"
    
    # Check if domain exists in libvirt
    if ! check_domain_exists "$domain_name"; then
        echo -e "${RED}✗ Domain does not exist in libvirt${NC}"
        return 1
    fi
    
    # Get domain UUID
    local domain_uuid=$(virsh domuuid "$domain_name" 2>/dev/null)
    
    # Check if domain is in Terraform state
    if check_terraform_resource "libvirt_domain.ubuntu_vm"; then
        local state_uuid=$(terraform state show "libvirt_domain.ubuntu_vm" 2>/dev/null | grep -oP 'id\s*=\s*"\K[^"]+' || echo "")
        
        if [ "$state_uuid" = "$domain_uuid" ]; then
            echo -e "${GREEN}✓ Domain already synced with Terraform${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠ Domain UUID mismatch, re-importing...${NC}"
            terraform state rm "libvirt_domain.ubuntu_vm" 2>/dev/null || true
        fi
    fi
    
    # Import domain to Terraform state
    echo "Importing domain to Terraform state..."
    if terraform import "libvirt_domain.ubuntu_vm" "$domain_uuid" 2>/dev/null; then
        echo -e "${GREEN}✓ Domain imported successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to import domain${NC}"
        return 1
    fi
}

# Function to handle Terraform lifecycle with domain preservation
terraform_lifecycle_preserve() {
    local action="$1"  # plan, apply, destroy
    local auto_approve="${2:-false}"
    
    cd "$PROJECT_ROOT"
    
    echo -e "${CYAN}Terraform lifecycle: $action (preserve mode)${NC}"
    
    # Get VM hostname
    local vm_hostname=$(grep -E '^\s*vm_hostname\s*=' example.tfvars 2>/dev/null | cut -d'"' -f2 || echo "ubuntu-vm")
    local sanitized=$(echo "$vm_hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    # Check if domain exists
    if check_domain_exists "$sanitized"; then
        echo -e "${CYAN}Existing domain detected: $sanitized${NC}"
        
        # Sync with Terraform state
        if sync_domain_with_terraform "$sanitized"; then
            echo -e "${GREEN}✓ Domain synced with Terraform${NC}"
            
            # For apply action, use refresh-only first
            if [ "$action" = "apply" ]; then
                echo "Running terraform refresh to sync state..."
                terraform refresh -var-file=example.tfvars || true
            fi
        else
            echo -e "${YELLOW}⚠ Failed to sync domain, Terraform may recreate it${NC}"
        fi
    fi
    
    # Execute Terraform action
    case "$action" in
        plan)
            terraform plan -var-file=example.tfvars -out=tfplan
            ;;
        apply)
            if [ "$auto_approve" = "true" ]; then
                terraform apply -var-file=example.tfvars -auto-approve
            else
                if [ -f "tfplan" ]; then
                    terraform apply tfplan
                else
                    terraform apply -var-file=example.tfvars
                fi
            fi
            ;;
        destroy)
            if [ "$auto_approve" = "true" ]; then
                terraform destroy -var-file=example.tfvars -auto-approve
            else
                terraform destroy -var-file=example.tfvars
            fi
            ;;
        *)
            echo -e "${RED}✗ Unknown action: $action${NC}"
            return 1
            ;;
    esac
}

# Export functions
export -f check_terraform_resource
export -f sync_domain_with_terraform
export -f terraform_lifecycle_preserve