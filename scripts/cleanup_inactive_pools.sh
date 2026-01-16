
#!/bin/bash

# ============================================================================
# Script: cleanup_inactive_pools.sh
# Purpose: Clean up inactive/orphaned libvirt storage pools
# Usage: ./scripts/cleanup_inactive_pools.sh [OPTIONS]
# ============================================================================

set -e

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
LOG_FILE="$LOG_DIR/cleanup_pools_$(date +%Y%m%d_%H%M%S).log"
POOL_NAME="k3s_infra_pool"

# Parse arguments
FORCE_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --force) FORCE_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --force     Skip confirmation prompts"
            echo "  --dry-run   Show what would be done without doing it"
            echo "  --help      Show this help message"
            exit 0
            ;;
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

# ============================================================================
# Main Script
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║         Cleanup Inactive Storage Pools Script              ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No changes will be made"
    log ""
fi

# ============================================================================
# Check Prerequisites
# ============================================================================
log_info "Checking prerequisites..."

if ! command -v virsh &> /dev/null; then
    log_error "virsh not found. Please install libvirt-clients."
    exit 1
fi

log_success "Prerequisites check passed"
log ""

# ============================================================================
# List All Pools
# ============================================================================
log_info "Scanning for storage pools..."

ALL_POOLS=$(sudo virsh pool-list --all 2>/dev/null | tail -n +3 | awk '{print $1}' | grep -v "^$" || true)

if [ -z "$ALL_POOLS" ]; then
    log_success "No storage pools found"
    exit 0
fi

log_info "Found storage pools:"
echo "$ALL_POOLS" | while read -r pool; do
    STATE=$(sudo virsh pool-info "$pool" 2>/dev/null | grep "State:" | awk '{print $2}' || echo "unknown")
    AUTOSTART=$(sudo virsh pool-info "$pool" 2>/dev/null | grep "Autostart:" | awk '{print $2}' || echo "unknown")
    PERSISTENT=$(sudo virsh pool-info "$pool" 2>/dev/null | grep "Persistent:" | awk '{print $2}' || echo "unknown")
    
    if [ "$STATE" = "inactive" ]; then
        log_warning "  - $pool (State: $STATE, Autostart: $AUTOSTART, Persistent: $PERSISTENT)"
    else
        log_info "  - $pool (State: $STATE, Autostart: $AUTOSTART, Persistent: $PERSISTENT)"
    fi
done

log ""

# ============================================================================
# Find Inactive Pools
# ============================================================================
log_info "Identifying inactive pools..."

INACTIVE_POOLS=()
for pool in $ALL_POOLS; do
    STATE=$(sudo virsh pool-info "$pool" 2>/dev/null | grep "State:" | awk '{print $2}' || echo "unknown")
    if [ "$STATE" = "inactive" ]; then
        INACTIVE_POOLS+=("$pool")
    fi
done

if [ ${#INACTIVE_POOLS[@]} -eq 0 ]; then
    log_success "No inactive pools found"
    exit 0
fi

log_warning "Found ${#INACTIVE_POOLS[@]} inactive pool(s):"
for pool in "${INACTIVE_POOLS[@]}"; do
    log_warning "  - $pool"
done

log ""

# ============================================================================
# Confirmation
# ============================================================================
if [ "$FORCE_MODE" = false ] && [ "$DRY_RUN" = false ]; then
    log_warning "This will delete the following inactive pools:"
    for pool in "${INACTIVE_POOLS[@]}"; do
        echo "  - $pool"
    done
    log ""
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
fi

log ""

# ============================================================================
# Clean Inactive Pools
# ============================================================================
log_info "Processing inactive pools..."
log ""

CLEANED_COUNT=0
FAILED_COUNT=0

for pool in "${INACTIVE_POOLS[@]}"; do
    log_info "Processing pool: $pool"
    
    # Get pool information
    POOL_PATH=$(sudo virsh pool-dumpxml "$pool" 2>/dev/null | grep "<path>" | sed 's/.*<path>\(.*\)<\/path>.*/\1/' || echo "")
    
    if [ -n "$POOL_PATH" ]; then
        log_info "  Pool path: $POOL_PATH"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY RUN] Would undefine pool: $pool"
        if [ -n "$POOL_PATH" ] && [ -d "$POOL_PATH" ]; then
            log_info "  [DRY RUN] Would remove directory: $POOL_PATH"
        fi
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        continue
    fi
    
    # Try to destroy pool if it's somehow still active
    log_info "  Ensuring pool is stopped..."
    sudo virsh pool-destroy "$pool" 2>&1 | tee -a "$LOG_FILE" || true
    
    # List and delete volumes
    log_info "  Checking for volumes..."
    VOLUMES=$(sudo virsh vol-list "$pool" 2>/dev/null | tail -n +3 | awk '{print $1}' | grep -v "^$" || true)
    
    if [ -n "$VOLUMES" ]; then
        log_warning "  Found volumes in pool:"
        VOL_COUNT=0
        for vol in $VOLUMES; do
            log_info "    - Deleting volume: $vol"
            if sudo virsh vol-delete "$vol" --pool "$pool" 2>&1 | tee -a "$LOG_FILE"; then
                VOL_COUNT=$((VOL_COUNT + 1))
            else
                log_warning "    Failed to delete volume: $vol"
            fi
        done
        log_success "  Deleted $VOL_COUNT volume(s)"
    else
        log_info "  No volumes found"
    fi
    
    # Undefine pool
    log_info "  Undefining pool..."
    if sudo virsh pool-undefine "$pool" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "  Pool undefined: $pool"
        
        # Remove pool directory if it exists
        if [ -n "$POOL_PATH" ] && [ -d "$POOL_PATH" ]; then
            log_info "  Checking pool directory..."
            
            # Check if directory is empty
            if [ -z "$(ls -A "$POOL_PATH" 2>/dev/null)" ]; then
                log_info "  Removing empty directory: $POOL_PATH"
                if sudo rmdir "$POOL_PATH" 2>&1 | tee -a "$LOG_FILE"; then
                    log_success "  Directory removed"
                else
                    log_warning "  Failed to remove directory"
                fi
            else
                log_warning "  Directory not empty: $POOL_PATH"
                log_info "  Contents:"
                sudo ls -la "$POOL_PATH" 2>/dev/null | tee -a "$LOG_FILE" || true
                
                read -p "  Remove directory and all contents? (yes/no): " -r
                echo
                if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                    log_warning "  Forcing removal of directory..."
                    if sudo rm -rf "$POOL_PATH" 2>&1 | tee -a "$LOG_FILE"; then
                        log_success "  Directory removed"
                    else
                        log_error "  Failed to remove directory"
                    fi
                else
                    log_info "  Directory kept: $POOL_PATH"
                fi
            fi
        fi
        
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_error "  Failed to undefine pool: $pool"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    
    log ""
done

# ============================================================================
# Summary
# ============================================================================
log "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
log "${CYAN}║                  Cleanup Summary                           ║${NC}"
log "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
log ""

if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN completed"
    log_info "  Pools that would be cleaned: $CLEANED_COUNT"
else
    log_info "Cleanup completed"
    log_success "  Pools cleaned: $CLEANED_COUNT"
    if [ $FAILED_COUNT -gt 0 ]; then
        log_warning "  Pools failed: $FAILED_COUNT"
    fi
fi

log ""
log_info "Log file: $LOG_FILE"
log ""

# ============================================================================
# Verification
# ============================================================================
log_info "Current pool status:"
sudo virsh pool-list --all 2>/dev/null | tee -a "$LOG_FILE" || true

log ""

if [ $FAILED_COUNT -eq 0 ]; then
    log_success "✓ All inactive pools cleaned successfully!"
else
    log_warning "⚠ Some pools could not be cleaned"
    log_info "Check log file for details: $LOG_FILE"
fi

exit 0