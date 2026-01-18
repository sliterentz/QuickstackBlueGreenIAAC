#!/bin/bash

# ==============================================================================
# Terraform Init Upgrade Script
# 
# Deskripsi: Skrip untuk menjalankan 'terraform init -upgrade' dengan 
# penanganan error yang kuat, caching, dan fitur rollback.
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Config
MIN_TF_VERSION="1.0.0"
REGISTRY_URL="https://registry.terraform.io"
TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
LOG_DIR="$(pwd)/logs"
LOG_FILE="$LOG_DIR/terraform-init-upgrade-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE=".terraform.lock.hcl"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Global variable for backup path
BACKUP_LOCK_FILE=""

# Function to print status
print_status() {
    local status=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$status" in
        "ok")      echo -e "${GREEN}[$timestamp] ✓${NC} $message" ;;
        "error")   echo -e "${RED}[$timestamp] ✗${NC} $message" ;;
        "warn")    echo -e "${YELLOW}[$timestamp] ⚠${NC} $message" ;;
        "info")    echo -e "${CYAN}[$timestamp] ℹ${NC} $message" ;;
        "step")    echo -e "${BLUE}[$timestamp] ⮕${NC} $message" ;;
    esac
    
    echo "[$timestamp] [$status] $message" >> "$LOG_FILE"
}

# 1. Environment Configuration
configure_env() {
    print_status "step" "Konfigurasi environment..."
    
    # Setup Plugin Cache
    if [ ! -d "$TF_PLUGIN_CACHE_DIR" ]; then
        print_status "info" "Membuat direktori cache plugin: $TF_PLUGIN_CACHE_DIR"
        mkdir -p "$TF_PLUGIN_CACHE_DIR"
    fi
    export TF_PLUGIN_CACHE_DIR="$TF_PLUGIN_CACHE_DIR"
    print_status "ok" "Plugin cache dikonfigurasi di: $TF_PLUGIN_CACHE_DIR"
}

# 2. Verify Connectivity
check_connectivity() {
    print_status "step" "Memeriksa konektivitas ke Terraform Registry..."
    
    if command -v curl >/dev/null 2>&1; then
        if curl -s --head "$REGISTRY_URL" > /dev/null; then
            print_status "ok" "Koneksi ke $REGISTRY_URL berhasil"
        else
            print_status "error" "Gagal terhubung ke $REGISTRY_URL"
            return 1
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 registry.terraform.io > /dev/null 2>&1; then
            print_status "ok" "Ping ke registry.terraform.io berhasil"
        else
            print_status "error" "Ping ke registry.terraform.io gagal"
            return 1
        fi
    else
        print_status "warn" "Alat pemeriksaan koneksi (curl/ping) tidak ditemukan. Lewati."
    fi
}

# 3. Check Terraform Version
check_version() {
    print_status "step" "Memeriksa versi Terraform..."
    
    if ! command -v terraform >/dev/null 2>&1; then
        print_status "error" "Terraform tidak terinstall atau tidak ada di PATH"
        return 1
    fi
    
    CURRENT_VERSION=$(terraform version -json | jq -r '.terraform_version')
    print_status "info" "Versi Terraform saat ini: $CURRENT_VERSION"
    
    if [[ "$(printf '%s\n' "$MIN_TF_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" != "$MIN_TF_VERSION" ]]; then
        print_status "error" "Versi Terraform minimal adalah $MIN_TF_VERSION. Saat ini: $CURRENT_VERSION"
        return 1
    fi
    print_status "ok" "Versi Terraform kompatibel"
}

# 4. State Compatibility Check
check_state() {
    print_status "step" "Memeriksa kompatibilitas state file..."
    
    if [ -f "terraform.tfstate" ]; then
        if jq . "terraform.tfstate" >/dev/null 2>&1; then
            print_status "ok" "State file (local) valid"
        else
            print_status "warn" "State file ditemukan tetapi tidak valid atau terenkripsi (mungkin remote/cloud)"
        fi
    else
        print_status "info" "State file tidak ditemukan (deployment baru)"
    fi
}

# 5. Backup Lock File for Rollback
backup_lock() {
    if [ -f "$LOCK_FILE" ]; then
        print_status "info" "Membuat backup lock file..."
        # Use /tmp to avoid path allowlist issues in some environments
        BACKUP_LOCK_FILE="/tmp/tf_lock_backup_$(date +%s)"
        cp "$LOCK_FILE" "$BACKUP_LOCK_FILE" 2>/dev/null || {
            print_status "warn" "Gagal membuat backup lock file di /tmp. Fitur rollback mungkin terbatas."
            BACKUP_LOCK_FILE=""
            return 0
        }
        print_status "ok" "Backup lock file disimpan di: $BACKUP_LOCK_FILE"
    fi
}

# 6. Execute Init Upgrade
run_init_upgrade() {
    print_status "step" "Menjalankan 'terraform init -upgrade'..."
    
    if terraform init -upgrade -no-color 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Terraform init -upgrade berhasil"
        return 0
    else
        print_status "error" "Terraform init -upgrade gagal"
        return 1
    fi
}

# 7. Rollback Mechanism
rollback() {
    print_status "warn" "Memulai proses rollback ke versi sebelumnya..."
    
    if [ -n "$BACKUP_LOCK_FILE" ] && [ -f "$BACKUP_LOCK_FILE" ]; then
        cp "$BACKUP_LOCK_FILE" "$LOCK_FILE" 2>/dev/null || {
            print_status "error" "Gagal mengembalikan lock file dari backup."
            return 1
        }
        print_status "info" "Lock file dikembalikan. Menjalankan init ulang..."
        if terraform init -no-color 2>&1 | tee -a "$LOG_FILE"; then
            print_status "ok" "Rollback berhasil"
        else
            print_status "error" "Rollback gagal"
            return 1
        fi
    else
        print_status "error" "Tidak ada backup lock file yang valid untuk rollback"
        return 1
    fi
}

# 8. Validate Configuration
validate_config() {
    print_status "step" "Validasi konfigurasi Terraform..."
    if terraform validate -no-color 2>&1 | tee -a "$LOG_FILE"; then
        print_status "ok" "Konfigurasi valid"
    else
        print_status "error" "Validasi konfigurasi gagal"
        return 1
    fi
}

# 9. Document Changes
document_changes() {
    print_status "step" "Mendokumentasikan perubahan..."
    
    REPORT_FILE="$LOG_DIR/upgrade-report-$(date +%Y%m%d).md"
    {
        echo "# Terraform Upgrade Report"
        echo "Tanggal: $(date)"
        echo "Versi Terraform: $(terraform version -json | jq -r '.terraform_version')"
        echo ""
        echo "## Provider Changes"
        if [ -n "$BACKUP_LOCK_FILE" ] && [ -f "$BACKUP_LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
            echo "Berikut adalah perubahan versi provider:"
            diff "$BACKUP_LOCK_FILE" "$LOCK_FILE" | grep "version =" || echo "Tidak ada perubahan versi provider."
        else
            echo "Informasi perubahan tidak tersedia (backup tidak ditemukan)."
        fi
    } > "$REPORT_FILE"
    
    print_status "ok" "Laporan upgrade disimpan di: $REPORT_FILE"
}

# Main Execution Flow
main() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Terraform Init & Upgrade Handler              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Log file: $LOG_FILE${NC}"
    echo ""

    configure_env
    check_connectivity || exit 1
    check_version || exit 1
    check_state
    
    backup_lock
    
    if run_init_upgrade; then
        validate_config || {
            print_status "warn" "Validasi gagal setelah upgrade. Mencoba rollback..."
            rollback
            exit 1
        }
        document_changes
        print_status "ok" "Proses upgrade selesai dengan sukses!"
    else
        rollback
        exit 1
    fi
    
    # Cleanup backup if successful
    if [ -n "$BACKUP_LOCK_FILE" ] && [ -f "$BACKUP_LOCK_FILE" ]; then
        rm -f "$BACKUP_LOCK_FILE" 2>/dev/null || true
    fi
}

# Run main
main "$@"
