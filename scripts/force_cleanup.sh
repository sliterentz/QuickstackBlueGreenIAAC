
#!/bin/bash

# ============================================================================
# Script: force_cleanup.sh
# Purpose: Force cleanup when normal destroy fails
# Usage: ./scripts/force_cleanup.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

POOL_NAME="k3s_infra_pool"
POOL_PATH="/var/lib/libvirt/images/${POOL_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_warning "╔════════════════════════════════════════════════════════════╗"
log_warning "║              FORCE CLEANUP - USE WITH CAUTION              ║"
log_warning "╚════════════════════════════════════════════════════════════╝"
log ""
log_warning "This will forcefully remove ALL resources including:"
log_warning "  - All VMs (running and stopped)"
log_warning "  - Storage pools and volumes"
log_warning "  - Pool directories"
log_warning "  - Terraform state"
log_warning "  - All temporary files"
log ""

read -p "Are you absolutely sure? Type 'FORCE DELETE' to continue: " -r
if [[ ! $REPLY == "FORCE DELETE" ]]; then
    log_info "Cancelled by user"
    exit 0
fi

log ""
log_info "Starting force cleanup..."
log ""

cd "$PROJECT_DIR" || exit 1

# ============================================================================
# STEP 1: Force stop and remove all VMs
# ============================================================================
log_info "[1/6] Force removing VMs..."

if command -v virsh &> /dev/null; then
    ALL_VMS=$(sudo virsh list --all --name 2>/dev/null || true)
    VM_COUNT=0
    
    for vm in $ALL_VMS; do
        if [[ $vm =~ k3s|master|worker ]] && [ -n "$vm" ]; then
            log_info "Processing VM: $vm"
            
            # Force destroy if running
            if sudo virsh list --name 2>/dev/null | grep -q "^${vm}$"; then
                log_info "  Destroying running VM: $vm"
                sudo virsh destroy "$vm" 2>/dev/null || true
            fi
            
            # Get all storage volumes for this VM
            log_info "  Finding storage volumes for: $vm"
            VM_DISKS=$(sudo virsh domblklist "$vm" 2>/dev/null | grep -v "^-" | grep -v "^Target" | awk '{print $2}' || true)
            
            # Undefine with all storage
            log_info "  Undefining VM: $vm"
            sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
            
            # Manual disk cleanup if undefine failed
            for disk in $VM_DISKS; do
                if [ -f "$disk" ]; then
                    log_info "  Manually removing disk: $disk"
                    sudo rm -f "$disk" 2>/dev/null || true
                fi
            done
            
            VM_COUNT=$((VM_COUNT + 1))
        fi
    done
    
    if [ $VM_COUNT -gt 0 ]; then
        log_success "Removed $VM_COUNT VM(s)"
    else
        log_info "No VMs found to remove"
    fi
else
    log_warning "virsh not available, skipping VM cleanup"
fi

log ""

# ============================================================================
# STEP 2: Force remove storage pool
# ============================================================================
log_info "[2/6] Force removing storage pool..."

if command -v virsh &> /dev/null; then
    if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
        log_info "Found pool: $POOL_NAME"
        
        # Get pool state
        POOL_STATE=$(sudo virsh pool-info "$POOL_NAME" 2>/dev/null | grep "State:" | awk '{print $2}' || echo "unknown")
        log_info "Pool state: $POOL_STATE"
        
        # Delete all volumes first
        log_info "Deleting all volumes in pool..."
        VOLUMES=$(sudo virsh vol-list "$POOL_NAME" 2>/dev/null | tail -n +3 | awk '{print $1}' || true)
        VOL_COUNT=0
        
        for vol in $VOLUMES; do
            if [ -n "$vol" ]; then
                log_info "  Deleting volume: $vol"
                sudo virsh vol-delete "$vol" --pool "$POOL_NAME" 2>/dev/null || true
                VOL_COUNT=$((VOL_COUNT + 1))
            fi
        done
        
        if [ $VOL_COUNT -gt 0 ]; then
            log_success "Deleted $VOL_COUNT volume(s)"
        fi
        
        # Destroy pool if active
        if [ "$POOL_STATE" == "running" ]; then
            log_info "Destroying active pool..."
            sudo virsh pool-destroy "$POOL_NAME" 2>/dev/null || true
        fi
        
        # Undefine pool
        log_info "Undefining pool..."
        sudo virsh pool-undefine "$POOL_NAME" 2>/dev/null || true
        
        log_success "Storage pool removed"
    else
        log_info "No storage pool found"
    fi
else
    log_warning "virsh not available, skipping pool cleanup"
fi

log ""

# ============================================================================
# STEP 3: Force remove pool directory
# ============================================================================
log_info "[3/6] Force removing pool directory..."

if [ -d "$POOL_PATH" ]; then
    log_info "Found pool directory: $POOL_PATH"
    
    # Check directory size
    DIR_SIZE=$(sudo du -sh "$POOL_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
    log_info "Directory size: $DIR_SIZE"
    
    # List contents
    log_info "Directory contents:"
    sudo ls -lh "$POOL_PATH" 2>/dev/null | tee -a /dev/stderr || true
    
    # Force remove
    log_warning "Forcing removal of pool directory..."
    if sudo rm -rf "$POOL_PATH" 2>/dev/null; then
        log_success "Pool directory removed"
    else
        log_error "Failed to remove pool directory"
        log_info "Trying alternative method..."
        
        # Try to remove files first
        sudo find "$POOL_PATH" -type f -delete 2>/dev/null || true
        sudo find "$POOL_PATH" -type d -delete 2>/dev/null || true
        
        if [ ! -d "$POOL_PATH" ]; then
            log_success "Pool directory removed (alternative method)"
        else
            log_error "Could not remove pool directory"
            log_info "Manual removal required: sudo rm -rf $POOL_PATH"
        fi
    fi
else
    log_info "Pool directory does not exist"
fi

log ""

# ============================================================================
# STEP 4: Clean Terraform state
# ============================================================================
log_info "[4/6] Cleaning Terraform state..."

# Remove all state files
STATE_FILES=(
    "terraform.tfstate"
    "terraform.tfstate.backup"
    ".terraform.tfstate.lock.*"
)

for pattern in "${STATE_FILES[@]}"; do
    if ls $pattern 1> /dev/null 2>&1; then
        log_info "Removing: $pattern"
        rm -f $pattern
    fi
done

# Clean .terraform directory
if [ -d ".terraform" ]; then
    log_info "Removing .terraform directory..."
    rm -rf .terraform
fi

log_success "Terraform state cleaned"
log ""

# ============================================================================
# STEP 5: Clean all temporary files
# ============================================================================
log_info "[5/6] Cleaning temporary files..."

TEMP_FILES=(
    "kubeconfig"
    "id_rsa"
    "id_rsa.pub"
    "*.backup"
    "*.log"
)

TEMP_DIRS=(
    "cloud-init"
    "logs"
)

# Remove files
for pattern in "${TEMP_FILES[@]}"; do
    if ls $pattern 1> /dev/null 2>&1; then
        log_info "Removing files: $pattern"
        rm -f $pattern
    fi
done

# Remove directories
for dir in "${TEMP_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        log_info "Removing directory: $dir"
        rm -rf "$dir"
    fi
done

log_success "Temporary files cleaned"
log ""

# ============================================================================
# STEP 6: Final verification
# ============================================================================
log_info "[6/6] Final verification..."

ISSUES=0

# Check VMs
if command -v virsh &> /dev/null; then
    REMAINING_VMS=$(sudo virsh list --all --name 2>/dev/null | grep -E "k3s|master|worker" || true)
    if [ -n "$REMAINING_VMS" ]; then
        log_error "Some VMs still exist:"
        echo "$REMAINING_VMS"
        ISSUES=$((ISSUES + 1))
    else
        log_success "✓ No VMs remaining"
    fi
    
    # Check pools
    if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
        log_error "Storage pool still exists"
        ISSUES=$((ISSUES + 1))
    else
        log_success "✓ Storage pool removed"
    fi
fi

# Check pool directory
if [ -d "$POOL_PATH" ]; then
    log_error "Pool directory still exists: $POOL_PATH"
    ISSUES=$((ISSUES + 1))
else
    log_success "✓ Pool directory removed"
fi

# Check state files
if [ -f "terraform.tfstate" ]; then
    log_error "Terraform state still exists"
    ISSUES=$((ISSUES + 1))
else
    log_success "✓ Terraform state removed"
fi

log ""

# ============================================================================
# Summary
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║              Force Cleanup Summary                         ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

if [ $ISSUES -eq 0 ]; then
    log_success "✓ Force cleanup completed successfully!"
    log_success "✓ All resources have been removed"
else
    log_warning "⚠ Force cleanup completed with $ISSUES issue(s)"
    log_warning "Manual intervention may be required"
fi

log ""
log_info "If issues persist, try these manual commands:"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "1. List all VMs:"
log_info "   sudo virsh list --all"
log_info ""
log_info "2. Force remove specific VM:"
log_info "   sudo virsh destroy <vm-name>"
log_info "   sudo virsh undefine <vm-name> --remove-all-storage"
log_info ""
log_info "3. List all pools:"
log_info "   sudo virsh pool-list --all"
log_info ""
log_info "4. Force remove pool:"
log_info "   sudo virsh pool-destroy $POOL_NAME"
log_info "   sudo virsh pool-undefine $POOL_NAME"
log_info ""
log_info "5. Force remove pool directory:"
log_info "   sudo rm -rf $POOL_PATH"
log_info ""
log_info "6. Check for orphaned processes:"
log_info "   ps aux | grep -E 'qemu|libvirt|kvm'"
log_info ""
log_info "7. Restart libvirt service:"
log_info "   sudo systemctl restart libvirtd"
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""

exit 0