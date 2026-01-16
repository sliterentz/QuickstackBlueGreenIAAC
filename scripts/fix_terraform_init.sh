#!/bin/bash

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Terraform Apply - Automated Fix Script            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# STEP 1: Pre-flight Checks
# ============================================================================
echo -e "${YELLOW}[1/6] Running pre-flight checks...${NC}"

# Check if we're in the right directory
if [ ! -f "main.tf" ]; then
    echo -e "${RED}✗ Error: main.tf not found. Please run from terraform directory${NC}"
    exit 1
fi

# Check if virsh is available
if ! command -v virsh &> /dev/null; then
    echo -e "${RED}✗ Error: virsh command not found. Is libvirt installed?${NC}"
    exit 1
fi

# Check if terraform is available
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}✗ Error: terraform command not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Pre-flight checks passed${NC}"
echo ""

# ============================================================================
# STEP 2: Handle Storage Pool Conflict
# ============================================================================
echo -e "${YELLOW}[2/6] Handling storage pool conflict...${NC}"

POOL_NAME="k3s_infra_pool"

if virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
    echo -e "${BLUE}Pool '$POOL_NAME' exists in libvirt${NC}"
    
    # Check if pool is in terraform state
    if terraform state list 2>/dev/null | grep -q "libvirt_pool.default"; then
        echo -e "${YELLOW}Pool already in Terraform state${NC}"
        
        # Verify it's the correct pool
        STATE_POOL=$(terraform state show libvirt_pool.default 2>/dev/null | grep "name" | awk '{print $3}' | tr -d '"')
        
        if [ "$STATE_POOL" != "$POOL_NAME" ]; then
            echo -e "${YELLOW}State pool name mismatch. Removing and re-importing...${NC}"
            terraform state rm libvirt_pool.default
            terraform import libvirt_pool.default "$POOL_NAME"
        else
            echo -e "${GREEN}✓ Pool state is correct${NC}"
        fi
    else
        echo -e "${BLUE}Importing pool to Terraform state...${NC}"
        terraform import libvirt_pool.default "$POOL_NAME" || {
            echo -e "${RED}✗ Import failed${NC}"
            exit 1
        }
        echo -e "${GREEN}✓ Pool imported successfully${NC}"
    fi
else
    echo -e "${GREEN}✓ Pool does not exist, Terraform will create it${NC}"
fi

echo ""

# ============================================================================
# STEP 3: Check UEFI/OVMF Support
# ============================================================================
echo -e "${YELLOW}[3/6] Checking UEFI/OVMF support...${NC}"

OVMF_PATHS=(
    "/usr/share/OVMF/OVMF_CODE.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
    "/usr/share/qemu/ovmf-x86_64-code.bin"
)

OVMF_FOUND=false
OVMF_PATH=""

for path in "${OVMF_PATHS[@]}"; do
    if [ -f "$path" ]; then
        OVMF_FOUND=true
        OVMF_PATH="$path"
        echo -e "${GREEN}✓ UEFI firmware found at: $path${NC}"
        break
    fi
done

if [ "$OVMF_FOUND" = false ]; then
    echo -e "${YELLOW}⚠ UEFI firmware not found${NC}"
    echo -e "${YELLOW}  Installing OVMF package...${NC}"
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y ovmf
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y edk2-ovmf
    else
        echo -e "${YELLOW}  Please install OVMF manually or VM will use BIOS${NC}"
    fi
    
    # Check again after installation
    for path in "${OVMF_PATHS[@]}"; do
        if [ -f "$path" ]; then
            OVMF_FOUND=true
            OVMF_PATH="$path"
            echo -e "${GREEN}✓ UEFI firmware installed at: $path${NC}"
            break
        fi
    done
fi

if [ "$OVMF_FOUND" = false ]; then
    echo -e "${YELLOW}⚠ UEFI not available, will use BIOS mode${NC}"
fi

echo ""

# ============================================================================
# STEP 4: Validate Terraform Configuration
# ============================================================================
echo -e "${YELLOW}[4/6] Validating Terraform configuration...${NC}"

# Format terraform files
terraform fmt -recursive

# Initialize if needed
if [ ! -d ".terraform" ]; then
    echo -e "${BLUE}Initializing Terraform...${NC}"
    terraform init
fi

# Validate configuration
if terraform validate; then
    echo -e "${GREEN}✓ Terraform configuration is valid${NC}"
else
    echo -e "${RED}✗ Terraform validation failed${NC}"
    exit 1
fi

echo ""

# ============================================================================
# STEP 5: Plan Terraform Changes
# ============================================================================
echo -e "${YELLOW}[5/6] Planning Terraform changes...${NC}"

terraform plan -out=tfplan

echo ""
echo -e "${BLUE}Review the plan above. Press Enter to continue or Ctrl+C to abort...${NC}"
read -r

echo ""

# ============================================================================
# STEP 6: Apply Terraform Configuration
# ============================================================================
echo -e "${YELLOW}[6/6] Applying Terraform configuration...${NC}"

if terraform apply tfplan; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Deployment Successful! ✓                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Show outputs
    echo -e "${BLUE}Deployment Information:${NC}"
    terraform output
    
    # Cleanup plan file
    rm -f tfplan
    
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. SSH to VM: $(terraform output -raw ssh_connection 2>/dev/null || echo 'Check outputs above')"
    echo "2. Check VM status: virsh list --all"
    echo "3. View VM console: virsh console $(terraform output -raw vm_name 2>/dev/null || echo 'VM_NAME')"
    
else
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Deployment Failed! ✗                          ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo "1. Check error messages above"
    echo "2. Verify libvirt service: sudo systemctl status libvirtd"
    echo "3. Check available resources: virsh nodeinfo"
    echo "4. Review Terraform state: terraform state list"
    echo "5. Check logs: journalctl -u libvirtd -n 50"
    
    rm -f tfplan
    exit 1
fi