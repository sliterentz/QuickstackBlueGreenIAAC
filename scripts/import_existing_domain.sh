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

# Function to import domain to Terraform state
import_domain_to_terraform() {
    local domain_name="$1"
    local terraform_resource="${2:-libvirt_domain.ubuntu_vm}"
    
    echo -e "${CYAN}Importing domain '$domain_name' to Terraform state...${NC}"
    
    # Check if domain exists in libvirt
    if ! check_domain_exists "$domain_name"; then
        echo -e "${RED}✗ Domain '$domain_name' does not exist in libvirt${NC}"
        return 1
    fi
    
    # Get domain UUID
    local domain_uuid=$(virsh domuuid "$domain_name" 2>/dev/null)
    if [ -z "$domain_uuid" ]; then
        echo -e "${RED}✗ Failed to get domain UUID${NC}"
        return 1
    fi
    
    echo "Domain UUID: $domain_uuid"
    
    # Check if already in Terraform state
    cd "$PROJECT_ROOT"
    
    if terraform state show "$terraform_resource" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Domain already exists in Terraform state${NC}"
        
        # Check if it's the same domain
        local state_uuid=$(terraform state show "$terraform_resource" | grep -oP 'id\s*=\s*"\K[^"]+' || echo "")
        
        if [ "$state_uuid" = "$domain_uuid" ]; then
            echo -e "${GREEN}✓ Domain in state matches libvirt domain${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠ Domain in state differs from libvirt domain${NC}"
            echo "  State UUID: $state_uuid"
            echo "  Libvirt UUID: $domain_uuid"
            
            read -p "Remove from state and re-import? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                terraform state rm "$terraform_resource"
            else
                return 1
            fi
        fi
    fi
    
    # Import domain
    echo "Importing domain to Terraform state..."
    if terraform import "$terraform_resource" "$domain_uuid"; then
        echo -e "${GREEN}✓ Domain imported successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to import domain${NC}"
        return 1
    fi
}

# Function to import volumes to Terraform state
import_volumes_to_terraform() {
    local hostname="$1"
    local pool_name="${2:-k3s_infra_pool}"
    
    echo -e "${CYAN}Importing volumes for '$hostname' to Terraform state...${NC}"
    
    local sanitized=$(echo "$hostname" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    cd "$PROJECT_ROOT"
    
    # Import base image volume
    local base_vol="ubuntu-base-img-${sanitized}.qcow2"
    if virsh vol-info "$base_vol" --pool "$pool_name" >/dev/null 2>&1; then
        echo "Importing base image volume..."
        local vol_path=$(virsh vol-path "$base_vol" --pool "$pool_name")
        
        if ! terraform state show "libvirt_volume.ubuntu_base" >/dev/null 2>&1; then
            terraform import "libvirt_volume.ubuntu_base" "$vol_path" || true
        fi
    fi
    
    # Import main disk volume
    local disk_vol="ubuntu-disk-${sanitized}.qcow2"
    if virsh vol-info "$disk_vol" --pool "$pool_name" >/dev/null 2>&1; then
        echo "Importing disk volume..."
        local vol_path=$(virsh vol-path "$disk_vol" --pool "$pool_name")
        
        if ! terraform state show "libvirt_volume.ubuntu_disk" >/dev/null 2>&1; then
            terraform import "libvirt_volume.ubuntu_disk" "$vol_path" || true
        fi
    fi
    
    # Import cloudinit volume
    local cloudinit_vol="cloudinit-${sanitized}.iso"
    if virsh vol-info "$cloudinit_vol" --pool "$pool_name" >/dev/null 2>&1; then
        echo "Importing cloudinit volume..."
        local vol_path=$(virsh vol-path "$cloudinit_vol" --pool "$pool_name")
        
        if ! terraform state show "libvirt_cloudinit_disk.commoninit" >/dev/null 2>&1; then
            terraform import "libvirt_cloudinit_disk.commoninit" "$vol_path" || true
        fi
    fi
    
    echo -e "${GREEN}✓ Volume import completed${NC}"
}

# Main execution
main() {
    local domain_name="${1:-}"
    
    if [ -z "$domain_name" ]; then
        echo -e "${RED}Error: Domain name required${NC}"
        echo "Usage: $0 <domain_name>"
        exit 1
    fi
    
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Import Existing Domain to Terraform          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Validate domain
    if ! check_domain_exists "$domain_name"; then
        echo -e "${RED}✗ Domain '$domain_name' does not exist${NC}"
        exit 1
    fi
    
    # Show domain info
    echo -e "${CYAN}Domain Information:${NC}"
    virsh dominfo "$domain_name"
    echo ""
    
    # Confirm import
    read -p "Import this domain to Terraform state? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Import cancelled"
        exit 0
    fi
    
    # Import domain
    if import_domain_to_terraform "$domain_name"; then
        echo -e "${GREEN}✓ Domain import successful${NC}"
    else
        echo -e "${RED}✗ Domain import failed${NC}"
        exit 1
    fi
    
    # Import volumes
    echo ""
    read -p "Import associated volumes? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        import_volumes_to_terraform "$domain_name"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Import Completed Successfully             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Run 'terraform plan' to verify state"
    echo "  2. Run 'terraform apply' to sync any differences"
}

# Run main function
main "$@"