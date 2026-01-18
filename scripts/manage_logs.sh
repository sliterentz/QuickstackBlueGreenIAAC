#!/bin/bash

# ==============================================================================
# Script to manage and move log files to the central logs directory
# ==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DEST_DIR="$PROJECT_ROOT/logs"
LOG_FILES=(
    ".cloudinit_cleanup.log"
    ".cloudinit_verification.log"
    ".health_check.log"
    ".virt_detection.log"
    ".pre_deployment_check.log"
)
SOURCE_DIRS=(
    "$PROJECT_ROOT"
    "$PROJECT_ROOT/terraform-kvm-ubuntu"
)

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠ $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1${NC}"
}

# 1. Ensure logs directory exists
if [ ! -d "$LOG_DEST_DIR" ]; then
    log "Creating logs directory: $LOG_DEST_DIR"
    mkdir -p "$LOG_DEST_DIR"
    chmod 755 "$LOG_DEST_DIR"
fi

log "Starting log migration to $LOG_DEST_DIR"

# 2. Identify and move log files
for log_file in "${LOG_FILES[@]}"; do
    for source_dir in "${SOURCE_DIRS[@]}"; do
        source_path="$source_dir/$log_file"
        dest_path="$LOG_DEST_DIR/$log_file"
        
        if [ -f "$source_path" ]; then
            # Check if it's already in the destination (source and dest are same)
            if [ "$source_path" == "$dest_path" ]; then
                continue
            fi
            
            log "Found $log_file in $source_dir. Moving..."
            
            # Check if file is locked (using lsof if available, or just try move)
            if command -v lsof >/dev/null 2>&1; then
                if lsof "$source_path" >/dev/null 2>&1; then
                    log_warn "File $source_path is currently in use. Skipping..."
                    continue
                fi
            fi
            
            # Move while preserving permissions
            if cp -p "$source_path" "$dest_path" && rm "$source_path"; then
                log_success "Moved $log_file to $LOG_DEST_DIR"
            else
                log_error "Failed to move $log_file from $source_dir"
            fi
        fi
    done
done

# 3. Verify
log "Verifying migration..."
ALL_MOVED=true
for log_file in "${LOG_FILES[@]}"; do
    dest_path="$LOG_DEST_DIR/$log_file"
    
    # We only care if they exist in the new location IF they existed at all
    # But for verification, let's just check what's there now
    if [ -f "$dest_path" ]; then
        log "✓ $log_file is present in $LOG_DEST_DIR"
        ls -l "$dest_path"
    fi
    
    # Check if they still exist in source dirs
    for source_dir in "${SOURCE_DIRS[@]}"; do
        source_path="$source_dir/$log_file"
        if [ "$source_path" != "$dest_path" ] && [ -f "$source_path" ]; then
            log_error "File still exists in source: $source_path"
            ALL_MOVED=false
        fi
    done
done

if [ "$ALL_MOVED" = true ]; then
    log_success "Log migration completed successfully."
else
    log_warn "Log migration completed with some issues."
fi
