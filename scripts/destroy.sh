
#!/bin/bash

# ============================================================================
# Script: destroy.sh
# Purpose: Safely and smoothly destroy Terraform infrastructure
# Project: QuickstackBlueGreenIAAC
# Version: 2.0
# ============================================================================
#
# USAGE:
#   ./scripts/destroy.sh [OPTIONS]
#
# OPTIONS:
#   --force         Skip confirmation prompts
#   --keep-pool     Keep storage pool directory
#   --debug         Enable debug logging
#
# EXAMPLES:
#   ./scripts/destroy.sh                    # Interactive mode
#   ./scripts/destroy.sh --force            # Auto-approve mode
#   ./scripts/destroy.sh --force --debug    # Debug mode
#
# ============================================================================

set -euo pipefail

# ============================================================================
# Color Codes
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/destroy_$(date +%Y%m%d_%H%M%S).log"
POOL_NAME="k3s_infra_pool"
POOL_PATH="/var/lib/libvirt/images/${POOL_NAME}"

# Parse arguments
FORCE_MODE=false
KEEP_POOL=false
DEBUG_MODE=false

for arg in "$@"; do
    case $arg in
        --force) FORCE_MODE=true ;;
        --keep-pool) KEEP_POOL=true ;;
        --debug) DEBUG_MODE=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"

# ============================================================================
# Logging Functions
# ============================================================================
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
    fi
}

# ============================================================================
# Error Handler
# ============================================================================
cleanup_on_error() {
    log_error "Script failed at line $1"
    log_warning "Check log file: $LOG_FILE"
    log_info "You can retry with: ./scripts/destroy.sh --force"
}

trap 'cleanup_on_error $LINENO' ERR

# ============================================================================
# Main Script
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║          Infrastructure Destroy Script v2.0                ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

cd "$PROJECT_DIR" || exit 1

# ============================================================================
# STEP 1: Confirmation
# ============================================================================
if [ "$FORCE_MODE" = false ]; then
    log_warning "This will destroy ALL infrastructure resources!"
    log_warning "This action CANNOT be undone!"
    log ""
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Destroy cancelled by user"
        exit 0
    fi
fi

# ============================================================================
# STEP 2: Pre-conditions Check
# ============================================================================
log_info "[1/10] Running pre-conditions check..."

if ! command -v terraform &> /dev/null; then
    log_error "Terraform not found. Please install Terraform first."
    exit 1
fi

if ! command -v virsh &> /dev/null; then
    log_warning "virsh not found. Some cleanup may be skipped."
fi

if ! command -v kubectl &> /dev/null; then
    log_warning "kubectl not found. Kubernetes cleanup will be skipped."
fi

log_success "Pre-conditions check passed"
log ""

# ============================================================================
# STEP 3: State Lock Check & Unlock
# ============================================================================
log_info "[2/10] Checking for state locks..."

if ls .terraform.tfstate.lock.* 1> /dev/null 2>&1; then
    log_warning "Found state lock files. Attempting to unlock..."
    for lock_file in .terraform.tfstate.lock.*; do
        LOCK_ID=$(echo "$lock_file" | cut -d. -f4)
        log_info "Unlocking: $LOCK_ID"
        terraform force-unlock -force "$LOCK_ID" 2>&1 | tee -a "$LOG_FILE" || true
    done
    log_success "State unlocked"
else
    log_success "No state locks found"
fi

log ""

# ============================================================================
# STEP 4: Kubernetes Cleanup (if applicable)
# ============================================================================
log_info "[3/10] Checking for Kubernetes resources..."

if [ -f "kubeconfig" ]; then
    export KUBECONFIG="$(pwd)/kubeconfig"
    log_info "Using local kubeconfig for cleanup..."
    
    # Check if cluster is accessible
    # if kubectl cluster-info &> /dev/null; then
    #     log_info "Kubernetes cluster is accessible"
        
    #     # Clean stuck namespaces
    #     log_info "Checking for stuck namespaces..."
    #     STUCK_NS=$(kubectl get namespaces 2>/dev/null | grep Terminating | awk '{print $1}' || true)
    #     if [ -n "$STUCK_NS" ]; then
    #         log_warning "Found stuck namespaces: $STUCK_NS"
    #         for ns in $STUCK_NS; do
    #             log_info "Removing finalizers from namespace: $ns"
    #             kubectl patch namespace "$ns" -p '{"spec":{"finalizers":null}}' --type=merge 2>&1 | tee -a "$LOG_FILE" || true
    #         done
    #     fi
        
    #     # Clean PVCs
    #     log_info "Cleaning up PVCs..."
    #     kubectl delete pvc --all --all-namespaces --timeout=30s 2>&1 | tee -a "$LOG_FILE" || true
        
    #     log_success "Kubernetes cleanup completed"
    # else
    #     log_warning "Kubernetes cluster not accessible"
    # fi
else
    log_info "No kubeconfig found, skipping Kubernetes cleanup"
fi

log ""

# ============================================================================
# STEP 5: Stop Running VMs
# ============================================================================
log_info "[4/10] Stopping running VMs..."

if command -v virsh &> /dev/null; then
    # Get list of running VMs that match our pattern
    RUNNING_VMS=$(sudo virsh list --name 2>/dev/null | grep -E "k3s|master|worker" || true)
    
    if [ -n "$RUNNING_VMS" ]; then
        log_warning "Found running VMs:"
        echo "$RUNNING_VMS" | tee -a "$LOG_FILE"
        
        for vm in $RUNNING_VMS; do
            log_info "Destroying VM: $vm"
            sudo virsh destroy "$vm" 2>&1 | tee -a "$LOG_FILE" || true
        done
        
        log_success "VMs stopped"
    else
        log_success "No running VMs found"
    fi
else
    log_warning "virsh not available, skipping VM cleanup"
fi

log ""

# ============================================================================
# STEP 6: Terraform Destroy
# ============================================================================
log_info "[5/10] Running Terraform destroy..."

# Enable debug logging if requested
if [ "$DEBUG_MODE" = true ]; then
    export TF_LOG=DEBUG
    export TF_LOG_PATH="$LOG_DIR/terraform-destroy-debug.log"
    log_debug "Debug logging enabled: $TF_LOG_PATH"
fi

# Run terraform destroy
DESTROY_ARGS="-compact-warnings"
if [ "$FORCE_MODE" = true ]; then
    DESTROY_ARGS="$DESTROY_ARGS -auto-approve"
fi

if terraform destroy $DESTROY_ARGS 2>&1 | tee -a "$LOG_FILE"; then
    log_success "Terraform destroy completed successfully"
else
    DESTROY_EXIT_CODE=$?
    log_error "Terraform destroy failed with exit code: $DESTROY_EXIT_CODE"
    
    # Continue with manual cleanup
    log_warning "Continuing with manual cleanup..."
fi

log ""

# ============================================================================
# STEP 7: Manual Pool Cleanup
# ============================================================================
log_info "[6/10] Cleaning up storage pool..."

if command -v virsh &> /dev/null; then
    # Check if pool exists
    if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
        log_info "Found pool: $POOL_NAME"
        
        # Destroy pool (stop it)
        log_info "Stopping pool..."
        sudo virsh pool-destroy "$POOL_NAME" 2>&1 | tee -a "$LOG_FILE" || true
        
        # Delete all volumes in the pool
        log_info "Deleting volumes in pool..."
        VOLUMES=$(sudo virsh vol-list "$POOL_NAME" 2>/dev/null | tail -n +3 | awk '{print $1}' || true)
        if [ -n "$VOLUMES" ]; then
            for vol in $VOLUMES; do
                log_info "Deleting volume: $vol"
                sudo virsh vol-delete "$vol" --pool "$POOL_NAME" 2>&1 | tee -a "$LOG_FILE" || true
            done
        fi
        
        # Undefine pool
        log_info "Undefining pool..."
        sudo virsh pool-undefine "$POOL_NAME" 2>&1 | tee -a "$LOG_FILE" || true
        
        # Remove pool directory if not keeping
        if [ "$KEEP_POOL" = false ] && [ -d "$POOL_PATH" ]; then
            log_info "Removing pool directory: $POOL_PATH"
            
            # Check if directory is empty or has leftover files
            if [ -n "$(ls -A "$POOL_PATH" 2>/dev/null)" ]; then
                log_warning "Pool directory not empty, forcing removal..."
                sudo rm -rf "$POOL_PATH" 2>&1 | tee -a "$LOG_FILE" || {
                    log_error "Failed to remove pool directory"
                    log_info "You may need to manually remove: sudo rm -rf $POOL_PATH"
                }
            else
                sudo rmdir "$POOL_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            fi
        fi
        
        log_success "Storage pool cleaned up"
    else
        log_success "No storage pool found"
    fi
else
    log_warning "virsh not available, skipping pool cleanup"
fi

log ""

# ============================================================================
# STEP 8: Clean Undefined VMs
# ============================================================================
log_info "[7/10] Cleaning up undefined VMs..."

if command -v virsh &> /dev/null; then
    # Get list of all defined VMs
    ALL_VMS=$(sudo virsh list --all --name 2>/dev/null | grep -E "k3s|master|worker" || true)
    
    if [ -n "$ALL_VMS" ]; then
        log_warning "Found VMs to clean:"
        echo "$ALL_VMS" | tee -a "$LOG_FILE"
        
        for vm in $ALL_VMS; do
            log_info "Undefining VM: $vm"
            sudo virsh undefine "$vm" --remove-all-storage 2>&1 | tee -a "$LOG_FILE" || true
        done
        
        log_success "VMs cleaned up"
    else
        log_success "No VMs found to clean"
    fi
else
    log_warning "virsh not available, skipping VM cleanup"
fi

log ""

# ============================================================================
# STEP 9: Clean Terraform Files
# ============================================================================
log_info "[8/10] Cleaning up Terraform files..."

# Remove state files
if [ -f "terraform.tfstate" ]; then
    log_info "Backing up terraform.tfstate..."
    cp terraform.tfstate "$LOG_DIR/terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)"
    rm -f terraform.tfstate
    log_success "State file backed up and removed"
fi

if [ -f "terraform.tfstate.backup" ]; then
    log_info "Removing terraform.tfstate.backup..."
    rm -f terraform.tfstate.backup
fi

# Remove lock files
if ls .terraform.tfstate.lock.* 1> /dev/null 2>&1; then
    log_info "Removing state lock files..."
    rm -f .terraform.tfstate.lock.*
fi

# Remove kubeconfig
if [ -f "kubeconfig" ]; then
    log_info "Removing kubeconfig..."
    rm -f kubeconfig
fi

# Clean .terraform directory (optional)
if [ -d ".terraform" ]; then
    log_info "Cleaning .terraform directory..."
    rm -rf .terraform/providers
    log_success ".terraform/providers removed"
fi

log_success "Terraform files cleaned up"
log ""

# ============================================================================
# STEP 10: Clean Temporary Files
# ============================================================================
log_info "[9/10] Cleaning up temporary files..."

# Remove SSH keys if they exist
if [ -f "id_rsa" ]; then
    log_info "Removing SSH private key..."
    rm -f id_rsa
fi

if [ -f "id_rsa.pub" ]; then
    log_info "Removing SSH public key..."
    rm -f id_rsa.pub
fi

# Remove any backup files
if ls *.backup 1> /dev/null 2>&1; then
    log_info "Removing backup files..."
    rm -f *.backup
fi

# Remove cloud-init files if they exist
if [ -d "cloud-init" ]; then
    log_info "Removing cloud-init directory..."
    rm -rf cloud-init
fi

log_success "Temporary files cleaned up"
log ""

# ============================================================================
# STEP 11: Verification
# ============================================================================
log_info "[10/10] Verifying cleanup..."

CLEANUP_ISSUES=0

# Check for remaining VMs
if command -v virsh &> /dev/null; then
    REMAINING_VMS=$(sudo virsh list --all --name 2>/dev/null | grep -E "k3s|master|worker" || true)
    if [ -n "$REMAINING_VMS" ]; then
        log_warning "Some VMs still exist:"
        echo "$REMAINING_VMS" | tee -a "$LOG_FILE"
        CLEANUP_ISSUES=$((CLEANUP_ISSUES + 1))
    else
        log_success "✓ No VMs remaining"
    fi
    
    # Check for remaining pools
    if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
        log_warning "Storage pool still exists: $POOL_NAME"
        CLEANUP_ISSUES=$((CLEANUP_ISSUES + 1))
    else
        log_success "✓ Storage pool removed"
    fi
fi

# Check for remaining Terraform resources
if [ -f "terraform.tfstate" ]; then
    REMAINING_RESOURCES=$(terraform state list 2>/dev/null | wc -l || echo "0")
    if [ "$REMAINING_RESOURCES" -gt 0 ]; then
        log_warning "Some Terraform resources still in state: $REMAINING_RESOURCES"
        terraform state list 2>/dev/null | tee -a "$LOG_FILE"
        CLEANUP_ISSUES=$((CLEANUP_ISSUES + 1))
    else
        log_success "✓ No Terraform resources in state"
    fi
else
    log_success "✓ No state file exists"
fi

# Check for pool directory
if [ -d "$POOL_PATH" ]; then
    if [ "$KEEP_POOL" = true ]; then
        log_info "✓ Pool directory kept as requested: $POOL_PATH"
    else
        log_warning "Pool directory still exists: $POOL_PATH"
        log_info "You can manually remove it with: sudo rm -rf $POOL_PATH"
        CLEANUP_ISSUES=$((CLEANUP_ISSUES + 1))
    fi
else
    log_success "✓ Pool directory removed"
fi

log ""

# ============================================================================
# Summary
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║                  Destroy Summary                           ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

if [ $CLEANUP_ISSUES -eq 0 ]; then
    log_success "✓ All resources destroyed successfully!"
    log_success "✓ Infrastructure completely cleaned up"
    log ""
    log_info "Summary:"
    log_info "  - VMs: Removed"
    log_info "  - Storage Pool: Removed"
    log_info "  - Terraform State: Cleaned"
    log_info "  - Temporary Files: Cleaned"
else
    log_warning "⚠ Cleanup completed with $CLEANUP_ISSUES issue(s)"
    log ""
    log_info "Manual cleanup may be required for:"
    
    if command -v virsh &> /dev/null; then
        REMAINING_VMS=$(sudo virsh list --all --name 2>/dev/null | grep -E "k3s|master|worker" || true)
        if [ -n "$REMAINING_VMS" ]; then
            log_info "  - VMs: $REMAINING_VMS"
            log_info "    Command: sudo virsh undefine <vm-name> --remove-all-storage"
        fi
        
        if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
            log_info "  - Storage Pool: $POOL_NAME"
            log_info "    Commands:"
            log_info "      sudo virsh pool-destroy $POOL_NAME"
            log_info "      sudo virsh pool-undefine $POOL_NAME"
        fi
    fi
    
    if [ -d "$POOL_PATH" ] && [ "$KEEP_POOL" = false ]; then
        log_info "  - Pool Directory: $POOL_PATH"
        log_info "    Command: sudo rm -rf $POOL_PATH"
    fi
fi

log ""
log_info "Log file saved to: $LOG_FILE"
log ""

# ============================================================================
# Post-Destroy Instructions
# ============================================================================
log_info "Next Steps:"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "To redeploy infrastructure:"
log_info "  1. Review and update variables: vi example.tfvars"
log_info "  2. Initialize Terraform: terraform init"
log_info "  3. Plan deployment: terraform plan -var-file=example.tfvars"
log_info "  4. Apply configuration: terraform apply -var-file=example.tfvars"
log_info ""
log_info "To verify complete cleanup:"
log_info "  sudo virsh list --all"
log_info "  sudo virsh pool-list --all"
log_info "  ls -la $POOL_PATH"
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""

exit 0