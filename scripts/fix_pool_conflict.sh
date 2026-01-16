
#!/bin/bash

set -euo pipefail

# ============================================================================
# Color Codes
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/pool_fix_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$LOG_DIR"

# ============================================================================
# Logging Functions
# ============================================================================
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}✗ $1${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}⚠ $1${NC}" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}ℹ $1${NC}" | tee -a "$LOG_FILE"
}

# ============================================================================
# Error Handler
# ============================================================================
cleanup_on_error() {
    log_error "Script failed at line $1"
    log_warning "Check log file: $LOG_FILE"
    
    if [ -f "$PROJECT_DIR/.terraform_backup_state" ]; then
        log_info "Restoring backup state..."
        cp "$PROJECT_DIR/.terraform_backup_state" "$PROJECT_DIR/terraform.tfstate"
        rm "$PROJECT_DIR/.terraform_backup_state"
        log_success "State restored from backup"
    fi
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# ============================================================================
# Main Script
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║         Storage Pool Conflict Fix Script v2.2             ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

# Change to project directory
cd "$PROJECT_DIR" || exit 1

# ============================================================================
# STEP 1: Pre-flight Checks
# ============================================================================
log_info "[1/9] Running pre-flight checks..."

# Check if we're in terraform directory
if [ ! -f "main.tf" ]; then
    log_error "main.tf not found. Please run from terraform directory"
    exit 1
fi

# Check if virsh is available
if ! command -v virsh &> /dev/null; then
    log_error "virsh command not found. Is libvirt installed?"
    exit 1
fi

# Check if terraform is available
if ! command -v terraform &> /dev/null; then
    log_error "terraform command not found"
    exit 1
fi

# Check libvirt connection
if ! sudo virsh list &> /dev/null; then
    log_error "Cannot connect to libvirt. Is libvirtd running?"
    log_info "Try: sudo systemctl start libvirtd"
    exit 1
fi

log_success "Pre-flight checks passed"
log ""

# ============================================================================
# STEP 2: Fix Provider Configuration
# ============================================================================
log_info "[2/9] Checking provider configuration..."

# Check if provider is correctly configured
if grep -q 'source.*=.*"hashicorp/libvirt"' main.tf; then
    log_warning "Found incorrect provider source (hashicorp/libvirt)"
    log_info "Fixing provider configuration..."
    
    # Backup main.tf
    cp main.tf main.tf.backup
    
    # Fix provider source
    sed -i 's|source.*=.*"hashicorp/libvirt"|source  = "dmacvicar/libvirt"|g' main.tf
    sed -i 's|source.*=.*"registry.terraform.io/hashicorp/libvirt"|source  = "dmacvicar/libvirt"|g' main.tf
    
    log_success "Provider configuration fixed"
elif grep -q 'source.*=.*"dmacvicar/libvirt"' main.tf; then
    log_success "Provider configuration is correct"
else
    log_warning "Provider configuration not found in main.tf"
fi

log ""

# ============================================================================
# STEP 3: Clean Terraform Cache
# ============================================================================
log_info "[3/9] Cleaning Terraform cache..."

# Remove lock file
if [ -f ".terraform.lock.hcl" ]; then
    log_info "Removing old lock file..."
    rm -f .terraform.lock.hcl
fi

# Remove .terraform directory
if [ -d ".terraform" ]; then
    log_info "Removing .terraform directory..."
    rm -rf .terraform
fi

# Remove cached plugins
if [ -d "$HOME/.terraform.d/plugin-cache" ]; then
    log_info "Cleaning plugin cache..."
    rm -rf "$HOME/.terraform.d/plugin-cache"
fi

log_success "Terraform cache cleaned"
log ""

# ============================================================================
# STEP 4: Initialize Terraform with Correct Provider
# ============================================================================
log_info "[4/9] Initializing Terraform with correct provider..."

# Initialize with upgrade
if terraform init -upgrade 2>&1 | tee -a "$LOG_FILE"; then
    log_success "Terraform initialized successfully"
else
    log_error "Terraform init failed"
    exit 1
fi

log ""

# ============================================================================
# STEP 5: Backup Current State
# ============================================================================
log_info "[5/9] Backing up current state..."

if [ -f "terraform.tfstate" ]; then
    cp terraform.tfstate .terraform_backup_state
    log_success "State backed up"
else
    log_warning "No state file found (fresh deployment)"
fi

log ""

# ============================================================================
# STEP 6: Check Pool in Terraform State FIRST
# ============================================================================
log_info "[6/9] Checking pool in Terraform state..."

POOL_IN_STATE=false
STATE_POOL_ID=""

if terraform state list 2>/dev/null | grep -q "libvirt_pool.default"; then
    POOL_IN_STATE=true
    log_warning "Pool found in Terraform state"
    
    # Get state info including ID
    STATE_POOL_NAME=$(terraform state show libvirt_pool.default 2>/dev/null | grep "name" | head -1 | awk '{print $3}' | tr -d '"' || echo "unknown")
    STATE_POOL_ID=$(terraform state show libvirt_pool.default 2>/dev/null | grep "^id" | head -1 | awk '{print $3}' | tr -d '"' || echo "unknown")
    
    log_info "State pool name: $STATE_POOL_NAME"
    log_info "State pool ID: $STATE_POOL_ID"
else
    log_info "Pool not found in Terraform state"
fi

log ""

# ============================================================================
# STEP 7: Check Pool in Libvirt
# ============================================================================
log_info "[7/9] Checking pool in libvirt..."

POOL_NAME="k3s_infra_pool"
POOL_EXISTS=false
POOL_UUID=""

if sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME"; then
    POOL_EXISTS=true
    log_info "Pool '$POOL_NAME' exists in libvirt"
    
    # Get pool UUID
    POOL_UUID=$(sudo virsh pool-uuid "$POOL_NAME" 2>/dev/null || echo "")
    
    if [ -z "$POOL_UUID" ]; then
        log_error "Failed to get pool UUID"
    else
        log_info "Pool UUID: $POOL_UUID"
    fi
    
    # Get pool info
    POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" 2>/dev/null | grep -oP '(?<=<path>).*(?=</path>)' || echo "unknown")
    POOL_STATE=$(sudo virsh pool-list --all 2>/dev/null | grep "$POOL_NAME" | awk '{print $2}' || echo "unknown")
    
    log_info "Pool path: $POOL_PATH"
    log_info "Pool state: $POOL_STATE"
    
    # Ensure pool is active
    if [ "$POOL_STATE" != "active" ]; then
        log_info "Starting pool..."
        sudo virsh pool-start "$POOL_NAME" 2>/dev/null || log_warning "Could not start pool"
    fi
    
    # Refresh pool
    log_info "Refreshing pool..."
    sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || log_warning "Could not refresh pool"
    
else
    log_success "Pool does not exist in libvirt (will be created)"
fi

log ""

# ============================================================================
# STEP 8: Reconcile State - IMPROVED LOGIC
# ============================================================================
log_info "[8/9] Reconciling state..."

# Case 1: Pool in state AND in libvirt
if [ "$POOL_IN_STATE" = true ] && [ "$POOL_EXISTS" = true ]; then
    log_info "Pool exists in both state and libvirt"
    
    # Check if IDs match
    if [ "$STATE_POOL_ID" = "$POOL_UUID" ]; then
        log_success "Pool IDs match - state is synchronized"
    else
        log_warning "Pool ID mismatch detected"
        log_info "State ID: $STATE_POOL_ID"
        log_info "Libvirt UUID: $POOL_UUID"
        log_info "Refreshing state..."
        
        # Remove from state and re-import with correct UUID
        terraform state rm libvirt_pool.default 2>&1 | tee -a "$LOG_FILE"
        
        if [ -n "$POOL_UUID" ]; then
            log_info "Re-importing with correct UUID..."
            if terraform import libvirt_pool.default "$POOL_UUID" 2>&1 | tee -a "$LOG_FILE"; then
                log_success "Pool re-imported successfully"
            else
                log_error "Failed to re-import pool"
                exit 1
            fi
        fi
    fi

# Case 2: Pool in state but NOT in libvirt
elif [ "$POOL_IN_STATE" = true ] && [ "$POOL_EXISTS" = false ]; then
    log_warning "Pool in state but not in libvirt (orphaned state)"
    log_info "Removing orphaned resource from state..."
    terraform state rm libvirt_pool.default 2>&1 | tee -a "$LOG_FILE"
    log_success "Orphaned state cleaned - Terraform will create new pool"

# Case 3: Pool NOT in state but EXISTS in libvirt
elif [ "$POOL_IN_STATE" = false ] && [ "$POOL_EXISTS" = true ]; then
    log_info "Pool exists in libvirt but not in state"
    
    if [ -z "$POOL_UUID" ]; then
        log_error "Cannot import: Pool UUID is empty"
        log_info "Removing existing pool for clean recreation..."
        
        sudo virsh pool-destroy "$POOL_NAME" 2>/dev/null || true
        sudo virsh pool-undefine "$POOL_NAME" 2>/dev/null || true
        
        log_success "Pool removed - Terraform will create new pool"
    else
        log_info "Importing existing pool with UUID: $POOL_UUID"
        
        if terraform import libvirt_pool.default "$POOL_UUID" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Pool imported successfully"
        else
            log_error "Import failed"
            log_info "Attempting cleanup and recreation..."
            
            sudo virsh pool-destroy "$POOL_NAME" 2>/dev/null || true
            sudo virsh pool-undefine "$POOL_NAME" 2>/dev/null || true
            
            log_success "Pool removed - Terraform will create new pool"
        fi
    fi

# Case 4: Pool NOT in state and NOT in libvirt
else
    log_success "Clean state - no pool exists (Terraform will create)"
fi

log ""

# ============================================================================
# STEP 9: Verify Configuration
# ============================================================================
log_info "[9/9] Verifying Terraform configuration..."

if terraform validate; then
    log_success "Configuration is valid"
else
    log_error "Configuration validation failed"
    exit 1
fi

log ""

# ============================================================================
# Cleanup and Summary
# ============================================================================
log_success "╔════════════════════════════════════════════════════════════╗"
log_success "║              Pool Conflict Fixed Successfully!             ║"
log_success "╚════════════════════════════════════════════════════════════╝"
log ""

# Remove backup if successful
if [ -f ".terraform_backup_state" ]; then
    rm .terraform_backup_state
fi

# Final state check
FINAL_POOL_IN_STATE=$(terraform state list 2>/dev/null | grep -q 'libvirt_pool.default' && echo 'true' || echo 'false')
FINAL_POOL_EXISTS=$(sudo virsh pool-list --all 2>/dev/null | grep -q "$POOL_NAME" && echo 'true' || echo 'false')

log_info "Final Summary:"
log_info "  Pool Name: $POOL_NAME"
log_info "  Pool UUID: ${POOL_UUID:-N/A}"
log_info "  Exists in Libvirt: $FINAL_POOL_EXISTS"
log_info "  In Terraform State: $FINAL_POOL_IN_STATE"
log_info "  Terraform Version: $(terraform version | head -1)"
log_info "  Provider Version: $(terraform version | grep -i libvirt || echo 'dmacvicar/libvirt ~> 0.7.6')"
log ""

if [ "$FINAL_POOL_EXISTS" = true ] && [ "$FINAL_POOL_IN_STATE" = "true" ]; then
    log_success "✓ Pool is properly synced"
    log_info "State: SYNCHRONIZED"
elif [ "$FINAL_POOL_EXISTS" = false ] && [ "$FINAL_POOL_IN_STATE" = "false" ]; then
    log_success "✓ Ready for fresh deployment"
    log_info "State: CLEAN"
else
    log_warning "⚠ Inconsistent state detected"
    log_info "State: NEEDS_ATTENTION"
fi

log ""
log_success "Next steps:"
log_success "  1. Run: terraform plan"
log_success "  2. Review the plan carefully"
log_success "  3. Run: terraform apply --auto-approve"
log ""

log_info "Log saved to: $LOG_FILE"

# ============================================================================
# Additional Diagnostics
# ============================================================================
log ""
log_info "Additional Diagnostics:"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check libvirt pools
log_info "Libvirt Pools:"
sudo virsh pool-list --all 2>/dev/null | tee -a "$LOG_FILE"

# Show pool details if exists
if [ "$FINAL_POOL_EXISTS" = true ]; then
    log_info ""
    log_info "Pool Details:"
    sudo virsh pool-info "$POOL_NAME" 2>/dev/null | tee -a "$LOG_FILE"
    
    log_info ""
    log_info "Pool Volumes:"
    sudo virsh vol-list "$POOL_NAME" 2>/dev/null | tee -a "$LOG_FILE" || echo "No volumes or pool inactive"
fi

# Check terraform state resources
log_info ""
log_info "Terraform State Resources:"
terraform state list 2>/dev/null | tee -a "$LOG_FILE" || echo "No resources in state"

# Show detailed pool state if in terraform
if [ "$FINAL_POOL_IN_STATE" = "true" ]; then
    log_info ""
    log_info "Terraform Pool State Details:"
    terraform state show libvirt_pool.default 2>/dev/null | head -20 | tee -a "$LOG_FILE"
fi

# Check provider versions
log_info ""
log_info "Provider Versions:"
terraform providers 2>/dev/null | tee -a "$LOG_FILE"

# Check provider lock
log_info ""
log_info "Provider Lock Status:"
if [ -f ".terraform.lock.hcl" ]; then
    grep -A 5 "provider.*libvirt" .terraform.lock.hcl | tee -a "$LOG_FILE"
else
    echo "No lock file found" | tee -a "$LOG_FILE"
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""

# ============================================================================
# Troubleshooting Guide
# ============================================================================
log_info "Troubleshooting Guide:"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "If you encounter issues, try these commands:"
log_info ""
log_info "1. Check pool status manually:"
log_info "   sudo virsh pool-list --all"
log_info "   sudo virsh pool-info $POOL_NAME"
log_info ""
log_info "2. Check Terraform state:"
log_info "   terraform state list"
log_info "   terraform state show libvirt_pool.default"
log_info ""
log_info "3. Manual cleanup (if needed):"
log_info "   # Remove from libvirt:"
log_info "   sudo virsh pool-destroy $POOL_NAME"
log_info "   sudo virsh pool-undefine $POOL_NAME"
log_info ""
log_info "   # Remove from Terraform state:"
log_info "   terraform state rm libvirt_pool.default"
log_info ""
log_info "4. Force recreation:"
log_info "   terraform apply -replace=libvirt_pool.default"
log_info ""
log_info "5. Check logs:"
log_info "   cat $LOG_FILE"
log_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""

exit 0