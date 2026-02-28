#!/bin/bash

# ==============================================================================
# Terraform Optimized Deployment Script (v3 - Real-time Progress)
# ==============================================================================
# Deskripsi: Skrip untuk menjalankan validasi, perencanaan, dan penerapan
#            infrastruktur Terraform dengan visualisasi progres real-time.
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Ini mencegah error "unbound variable" sebelum fungsi validate_environment dipanggil
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# Konfigurasi Warna
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Konfigurasi Direktori dan File
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs/terraform"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/terraform-deployment-${TIMESTAMP}.log"
VAR_FILE="${PROJECT_ROOT}/terraform.tfvars"
PLAN_FILE="${PROJECT_ROOT}/tfplan-${TIMESTAMP}.out"

# Progres Konfigurasi
TOTAL_STEPS=7
CURRENT_STEP=0
START_TIME=$(date +%s)

# Estimasi durasi per langkah (detik) - untuk ETC awal
declare -A STEP_WEIGHTS=(
    [1]=5   # Init
    [2]=3   # Validate
    [3]=15  # Plan
    [4]=60  # Apply
    [5]=2   # Outputs
    [6]=1   # Cleanup
)
TOTAL_WEIGHT=91

TF_PARALLELISM="${TF_PARALLELISM:-1}"
TF_INIT_RETRIES="${TF_INIT_RETRIES:-3}"
TF_INIT_UPGRADE="${TF_INIT_UPGRADE:-false}"
TF_REGISTRY_CLIENT_TIMEOUT="${TF_REGISTRY_CLIENT_TIMEOUT:-120}"
TF_PROVIDER_NET_RETRIES="${TF_PROVIDER_NET_RETRIES:-3}"
TF_PROVIDER_NET_TIMEOUT_SECONDS="${TF_PROVIDER_NET_TIMEOUT_SECONDS:-15}"

# Fungsi: Gambar Progress Bar
draw_progress_bar() {
    local percentage=$1
    local status_msg=$2
    local width=40
    local filled=$((percentage * width / 100))
    local empty=$((width - filled))
    
    # Hitung ETC
    local now=$(date +%s)
    local elapsed=$((now - START_TIME))
    local etc="Calculating..."
    
    if [ $percentage -gt 0 ]; then
        local total_est=$((elapsed * 100 / percentage))
        local remaining=$((total_est - elapsed))
        if [ $remaining -lt 0 ]; then remaining=0; fi
        etc="${remaining}s"
    fi

    # Render Bar
    printf "\r${WHITE}[${CYAN}"
    printf "%${filled}s" | tr ' ' '█'
    printf "${NC}"
    printf "%${empty}s" | tr ' ' '░'
    printf "${WHITE}] ${percentage}%% | ETC: ${etc} | ${status_msg}${NC}"
}

# Fungsi: Cetak Status
print_status() {
    local type=$1
    local message=$2
    local timestamp=$(date "+%H:%M:%S")
    
    case $type in
        "info")    echo -e "${BLUE}[$timestamp INFO]${NC} $message" ;;
        "success") echo -e "\n${GREEN}[$timestamp SUCCESS]${NC} $message" ;;
        "warn")    echo -e "${YELLOW}[$timestamp WARN]${NC} $message" ;;
        "error")   echo -e "\n${RED}[$timestamp ERROR]${NC} $message" ;;
        "step")    
            CURRENT_STEP=$((CURRENT_STEP + 1))
            local pct=$(( (CURRENT_STEP - 1) * 100 / TOTAL_STEPS ))
            draw_progress_bar $pct "$message"
            echo -e "\n${CYAN}[$timestamp STEP $CURRENT_STEP/$TOTAL_STEPS]${NC} ${WHITE}$message${NC}"
            ;;
    esac
}

libvirt_uri_is_remote() {
    local uri="${LIBVIRT_DEFAULT_URI:-}"
    [[ "$uri" == *"+ssh://"* || "$uri" == *"+tcp://"* || "$uri" == *"+tls://"* || "$uri" == ssh://* || "$uri" == tcp://* || "$uri" == tls://* ]]
}

sudo_noninteractive_ok() {
    command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

run_virsh() {
    local rc=0
    if virsh -c "${LIBVIRT_DEFAULT_URI}" "$@"; then
        return 0
    fi
    rc=$?

    if libvirt_uri_is_remote; then
        return "$rc"
    fi

    if sudo_noninteractive_ok; then
        sudo virsh -c "${LIBVIRT_DEFAULT_URI}" "$@"
        return $?
    fi

    return "$rc"
}

SUDO_CHECK_OUTPUT=""
if command -v sudo >/dev/null 2>&1; then
    SUDO_CHECK_OUTPUT="$(sudo -n true 2>&1 || true)"
    if echo "$SUDO_CHECK_OUTPUT" | grep -qiE "must be owned by uid 0|setuid bit set|owned by uid"; then
        print_status "warn" "sudo tidak dapat digunakan (permission/ownership rusak). Menjalankan perintah tanpa sudo."
        sudo() { "$@"; }
    fi
fi

# Fungsi: Penanganan Error
handle_error() {
    local exit_code=$1
    local step=$2
    print_status "error" "Langkah '$step' gagal dengan exit code $exit_code."
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
    echo "ERROR at $(date): Step '$step' failed with exit code $exit_code" >> "$LOG_FILE"
    
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              Deployment Gagal! ✗                       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
    print_status "info" "Detail error dapat dilihat di: $LOG_FILE"
    
    exit "$exit_code"
}

# Fungsi: Inisialisasi Log
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    echo "Terraform Deployment Log - $TIMESTAMP" > "$LOG_FILE"
    echo "Start Time: $(date)" >> "$LOG_FILE"
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
}

# Fungsi: Verifikasi Storage Pool Libvirt
verify_libvirt_pool() {
    print_status "info" "Verifying libvirt storage pool..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    
    # Check if pool exists
    if ! virsh pool-list --all | grep -q "$pool_name"; then
        print_status "error" "Storage pool '$pool_name' not found"
        print_status "info" "Attempting to create storage pool..."

        # Create pool if not exists
        virsh pool-define-as "$pool_name" dir --target "$pool_path" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to define storage pool"
            handle_error 1 "Define Storage Pool"
        }

        # PERBAIKAN: Menghapus spasi berlebih sebelum sudo yang menyebabkan error
        virsh pool-build "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to build storage pool"
            handle_error 1 "Build Storage Pool"
        }
        
        virsh pool-start "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to start storage pool"
            handle_error 1 "Start Storage Pool"
        }
        
        virsh pool-autostart "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "warn" "Failed to set pool autostart (non-critical)"
        }
        
        print_status "success" "Storage pool created successfully"
    fi
    
    # Check if pool is active
    if ! virsh pool-list | grep -q "$pool_name"; then
        print_status "info" "Activating storage pool..."
        virsh pool-start "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to start storage pool"
            handle_error 1 "Start Storage Pool"
        }
    fi
    
    if ! libvirt_uri_is_remote; then
        # Deteksi QEMU user
        local qemu_user=$(detect_qemu_user)
        local qemu_group=$(detect_qemu_group)
        
        print_status "info" "Detected QEMU runtime: $qemu_user:$qemu_group"
        
        if [[ ! -d "$pool_path" ]]; then
            print_status "warn" "Pool path does not exist: $pool_path"
            print_status "info" "Creating pool path..."
            sudo mkdir -p "$pool_path"
        fi

        # Set correct ownership based on detected user
        print_status "info" "Setting ownership to $qemu_user:$qemu_group..."
        
        if [[ "$qemu_user" == "root" ]]; then
            sudo chown -R root:root "$pool_path"
            sudo chmod 755 "$pool_path"
            print_status "info" "✓ Pool configured for root execution"
        else
            sudo chown -R "$qemu_user:$qemu_group" "$pool_path"
            sudo chmod 755 "$pool_path"
            print_status "info" "✓ Pool configured for unprivileged execution"
        fi
        
        # Verify ownership
        local actual_owner=$(stat -c '%U:%G' "$pool_path" 2>/dev/null)
        print_status "info" "Pool path owner: $actual_owner"
        
        if [[ "$actual_owner" != "$qemu_user:$qemu_group" ]]; then
            print_status "error" "Ownership mismatch! Expected: $qemu_user:$qemu_group, Got: $actual_owner"
            handle_error 1 "Pool Ownership"
        fi
    else
        print_status "info" "Remote libvirt URI detected, skipping local path checks"
    fi
    
    if [[ ! -d "$pool_path" ]]; then
        print_status "warn" "Pool path does not exist: $pool_path"
    fi

    if [[ -d "$pool_path" ]] && ! test -w "$pool_path"; then
        print_status "warn" "Pool path is not writable by current user: $pool_path (non-critical jika libvirt berjalan sebagai root)"
    fi
    
    # Refresh pool to sync with filesystem
    print_status "info" "Refreshing storage pool..."
    virsh pool-refresh "$pool_name" >> "$LOG_FILE" 2>&1 || {
        print_status "warn" "Pool refresh failed (non-critical)"
    }
    
    # Display pool info
    print_status "info" "Storage pool status:"
    virsh pool-info "$pool_name" | tee -a "$LOG_FILE"
    
    print_status "success" "Storage pool verified and ready"
    return 0
}

# Fungsi: Verifikasi Volume Storage
verify_storage_volumes() {
    print_status "info" "Verifying storage volumes..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    
    # List all volumes in pool
    print_status "info" "Current volumes in pool:"
    virsh vol-list "$pool_name" 2>&1 | tee -a "$LOG_FILE"
    
    # Check for orphaned or problematic volumes
    print_status "info" "Checking for orphaned volumes..."
    
    # List files in pool directory
    print_status "info" "Files in pool directory:"
    ls -lh "$pool_path" 2>&1 | tee -a "$LOG_FILE"
    
    # Verify each expected volume type
    local volume_types=("ubuntu-base-img" "ubuntu-disk" "cloudinit")
    local found_issues=false
    
    for vol_type in "${volume_types[@]}"; do
        local vol_count
        vol_count=$(virsh vol-list "$pool_name" 2>/dev/null | grep -c "$vol_type" || true)
        print_status "info" "Found $vol_count volumes of type: $vol_type"
        
        if [[ "$vol_type" == "cloudinit" && $vol_count -eq 0 ]]; then
            print_status "warn" "No cloud-init volumes found (will be created during deployment)"
        fi
    done
    
    # Check for file-pool mismatch
    print_status "info" "Checking for file-pool synchronization issues..."
    
    shopt -s nullglob  # Aktifkan nullglob untuk menangani pattern yang tidak cocok
    local files_found=false

    # Files in directory but not in pool
    for file in "$pool_path"/*.qcow2 "$pool_path"/*.iso; do
        if [[ -f "$file" ]]; then
            files_found=true
            local basename
            basename=$(basename "$file")

            if ! virsh vol-list "$pool_name" 2>/dev/null | grep -q "$basename"; then
                print_status "warn" "File exists but not in pool: $basename"
                found_issues=true
            fi
        fi
    done

    shopt -u nullglob  # Nonaktifkan nullglob setelah selesai

    if [[ "$files_found" == "false" ]]; then
        print_status "info" "No qcow2 or iso files found in pool directory"
    fi

    if [[ "$found_issues" == "true" ]]; then
        print_status "info" "Synchronization issues detected, refreshing pool..."
        sudo virsh pool-refresh "$pool_name" >> "$LOG_FILE" 2>&1
        
        print_status "info" "Updated volume list:"
        sudo virsh vol-list "$pool_name" 2>&1 | tee -a "$LOG_FILE"
    fi
    
    print_status "success" "Storage volume verification completed"
    return 0
}

# Fungsi: Ensure Storage Pool is Ready for Volume Creation
ensure_pool_ready_for_volumes() {
    print_status "info" "Ensuring storage pool is ready for volume creation..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    local max_wait=30
    local wait_count=0
    
    # 1. Verify pool is active
    while ! sudo virsh pool-list | grep -q "$pool_name.*active"; do
        if [[ $wait_count -ge $max_wait ]]; then
            print_status "error" "Storage pool failed to become active"
            return 1
        fi
        
        print_status "info" "Waiting for pool to become active... ($wait_count/$max_wait)"
        sleep 2
        ((wait_count++))
    done
    
    print_status "success" "Storage pool is active"
    
    # 2. Verify pool path permissions
    if ! libvirt_uri_is_remote; then
        print_status "info" "Verifying pool path permissions..."
        
        # Deteksi QEMU user dan group
        local qemu_user=$(detect_qemu_user)
        local qemu_group=$(detect_qemu_group)
        
        print_status "info" "QEMU akan berjalan sebagai: $qemu_user:$qemu_group"
        
        if [[ ! -d "$pool_path" ]]; then
            print_status "warn" "Pool path doesn't exist, creating..."
            sudo mkdir -p "$pool_path" || return 1
        fi

        # Set ownership ke QEMU user (bukan current user)
        print_status "info" "Setting ownership ke $qemu_user:$qemu_group..."
        if [[ "$qemu_user" == "root" ]]; then
            sudo chown -R root:root "$pool_path" || {
                print_status "error" "Gagal set ownership ke root:root"
                return 1
            }
            sudo chmod 755 "$pool_path" || return 1
            print_status "info" "✓ Pool owned by root (libvirt running as root)"
        else
            sudo chown -R "$qemu_user:$qemu_group" "$pool_path" || {
                print_status "error" "Gagal set ownership ke $qemu_user:$qemu_group"
                return 1
            }
            sudo chmod 755 "$pool_path" || return 1
            print_status "info" "✓ Pool owned by $qemu_user:$qemu_group"
        fi

        # Verify ownership
        local actual_owner=$(stat -c '%U:%G' "$pool_path" 2>/dev/null)
        local expected_owner="$qemu_user:$qemu_group"

        if [[ "$actual_owner" == "$expected_owner" ]]; then
            print_status "success" "✓ Ownership correct: $actual_owner"
        else
            print_status "error" "✗ Ownership mismatch: $actual_owner (expected: $expected_owner)"
            return 1
        fi
        
        # Test write access sebagai QEMU user (bukan current user)
        print_status "info" "Testing write permissions untuk QEMU user..."
        local test_file="${pool_path}/.test_write_$$"
        
        if [[ "$qemu_user" == "root" ]]; then
            # Jika root, langsung test dengan sudo
            if sudo touch "$test_file" 2>/dev/null; then
                sudo rm -f "$test_file"
                print_status "success" "✓ Root dapat menulis ke pool"
            else
                print_status "error" "✗ Root tidak dapat menulis ke pool"
                return 1
            fi
        else
            # Jika unprivileged user, test dengan sudo -u
            if sudo -u "$qemu_user" touch "$test_file" 2>/dev/null; then
                sudo rm -f "$test_file"
                print_status "success" "✓ QEMU user ($qemu_user) dapat menulis ke pool"
            else
                print_status "error" "✗ QEMU user ($qemu_user) tidak dapat menulis ke pool"
                
                # Debug info
                print_status "info" "Debug - Directory permissions:"
                ls -lad "$pool_path" | tee -a "$LOG_FILE"
                
                return 1
            fi
        fi
    else
        print_status "info" "Libvirt URI remote terdeteksi. Melewati perbaikan permission path lokal: $pool_path"
    fi
    
    # 3. Verify pool has available space
    local available_space
    available_space=$(sudo virsh pool-info "$pool_name" | grep "Available:" | awk '{print $2}' | sed 's/[^0-9.]//g')
    
    if [[ -z "$available_space" ]] || awk -v val="$available_space" 'BEGIN {exit !(val < 10)}'; then
        print_status "error" "Insufficient storage space in pool (need at least 10GB)"
        return 1
    fi
    
    print_status "info" "Available space: ${available_space}GB"
    
    # 4. Test write permission by creating a test file
    print_status "info" "Testing write permissions..."
    local test_file="${pool_path}/.test_write_$$"
    if sudo touch "$test_file" 2>/dev/null; then
        sudo rm -f "$test_file"
        print_status "success" "Write permissions verified"
    else
        print_status "error" "Cannot write to pool path"
        return 1
    fi
    
    # 5. Refresh pool to ensure sync
    print_status "info" "Refreshing pool state..."
    sudo virsh pool-refresh "$pool_name" >> "$LOG_FILE" 2>&1 || {
        print_status "warn" "Pool refresh failed (non-critical)"
    }
    
    # 6. Wait a bit for pool to stabilize
    print_status "info" "Allowing pool to stabilize..."
    sleep 3
    
    print_status "success" "Storage pool is ready for volume creation"
    return 0
}

# Fungsi: Pre-create Base Image Volume (jika belum ada)
precreate_base_image_volume() {
    print_status "info" "Checking for existing base image volume..."
    
    local pool_name="k3s_infra_pool"
    local base_vol_name="ubuntu-base-img"
    
    # Check if base volume already exists
    if sudo virsh vol-list "$pool_name" 2>/dev/null | grep -q "$base_vol_name"; then
        print_status "info" "Base image volume already exists"
        
        # Verify volume is accessible
        local vol_path
        vol_path=$(sudo virsh vol-path "$base_vol_name" --pool "$pool_name" 2>/dev/null)
        
        if [[ -n "$vol_path" ]] && [[ -f "$vol_path" ]]; then
            local vol_size
            vol_size=$(sudo ls -lh "$vol_path" | awk '{print $5}')
            print_status "success" "Base image verified: $vol_path ($vol_size)"
            return 0
        else
            print_status "warn" "Base image exists in pool but file not found, cleaning up..."
            sudo virsh vol-delete "$base_vol_name" --pool "$pool_name" 2>/dev/null || true
        fi
    fi
    
    print_status "info" "Base image volume will be created by Terraform"
    return 0
}

# Fungsi helper untuk deteksi QEMU user
detect_qemu_user() {
    local qemu_user=""
    
    # 1. Cek dari proses QEMU yang sedang berjalan
    if pgrep -x qemu-system-x86 >/dev/null 2>&1; then
        qemu_user=$(ps aux | grep -E '[q]emu-system-x86' | head -1 | awk '{print $1}')
        if [[ -n "$qemu_user" ]]; then
            echo "$qemu_user"
            return 0
        fi
    fi
    
    # 2. Cek dari konfigurasi libvirt qemu.conf
    if [[ -f /etc/libvirt/qemu.conf ]]; then
        # Try reading with sudo
        local conf_user=""
        if sudo_noninteractive_ok; then
            conf_user=$(sudo grep -E '^\s*user\s*=' /etc/libvirt/qemu.conf 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' "')
        elif [[ -r /etc/libvirt/qemu.conf ]]; then
            # Fallback to direct read if file is readable
            conf_user=$(grep -E '^\s*user\s*=' /etc/libvirt/qemu.conf 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' "')
        fi

        # Jika user = "root" atau tidak di-set (commented), maka libvirt berjalan sebagai root
        if [[ -n "$conf_user" ]] && [[ "$conf_user" != "root" ]]; then
            echo "$conf_user"
            return 0
        fi
    fi
        
    # 3. Cek dari proses libvirtd
    if pgrep -x libvirtd >/dev/null 2>&1; then
        local libvirt_user=$(ps aux | grep -E '[l]ibvirtd' | head -1 | awk '{print $1}')
        if [[ "$libvirt_user" == "root" ]]; then
            # Libvirt berjalan sebagai root, maka QEMU juga akan berjalan sebagai root
            echo "root"
            return 0
        fi
    fi

    # 4. Check from virtqemud process (newer libvirt)
    if pgrep -x virtqemud >/dev/null 2>&1; then
        local virtqemu_user=$(ps aux | grep -E '[v]irtqemud' | head -1 | awk '{print $1}')
        if [[ -n "$virtqemu_user" ]]; then
            echo "$virtqemu_user"
            return 0
        fi
    fi

    # 5. Fallback ke user default berdasarkan distro
    if [[ -z "$qemu_user" ]]; then
        if id libvirt-qemu >/dev/null 2>&1; then
            qemu_user="libvirt-qemu"
        elif id qemu >/dev/null 2>&1; then
            qemu_user="qemu"
        else
            qemu_user="root"
        fi
    fi
    
    echo "$qemu_user"
}

detect_qemu_group() {
    local qemu_group=""
    local qemu_user=$(detect_qemu_user)
    
    # Jika QEMU user adalah root, group juga root
    if [[ "$qemu_user" == "root" ]]; then
        echo "root"
        return 0
    fi
    
    # Cek dari konfigurasi libvirt
    if [[ -f /etc/libvirt/qemu.conf ]]; then
        qemu_group=$(grep -E '^\s*group\s*=' /etc/libvirt/qemu.conf | sed 's/.*=\s*"\(.*\)"/\1/' | tr -d ' "')
        if [[ -n "$qemu_group" ]] && [[ "$qemu_group" != "root" ]]; then
            echo "$qemu_group"
            return 0
        fi
    fi
    
    # Fallback ke group default
    if [[ -z "$qemu_group" ]]; then
        if getent group kvm >/dev/null 2>&1; then
            qemu_group="kvm"
        elif getent group libvirt >/dev/null 2>&1; then
            qemu_group="libvirt"
        else
            qemu_group="root"
        fi
    fi
    
    echo "$qemu_group"
}

# Fungsi: Fix Volume Permissions
fix_volume_permissions() {
    print_status "info" "Memperbaiki permissions untuk volume yang ada..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    
    if libvirt_uri_is_remote; then
        print_status "info" "Libvirt URI remote terdeteksi. Melewati perbaikan permission lokal."
        return 0
    fi

    # Deteksi user dan group qemu
    local qemu_user=$(detect_qemu_user)
    local qemu_group=$(detect_qemu_group)

    print_status "info" "QEMU User: $qemu_user, Group: $qemu_group"
    
    # Pastikan direktori pool ada
    if [[ ! -d "$pool_path" ]]; then
        print_status "info" "Membuat direktori pool: $pool_path"
        sudo mkdir -p "$pool_path"
    fi

    if ! ensure_sudo_ready; then
        print_status "error" "Tidak dapat menjalankan sudo untuk memperbaiki permission pool."
        return 1
    fi

    sudo chown root:root /var/lib/libvirt >>"$LOG_FILE" 2>&1 || true
    sudo chown root:root /var/lib/libvirt/images >>"$LOG_FILE" 2>&1 || true
    sudo chmod 0711 /var/lib/libvirt >>"$LOG_FILE" 2>&1 || true
    sudo chmod 0711 /var/lib/libvirt/images >>"$LOG_FILE" 2>&1 || true

    {
        echo "Libvirt pool permission audit (before fix):"
        echo "- pool_path: $pool_path"
        stat -c "  %A %a %U:%G %n" /var/lib/libvirt /var/lib/libvirt/images "$pool_path" 2>/dev/null || true
        sudo find "$pool_path" -maxdepth 1 -type f \( -name '*.qcow2' -o -name '*.iso' \) -printf "  %M %m %u:%g %p\n" 2>/dev/null | head -n 40 || true
    } >>"$LOG_FILE" 2>&1

    # Fix ownership direktori pool
    print_status "info" "Memperbaiki ownership direktori pool..."

    if [[ "$qemu_user" == "root" ]]; then
        # Jika QEMU berjalan sebagai root, set ownership ke root:root
        sudo chown -R root:root "$pool_path" || {
            print_status "error" "Gagal set ownership ke root:root"
            return 1
        }
        # Set permissions yang lebih permissive untuk root
        sudo chmod 0755 "$pool_path"
        
        print_status "info" "✓ Ownership set to root:root (libvirt running as root)"
    else
        # Jika QEMU berjalan sebagai unprivileged user
        sudo chown -R "$qemu_user:$qemu_group" "$pool_path" || {
            print_status "error" "Gagal set ownership ke $qemu_user:$qemu_group"
            return 1
        }
        sudo chmod 0755 "$pool_path"
        
        print_status "info" "✓ Ownership set to $qemu_user:$qemu_group"
    fi

    # Fix permissions untuk semua file yang ada
    print_status "info" "Memperbaiki permissions file volume..."
    shopt -s nullglob
    for file in "$pool_path"/*.qcow2 "$pool_path"/*.iso; do
        if [[ -f "$file" ]]; then
            print_status "info" "  Fixing: $(basename "$file")"
            
            if [[ "$qemu_user" == "root" ]]; then
                sudo chown root:root "$file"
                sudo chmod 0644 "$file"
            else
                sudo chown "$qemu_user:$qemu_group" "$file"
                sudo chmod 0640 "$file"
            fi
        fi
    done
    shopt -u nullglob

    if have_command setfacl; then
        sudo chmod g+s "$pool_path" >>"$LOG_FILE" 2>&1 || true
        sudo setfacl -m "u:${qemu_user}:rwx" -m "g:${qemu_group}:rwx" "$pool_path" >>"$LOG_FILE" 2>&1 || true
        sudo setfacl -d -m "u:${qemu_user}:rwX" -d -m "g:${qemu_group}:rwX" "$pool_path" >>"$LOG_FILE" 2>&1 || true
    fi

    {
        echo "Libvirt pool permission audit (after fix):"
        stat -c "  %A %a %U:%G %n" /var/lib/libvirt /var/lib/libvirt/images "$pool_path" 2>/dev/null || true
        sudo find "$pool_path" -maxdepth 1 -type f \( -name '*.qcow2' -o -name '*.iso' \) -printf "  %M %m %u:%g %p\n" 2>/dev/null | head -n 40 || true
    } >>"$LOG_FILE" 2>&1

    # Verify permissions
    print_status "info" "Verifikasi permissions:"
    ls -lah "$pool_path" | head -n 10 | tee -a "$LOG_FILE"
    
    # Nonaktifkan SELinux sementara jika aktif (untuk troubleshooting)
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_status=$(getenforce 2>/dev/null || echo "Disabled")
        if [[ "$selinux_status" == "Enforcing" ]]; then
            print_status "info" "SELinux Enforcing terdeteksi, memperbaiki context..."
            
            sudo semanage fcontext -a -t virt_image_t "$pool_path(/.*)?" 2>/dev/null || {
                print_status "warn" "Gagal set SELinux fcontext (mungkin sudah ada)"
            }
            
            sudo restorecon -Rv "$pool_path" 2>&1 | tee -a "$LOG_FILE"
            
            print_status "info" "SELinux context:"
            ls -Z "$pool_path" | head -n 5 | tee -a "$LOG_FILE"
        fi
    fi
    
    # Check AppArmor (Ubuntu/Debian)
    if command -v aa-status >/dev/null 2>&1; then
        if sudo aa-status 2>/dev/null | grep -q "libvirtd"; then
            print_status "info" "AppArmor terdeteksi, memperbaiki profile..."
            
            local apparmor_local="/etc/apparmor.d/local/abstractions/libvirt-qemu"
            sudo mkdir -p "$(dirname "$apparmor_local")" 2>/dev/null || true
            sudo touch "$apparmor_local" 2>/dev/null || true
            if ! sudo grep -q "$pool_path" "$apparmor_local" 2>/dev/null; then
                print_status "info" "Menambahkan rule AppArmor..."
                echo "  # Custom pool path for k3s_infra_pool" | sudo tee -a "$apparmor_local" >/dev/null
                echo "  \"$pool_path/\" r," | sudo tee -a "$apparmor_local" >/dev/null
                echo "  \"$pool_path/**\" rwk," | sudo tee -a "$apparmor_local" >/dev/null

                sudo systemctl reload apparmor 2>/dev/null || true
                print_status "success" "AppArmor profile updated"
            fi
        fi
    fi
    
    print_status "success" "Permission fixes selesai"
    return 0
}

# Fungsi: Pre-create and Fix Base Image Volume
precreate_and_fix_base_image_volume() {
    print_status "info" "Mempersiapkan base image volume dengan permissions yang benar..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    local base_vol_name="ubuntu-base-img"
    
    # Jalankan precreate yang sudah ada
    precreate_base_image_volume
    
    if libvirt_uri_is_remote; then
        return 0
    fi
    
    local qemu_user
    local qemu_group
    qemu_user=$(detect_qemu_user)
    qemu_group=$(detect_qemu_group)

    # Cari semua base image volumes dan fix permissions
    print_status "info" "Memperbaiki permissions untuk base image volumes..."
    
    shopt -s nullglob
    for img in "$pool_path"/ubuntu-base-img*.qcow2; do
        if [[ -f "$img" ]]; then
            print_status "info" "  Fixing: $(basename "$img")"
            sudo chown "$qemu_user:$qemu_group" "$img" 2>/dev/null || true
            sudo chmod 0640 "$img" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
    
    print_status "success" "Base image volume permissions fixed"
    return 0
}

# Fungsi: Verify Network Connectivity for Image Download
verify_network_for_download() {
    print_status "info" "Verifying network connectivity for image download..."
    
    local ubuntu_mirror="cloud-images.ubuntu.com"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if ping -c 2 -W 5 "$ubuntu_mirror" &>/dev/null; then
            print_status "success" "Network connectivity to Ubuntu mirror verified"
            return 0
        fi
        
        ((retry++))
        if [[ $retry -lt $max_retries ]]; then
            print_status "warn" "Network check failed, retrying... ($retry/$max_retries)"
            sleep 3
        fi
    done
    
    print_status "error" "Cannot reach Ubuntu cloud images mirror"
    print_status "info" "This may cause timeout during base image download"

    if [[ "${FORCE_MODE:-false}" == "true" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_status "warn" "Continuing despite network check failure due to --force/--dry-run"
        return 0
    fi
    
    read -p "Continue anyway? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        return 1
    fi
    
    return 0
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

sudo_can_run() {
    if ! have_command sudo; then
        return 1
    fi
    sudo -n true >/dev/null 2>&1
}

ensure_sudo_ready() {
    if ! have_command sudo; then
        return 1
    fi
    if sudo -n true >/dev/null 2>&1; then
        return 0
    fi
    print_status "warn" "Dependency install membutuhkan sudo. Anda mungkin diminta memasukkan password."
    sudo true
}

ensure_apparmor_virt_aa_helper_can_write_files() {
    if [[ ! -f "/etc/apparmor.d/usr.lib.libvirt.virt-aa-helper" ]]; then
        return 0
    fi

    local local_override="/etc/apparmor.d/local/usr.lib.libvirt.virt-aa-helper"
    local needed_rule="/etc/apparmor.d/libvirt/libvirt-*.files rw,"

    if [[ -f "$local_override" ]] && grep -qxF "$needed_rule" "$local_override" 2>/dev/null; then
        return 0
    fi

    print_status "warn" "Memperbaiki AppArmor virt-aa-helper agar dapat menulis file allowlist '*.files'"
    if ! ensure_sudo_ready; then
        print_status "error" "Tidak dapat menjalankan sudo untuk memperbaiki AppArmor."
        return 1
    fi

    sudo mkdir -p "/etc/apparmor.d/local" >>"$LOG_FILE" 2>&1 || true
    printf "%s\n" "$needed_rule" | sudo tee -a "$local_override" >/dev/null 2>&1 || return 1

    if have_command apparmor_parser; then
        sudo apparmor_parser -r "/etc/apparmor.d/usr.lib.libvirt.virt-aa-helper" >>"$LOG_FILE" 2>&1 || true
    fi
    if have_command systemctl; then
        sudo systemctl reload apparmor >>"$LOG_FILE" 2>&1 || true
    fi

    return 0
}

audit_libvirt_storage_path() {
    local file_path="$1"
    {
        echo "Libvirt storage audit:"
        echo "- Target: $file_path"
        echo "- Date: $(date)"
        echo "- namei:"
        namei -l "$file_path" 2>&1 || true
        echo "- stat:"
        stat "$file_path" 2>&1 || true
        if have_command getfacl; then
            echo "- getfacl:"
            getfacl -p "$(dirname "$file_path")" "$file_path" 2>&1 || true
        fi
        if have_command aa-status; then
            echo "- aa-status (summary):"
            aa-status 2>&1 | head -n 60 || true
        fi
        if have_command getenforce; then
            echo "- SELinux (getenforce):"
            getenforce 2>&1 || true
        fi
        if have_command ls; then
            echo "- SELinux context (ls -Z) if available:"
            ls -Z "$(dirname "$file_path")" "$file_path" 2>&1 | head -n 10 || true
        fi
        if have_command journalctl; then
            echo "- Kernel denies (journalctl -k | DENIED|apparmor|selinux):"
            journalctl -k -n 200 2>/dev/null | grep -iE "denied|apparmor|selinux" | tail -n 80 || true
        fi
    } >>"$LOG_FILE" 2>&1 || true
}

fix_libvirt_storage_permissions() {
    local pool_dir="/var/lib/libvirt/images/k3s_infra_pool"
    local qemu_user
    local qemu_group
    qemu_user=$(detect_qemu_user)
    qemu_group=$(detect_qemu_group)

    if ! ensure_sudo_ready; then
        return 1
    fi

    sudo chown root:root /var/lib/libvirt >>"$LOG_FILE" 2>&1 || true
    sudo chown root:root /var/lib/libvirt/images >>"$LOG_FILE" 2>&1 || true
    sudo chmod 0711 /var/lib/libvirt >>"$LOG_FILE" 2>&1 || true
    sudo chmod 0711 /var/lib/libvirt/images >>"$LOG_FILE" 2>&1 || true

    sudo chown "$qemu_user":"$qemu_group" "$pool_dir" >>"$LOG_FILE" 2>&1 || true
    sudo chmod 0755 "$pool_dir" >>"$LOG_FILE" 2>&1 || true

    if have_command setfacl; then
        sudo chmod g+s "$pool_dir" >>"$LOG_FILE" 2>&1 || true
        sudo setfacl -m "u:${qemu_user}:rwx" -m "g:${qemu_group}:rwx" "$pool_dir" >>"$LOG_FILE" 2>&1 || true
        sudo setfacl -d -m "u:${qemu_user}:rwX" -d -m "g:${qemu_group}:rwX" "$pool_dir" >>"$LOG_FILE" 2>&1 || true
    fi

    sudo find "$pool_dir" -maxdepth 1 -type f -name '*.qcow2' -exec chown "$qemu_user":"$qemu_group" {} + >>"$LOG_FILE" 2>&1 || true
    sudo find "$pool_dir" -maxdepth 1 -type f -name '*.iso' -exec chown "$qemu_user":"$qemu_group" {} + >>"$LOG_FILE" 2>&1 || true
    sudo find "$pool_dir" -maxdepth 1 -type f -name '*.qcow2' -exec chmod 0640 {} + >>"$LOG_FILE" 2>&1 || true
    sudo find "$pool_dir" -maxdepth 1 -type f -name '*.iso' -exec chmod 0640 {} + >>"$LOG_FILE" 2>&1 || true

    return 0
}

infer_domain_name_from_storage_path() {
    local p="$1"
    local b
    b=$(basename "$p" 2>/dev/null || true)
    if [[ "$b" =~ ^ubuntu-base-img-(.+)\.qcow2$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$b" =~ ^ubuntu-disk-(.+)\.qcow2$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo ""
    return 0
}

cleanup_libvirt_domain_if_safe() {
    local domain_name="$1"
    local expected_prefix="/var/lib/libvirt/images/k3s_infra_pool/"

    if [[ -z "$domain_name" ]]; then
        return 1
    fi
    if ! ensure_sudo_ready; then
        return 1
    fi
    if ! sudo virsh -c qemu:///system dominfo "$domain_name" >/dev/null 2>&1; then
        return 0
    fi

    local disk_path=""
    disk_path=$(sudo virsh -c qemu:///system dumpxml "$domain_name" 2>/dev/null | awk -F"'" '/<source file=/{print $2; exit}' || true)
    if [[ -n "$disk_path" ]] && [[ "$disk_path" != ${expected_prefix}* ]]; then
        print_status "error" "Refusing to cleanup domain '$domain_name' (disk path not in expected pool): $disk_path"
        return 1
    fi

    print_status "warn" "Cleaning up libvirt domain '$domain_name' to allow retry"
    sudo virsh -c qemu:///system destroy "$domain_name" >/dev/null 2>&1 || true
    sudo virsh -c qemu:///system undefine "$domain_name" --managed-save --nvram --snapshots-metadata >>"$LOG_FILE" 2>&1 || sudo virsh -c qemu:///system undefine "$domain_name" >>"$LOG_FILE" 2>&1 || true
    return 0
}

install_packages() {
    local pkgs=("$@")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi

    if have_command apt-get; then
        sudo apt-get update -y >>"$LOG_FILE" 2>&1 || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi
    if have_command dnf; then
        sudo dnf install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi
    if have_command yum; then
        sudo yum install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi
    if have_command zypper; then
        sudo zypper --non-interactive install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi
    if have_command pacman; then
        sudo pacman -Sy --noconfirm "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi
    if have_command apk; then
        sudo apk add --no-cache "${pkgs[@]}" >>"$LOG_FILE" 2>&1
        return $?
    fi

    return 2
}

ensure_mkisofs_available() {
    if have_command mkisofs; then
        return 0
    fi

    if have_command genisoimage; then
        sudo ln -sf "$(command -v genisoimage)" /usr/local/bin/mkisofs >>"$LOG_FILE" 2>&1 || true
        hash -r 2>/dev/null || true
        have_command mkisofs && return 0
    fi

    if have_command xorrisofs; then
        sudo ln -sf "$(command -v xorrisofs)" /usr/local/bin/mkisofs >>"$LOG_FILE" 2>&1 || true
        hash -r 2>/dev/null || true
        have_command mkisofs && return 0
    fi

    if have_command xorriso; then
        sudo ln -sf "$(command -v xorriso)" /usr/local/bin/mkisofs >>"$LOG_FILE" 2>&1 || true
        hash -r 2>/dev/null || true
        have_command mkisofs && return 0
    fi

    return 1
}

ensure_iso_tools() {
    if have_command mkisofs; then
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_status "warn" "mkisofs tidak ditemukan. Terraform apply akan gagal saat membuat cloud-init ISO."
        return 0
    fi

    print_status "warn" "mkisofs tidak ditemukan. Menyiapkan dependency untuk pembuatan cloud-init ISO..."

    if ! ensure_sudo_ready; then
        print_status "error" "Tidak dapat menjalankan sudo untuk install dependency (mkisofs/genisoimage)."
        print_status "info" "Install manual (Debian/Ubuntu): sudo apt-get update && sudo apt-get install -y genisoimage"
        print_status "info" "Lalu (jika mkisofs masih tidak ada): sudo ln -sf /usr/bin/genisoimage /usr/local/bin/mkisofs"
        return 1
    fi

    if have_command apt-get; then
        install_packages genisoimage || install_packages xorriso || true
    elif have_command dnf || have_command yum; then
        install_packages genisoimage || install_packages cdrtools || install_packages xorriso || true
    elif have_command zypper; then
        install_packages genisoimage || install_packages cdrtools || install_packages xorriso || true
    elif have_command pacman; then
        install_packages cdrtools || install_packages libisoburn || true
    elif have_command apk; then
        install_packages cdrkit || install_packages xorriso || true
    else
        print_status "error" "Package manager tidak dikenali. Install mkisofs/genisoimage secara manual."
        return 1
    fi

    ensure_mkisofs_available
    if ! have_command mkisofs; then
        print_status "error" "mkisofs masih tidak tersedia setelah instalasi dependency."
        return 1
    fi

    mkisofs --version >>"$LOG_FILE" 2>&1 || true
    print_status "success" "mkisofs tersedia: $(command -v mkisofs)"
    return 0
}

recover_libvirt_domain_exists() {
    local domain_name="$1"
    local addr="module.kvm_ubuntu.libvirt_domain.ubuntu_vm"

    if terraform state list 2>/dev/null | grep -qx "$addr"; then
        return 0
    fi

    if ! ensure_sudo_ready; then
        return 1
    fi

    if ! sudo virsh -c qemu:///system dominfo "$domain_name" >/dev/null 2>&1; then
        return 1
    fi

    local disk_path=""
    disk_path=$(sudo virsh -c qemu:///system dumpxml "$domain_name" 2>/dev/null | awk -F"'" '/<source file=/{print $2; exit}' || true)
    if [[ -n "$disk_path" ]] && [[ "$disk_path" != /var/lib/libvirt/images/k3s_infra_pool/* ]]; then
        print_status "error" "Refusing to modify existing domain '$domain_name' (disk path not in expected pool): $disk_path"
        return 1
    fi

    print_status "warn" "Domain '$domain_name' exists but not tracked in Terraform state. Cleaning up to allow retry..."
    sudo virsh -c qemu:///system destroy "$domain_name" >/dev/null 2>&1 || true
    sudo virsh -c qemu:///system undefine "$domain_name" --managed-save --nvram --snapshots-metadata >>"$LOG_FILE" 2>&1 || sudo virsh -c qemu:///system undefine "$domain_name" >>"$LOG_FILE" 2>&1 || true

    return 0
}

http_head_with_retry() {
    local url="$1"
    local retries="${2:-3}"
    local timeout_seconds="${3:-15}"

    local attempt=1
    while [[ $attempt -le $retries ]]; do
        if have_command curl; then
            if curl -fsSIL --connect-timeout "$timeout_seconds" --max-time "$timeout_seconds" "$url" >/dev/null 2>&1; then
                return 0
            fi
        elif have_command wget; then
            if wget --spider -q -T "$timeout_seconds" "$url" >/dev/null 2>&1; then
                return 0
            fi
        else
            return 2
        fi

        attempt=$((attempt + 1))
        sleep 2
    done

    return 1
}

verify_terraform_provider_connectivity() {
    print_status "info" "Checking Terraform provider registry connectivity..."

    if ! have_command curl && ! have_command wget; then
        print_status "warn" "curl/wget not found. Skipping HTTPS connectivity checks for Terraform providers."
        return 0
    fi

    local registry_url="https://registry.terraform.io/.well-known/terraform.json"
    local github_url="https://github.com"
    local libvirt_sha_url="https://github.com/dmacvicar/terraform-provider-libvirt/releases/download/v0.7.6/terraform-provider-libvirt_0.7.6_SHA256SUMS"

    local ok=true

    if ! http_head_with_retry "$registry_url" "$TF_PROVIDER_NET_RETRIES" "$TF_PROVIDER_NET_TIMEOUT_SECONDS"; then
        print_status "warn" "Cannot reach registry.terraform.io over HTTPS (provider discovery may fail)."
        ok=false
    else
        print_status "info" "✓ registry.terraform.io reachable"
    fi

    if ! http_head_with_retry "$github_url" "$TF_PROVIDER_NET_RETRIES" "$TF_PROVIDER_NET_TIMEOUT_SECONDS"; then
        print_status "warn" "Cannot reach github.com over HTTPS (community provider checksum fetch may fail)."
        ok=false
    else
        print_status "info" "✓ github.com reachable"
    fi

    if ! http_head_with_retry "$libvirt_sha_url" "$TF_PROVIDER_NET_RETRIES" "$TF_PROVIDER_NET_TIMEOUT_SECONDS"; then
        print_status "warn" "Cannot reach libvirt provider checksum URL (install may timeout)."
        ok=false
    else
        print_status "info" "✓ libvirt checksum URL reachable"
    fi

    if [[ "$ok" == "true" ]]; then
        return 0
    fi
    return 1
}

setup_terraform_runtime() {
    export TF_REGISTRY_CLIENT_TIMEOUT
    export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${PROJECT_ROOT}/.terraform.d/plugin-cache}"
    mkdir -p "$TF_PLUGIN_CACHE_DIR" 2>/dev/null || true
    chmod 700 "$TF_PLUGIN_CACHE_DIR" 2>/dev/null || true

    {
        echo "Terraform runtime env:"
        echo "- TF_REGISTRY_CLIENT_TIMEOUT=${TF_REGISTRY_CLIENT_TIMEOUT}"
        echo "- TF_PLUGIN_CACHE_DIR=${TF_PLUGIN_CACHE_DIR}"
        echo "- HTTP_PROXY set: $([[ -n \"${HTTP_PROXY:-}\" ]] && echo yes || echo no)"
        echo "- HTTPS_PROXY set: $([[ -n \"${HTTPS_PROXY:-}\" ]] && echo yes || echo no)"
        echo "- NO_PROXY set: $([[ -n \"${NO_PROXY:-}\" ]] && echo yes || echo no)"
    } >>"$LOG_FILE" 2>&1 || true
}

is_transient_provider_install_error() {
    local excerpt
    excerpt="$(tail -n 250 "$LOG_FILE" 2>/dev/null || true)"

    if echo "$excerpt" | grep -qiE "context deadline exceeded|TLS handshake timeout|i/o timeout|timeout|timed out|connection reset|temporary failure|network is unreachable|no route to host|EOF|502|503|504|429"; then
        return 0
    fi
    return 1
}

terraform_init_with_retry() {
    local upgrade_flag=""
    if [[ "${TF_INIT_UPGRADE}" == "true" ]]; then
        upgrade_flag="-upgrade"
    fi

    local attempt=1
    while [[ $attempt -le $TF_INIT_RETRIES ]]; do
        if terraform init -input=false $upgrade_flag >>"$LOG_FILE" 2>&1; then
            return 0
        fi

        local exit_code=$?
        if is_transient_provider_install_error && [[ $attempt -lt $TF_INIT_RETRIES ]]; then
            print_status "warn" "Terraform init gagal (kemungkinan network/transient). Retry $attempt/$TF_INIT_RETRIES..."
            sleep $((attempt * 5))
            attempt=$((attempt + 1))
            continue
        fi

        return "$exit_code"
    done

    return 1
}

# Fungsi: Rotasi Log
rotate_logs() {
    find "$LOG_DIR" -name "terraform-deployment-*.log" -mtime +7 -exec rm -f {} \; >> "$LOG_FILE" 2>&1 || true
}

# Fungsi: Validasi Prerequisites
check_prereqs() {
    if [ ! -f "$PROJECT_ROOT/main.tf" ]; then
        handle_error 1 "Check Root Directory (main.tf missing)"
    fi
    if [ ! -f "$VAR_FILE" ]; then
        handle_error 1 "Check Variable File ($VAR_FILE missing)"
    fi
    if ! command -v terraform &> /dev/null; then
        handle_error 1 "Check Terraform Command"
    fi
}

# Fungsi: Cleanup Partial Volumes
cleanup_partial_volumes() {
    print_status "info" "Cleaning up partial volumes..."
    
    local pool_name="k3s_infra_pool"
    
    # Get hostname from tfvars
    local hostname
    hostname=$(grep "^vm_hostname" "$VAR_FILE" | cut -d'"' -f2 | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    
    if [[ -z "$hostname" ]]; then
        print_status "warn" "Could not determine hostname for cleanup"
        return 1
    fi
    
    # List of volumes to check and clean
    local volumes=(
        "ubuntu-base-img-${hostname}.qcow2"
        "ubuntu-disk-${hostname}.qcow2"
        "cloudinit-${hostname}.iso"
    )
    
    for vol in "${volumes[@]}"; do
        if sudo virsh vol-info "$vol" --pool "$pool_name" &>/dev/null; then
            print_status "info" "Removing partial volume: $vol"
            sudo virsh vol-delete "$vol" --pool "$pool_name" 2>/dev/null || true
        fi
    done
    
    # Refresh pool
    sudo virsh pool-refresh "$pool_name" &>/dev/null || true
    
    print_status "success" "Partial volume cleanup complete"
}

# Fungsi: Import Existing Resources
import_existing_resources() {
    print_status "info" "Attempting to import existing resources..."
    
    local hostname
    hostname=$(grep "^vm_hostname" "$VAR_FILE" | cut -d'"' -f2 | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
    
    if [[ -z "$hostname" ]]; then
        print_status "warn" "Could not determine hostname for import"
        return 1
    fi
    
    # Check if domain exists in libvirt but not in Terraform state
    if sudo virsh dominfo "$hostname" &>/dev/null; then
        if ! terraform state list 2>/dev/null | grep -q "libvirt_domain.ubuntu_vm"; then
            print_status "info" "Importing existing domain: $hostname"
            terraform import \
                -var-file="$VAR_FILE" \
                "module.kvm_ubuntu.libvirt_domain.ubuntu_vm" \
                "$hostname" >> "$LOG_FILE" 2>&1 || {
                print_status "warn" "Failed to import domain (may not be critical)"
            }
        fi
    fi
    
    print_status "success" "Resource import check complete"
}

# Fungsi: Cleanup Failed Resources (Lanjutan)
cleanup_failed_resources() {
    print_status "info" "Cleaning up failed resources..."
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    
    # 1. Remove orphaned cloud-init ISOs
    print_status "info" "Removing orphaned cloud-init volumes..."
    sudo virsh vol-list "$pool_name" 2>/dev/null | grep "cloudinit-" | awk '{print $1}' | while read -r vol; do
        if [[ -n "$vol" ]]; then
            print_status "info" "  Removing: $vol"
            sudo virsh vol-delete "$vol" --pool "$pool_name" 2>/dev/null || true
        fi
    done
    
    # 2. Remove orphaned disk volumes (optional - hati-hati!)
    print_status "info" "Checking for orphaned disk volumes..."
    local orphaned_disks=$(sudo virsh vol-list "$pool_name" 2>/dev/null | grep "ubuntu-disk-" | awk '{print $1}')
    if [[ -n "$orphaned_disks" ]]; then
        print_status "warn" "Found orphaned disk volumes (not removing automatically):"
        echo "$orphaned_disks" | while read -r disk; do
            print_status "warn" "  - $disk"
        done
    fi
    
    # 3. Check for file-pool mismatch and clean
    print_status "info" "Checking for file-pool synchronization..."
    # Aktifkan nullglob untuk menangani pattern yang tidak cocok
    shopt -s nullglob
    
    local files_found=false
    local file_list=()

    # Kumpulkan semua file qcow2 dan iso
    for file in "$pool_path"/*.qcow2 "$pool_path"/*.iso; do
        if [[ -f "$file" ]]; then
            file_list+=("$file")
            files_found=true
        fi
    done

    # Proses file yang ditemukan
    if [[ "$files_found" == "true" ]]; then
        for file in "${file_list[@]}"; do
            local basename
            basename=$(basename "$file")
            
            if ! sudo virsh vol-list "$pool_name" 2>/dev/null | grep -q "$basename"; then
                print_status "warn" "File exists but not in pool metadata: $basename"
                print_status "info" "  Attempting to register with pool..."
                # Refresh pool akan mencoba sinkronisasi
            fi
        done
    else
        print_status "info" "No qcow2 or iso files found in pool directory"
    fi
    
    # Nonaktifkan nullglob setelah selesai
    shopt -u nullglob
    
    # 4. Refresh pool to sync
    print_status "info" "Refreshing storage pool..."
    sudo virsh pool-refresh "$pool_name" 2>/dev/null || {
        print_status "warn" "Pool refresh failed, attempting to restart pool..."
        sudo virsh pool-destroy "$pool_name" 2>/dev/null || true
        sleep 2
        sudo virsh pool-start "$pool_name" 2>/dev/null || true
        sudo virsh pool-refresh "$pool_name" 2>/dev/null || true
    }
    
    # 5. Display final state
    print_status "info" "Final pool state:"
    sudo virsh vol-list "$pool_name" 2>&1 | tee -a "$LOG_FILE"
    
    print_status "success" "Cleanup completed"
    return 0
}

# Fungsi: Deep Clean (untuk kasus ekstrem)
deep_clean_storage() {
    print_status "warn" "Performing DEEP CLEAN of storage pool..."
    print_status "warn" "This will remove ALL volumes in the pool!"
    
    local pool_name="k3s_infra_pool"
    local pool_path="/var/lib/libvirt/images/${pool_name}"
    
    # Confirm action
    read -p "Are you sure you want to continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "info" "Deep clean cancelled"
        return 1
    fi
    
    # Stop all VMs using volumes from this pool
    print_status "info" "Stopping VMs using pool volumes..."
    sudo virsh list --name | while read -r vm; do
        if [[ -n "$vm" ]]; then
            if sudo virsh domblklist "$vm" 2>/dev/null | grep -q "$pool_path"; then
                print_status "info" "  Stopping VM: $vm"
                sudo virsh destroy "$vm" 2>/dev/null || true
            fi
        fi
    done
    
    # Remove all volumes
    print_status "info" "Removing all volumes from pool..."
    sudo virsh vol-list "$pool_name" 2>/dev/null | tail -n +3 | awk '{print $1}' | while read -r vol; do
        if [[ -n "$vol" && "$vol" != "Name" ]]; then
            print_status "info" "  Deleting: $vol"
            sudo virsh vol-delete "$vol" --pool "$pool_name" 2>/dev/null || true
        fi
    done
    
    # Clean directory
    print_status "info" "Cleaning pool directory..."
    sudo rm -f "$pool_path"/*.qcow2 "$pool_path"/*.iso 2>/dev/null || true
    
    # Refresh pool
    sudo virsh pool-refresh "$pool_name" 2>/dev/null || true
    
    print_status "success" "Deep clean completed"
    return 0
}

# Fungsi: Verify Terraform State
verify_terraform_state() {
    print_status "info" "Verifying Terraform state..."
    
    # Check if state file exists
    if [[ ! -f "$PROJECT_ROOT/terraform.tfstate" ]]; then
        print_status "warn" "No Terraform state file found (fresh deployment)"
        return 0
    fi
    
    # Check for state lock
    if [[ -f "$PROJECT_ROOT/.terraform.tfstate.lock.info" ]]; then
        print_status "error" "Terraform state is locked!"
        print_status "info" "Lock info:"
        cat "$PROJECT_ROOT/.terraform.tfstate.lock.info" | tee -a "$LOG_FILE"
        
        read -p "Force remove lock? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            rm -f "$PROJECT_ROOT/.terraform.tfstate.lock.info"
            print_status "success" "Lock removed"
        else
            handle_error 1 "Terraform State Locked"
        fi
    fi
    
    # Validate state
    print_status "info" "Validating state integrity..."
    if terraform state list >> "$LOG_FILE" 2>&1; then
        local resource_count=$(terraform state list 2>/dev/null | wc -l)
        print_status "info" "Found $resource_count resources in state"
    else
        print_status "warn" "State validation failed (may be empty or corrupted)"
    fi
    
    print_status "success" "Terraform state verification completed"
    return 0
}

# Fungsi: Reconcile Libvirt State Drift
reconcile_libvirt_state() {
    print_status "info" "Reconciling Libvirt volumes with Terraform state..."

    if [[ "${DRY_RUN:-false}" == "true" ]] && ! sudo -n true >/dev/null 2>&1; then
        print_status "warn" "Skipping libvirt volume reconciliation (dry-run without passwordless sudo)"
        return 0
    fi

    if [[ ! -f "$PROJECT_ROOT/terraform.tfstate" ]]; then
        print_status "info" "No Terraform state file found, skipping reconciliation"
        return 0
    fi

    local pool_name="k3s_infra_pool"
    local targets

    targets=$(terraform state list 2>/dev/null | grep -E 'libvirt_cloudinit_disk\.commoninit$|libvirt_volume\.(ubuntu_base|ubuntu_base_img)$' || true)
    if [[ -z "$targets" ]]; then
        print_status "info" "No tracked libvirt volumes found in state, skipping reconciliation"
        return 0
    fi

    while read -r addr; do
        [[ -z "$addr" ]] && continue

        local vol_name
        vol_name=$(terraform state show -no-color "$addr" 2>/dev/null | awk -F'=' '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}')
        if [[ -z "$vol_name" ]]; then
            continue
        fi

        if ! sudo virsh vol-info "$vol_name" --pool "$pool_name" >/dev/null 2>&1; then
            print_status "warn" "State drift detected: $addr ($vol_name) missing in pool '$pool_name'. Removing from state..."
            terraform state rm "$addr" >> "$LOG_FILE" 2>&1 || {
                print_status "warn" "Failed to remove $addr from state (non-fatal)"
            }
        fi
    done <<< "$targets"

    print_status "success" "Libvirt state reconciliation completed"
    return 0
}

# Fungsi: Reconcile Libvirt Domain Drift
reconcile_libvirt_domain_state() {
    print_status "info" "Reconciling Libvirt domains with Terraform state..."

    if [[ "${DRY_RUN:-false}" == "true" ]] && ! sudo -n true >/dev/null 2>&1; then
        print_status "warn" "Skipping libvirt domain reconciliation (dry-run without passwordless sudo)"
        return 0
    fi

    if [[ ! -f "$PROJECT_ROOT/terraform.tfstate" ]]; then
        print_status "info" "No Terraform state file found, skipping domain reconciliation"
        return 0
    fi

    local domain_targets
    domain_targets=$(terraform state list 2>/dev/null | grep -E 'libvirt_domain\.ubuntu_vm$' || true)
    if [[ -n "$domain_targets" ]]; then
        while read -r addr; do
            [[ -z "$addr" ]] && continue

            local domain_name
            local domain_id

            domain_name=$(terraform state show -no-color "$addr" 2>/dev/null | awk -F'=' '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}')
            domain_id=$(terraform state show -no-color "$addr" 2>/dev/null | awk -F'=' '/^[[:space:]]*id[[:space:]]*=/{gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}')

            if [[ -n "$domain_id" ]] && sudo virsh dominfo "$domain_id" >/dev/null 2>&1; then
                continue
            fi

            if [[ -n "$domain_name" ]] && sudo virsh dominfo "$domain_name" >/dev/null 2>&1; then
                print_status "warn" "State drift detected: $addr references missing UUID but domain exists by name ($domain_name). Re-importing..."
                terraform state rm "$addr" >> "$LOG_FILE" 2>&1 || print_status "warn" "Failed to remove $addr from state (non-fatal)"
                terraform import -var-file="$VAR_FILE" "$addr" "$domain_name" >> "$LOG_FILE" 2>&1 || print_status "warn" "Failed to import $addr (non-fatal)"
                continue
            fi

            if terraform state list 2>/dev/null | grep -qx "$addr"; then
                print_status "warn" "State drift detected: $addr domain not found in libvirt. Removing from state to avoid delete failures..."
                terraform state rm "$addr" >> "$LOG_FILE" 2>&1 || print_status "warn" "Failed to remove $addr from state (non-fatal)"
            fi
        done <<< "$domain_targets"
    fi

    local hostname
    hostname=$(grep "^vm_hostname" "$VAR_FILE" | cut -d'"' -f2 | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-' || true)
    if [[ -z "$hostname" ]]; then
        print_status "warn" "Could not determine vm_hostname for domain reconciliation"
        return 0
    fi

    local addr="module.kvm_ubuntu.libvirt_domain.ubuntu_vm"
    if sudo virsh dominfo "$hostname" >/dev/null 2>&1 && ! terraform state list 2>/dev/null | grep -qx "$addr"; then
        print_status "warn" "Libvirt domain exists but is not tracked in Terraform state: $hostname"
        print_status "info" "Attempting to import domain into state..."

        if terraform import -var-file="$VAR_FILE" "$addr" "$hostname" >> "$LOG_FILE" 2>&1; then
            print_status "success" "Domain imported into state: $hostname"
            return 0
        fi

        print_status "warn" "Domain import failed. Attempting cleanup to allow recreation..."

        if sudo virsh dominfo "$hostname" >/dev/null 2>&1; then
            if sudo virsh domstate "$hostname" 2>/dev/null | grep -qi "running"; then
                print_status "info" "Stopping running domain to release disk locks: $hostname"
                sudo virsh destroy "$hostname" >> "$LOG_FILE" 2>&1 || true
                sleep 3
            fi

            sudo virsh undefine "$hostname" >> "$LOG_FILE" 2>&1 || true
            print_status "success" "Domain cleanup completed: $hostname"
        fi
    fi

    return 0
}

# Fungsi: Verify Kubeconfig Status
verify_kubeconfig_status() {
    print_status "info" "Verifying Kubernetes configuration status..."
    
    local kube_config_path="${PROJECT_ROOT}/kubeconfig"
    local default_kube_path="${HOME}/.kube/config"
    local k3s_kube_path="/etc/rancher/k3s/k3s.yaml"
    
    if [[ -n "${KUBECONFIG:-}" ]]; then
         print_status "info" "Using KUBECONFIG env var: $KUBECONFIG"
    elif [[ -f "$kube_config_path" ]]; then
        print_status "info" "Found local kubeconfig: $kube_config_path"
        # Check validity (basic check)
        if grep -q "current-context" "$kube_config_path"; then
             print_status "info" "  Config appears valid (has current-context)"
        else
             print_status "warn" "  Config might be invalid or incomplete"
        fi
    elif [[ -f "$default_kube_path" ]]; then
        print_status "info" "Found default kubeconfig: $default_kube_path"
    elif [[ -f "$k3s_kube_path" ]]; then
        print_status "info" "Found K3s kubeconfig: $k3s_kube_path"
    else
        print_status "info" "No existing kubeconfig found (expected for fresh install)"
    fi
    
    return 0
}

verify_kubernetes_apiserver_status() {
    print_status "info" "Checking Kubernetes API readiness..."

    local selected_kubeconfig
    selected_kubeconfig=$(kubeconfig_selected_path || true)
    if [[ -z "$selected_kubeconfig" ]] || [[ "$selected_kubeconfig" == "NOT_FOUND" ]]; then
        selected_kubeconfig="${PROJECT_ROOT}/kubeconfig"
    fi

    if [[ ! -f "$selected_kubeconfig" ]]; then
        print_status "warn" "No kubeconfig file found for readiness check: $selected_kubeconfig"
        return 0
    fi

    local server_url
    server_url=$(kubeconfig_server_url "$selected_kubeconfig" || true)
    if [[ -z "$server_url" ]]; then
        print_status "warn" "Kubeconfig missing server URL: $selected_kubeconfig"
        return 0
    fi

    print_status "info" "Using kubeconfig: $selected_kubeconfig"
    print_status "info" "API server: $server_url"

    if kubeconfig_is_dummy "$selected_kubeconfig"; then
        print_status "warn" "Kubeconfig is dummy (127.0.0.1). Skipping API readiness check."
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "warn" "kubectl not found. Skipping API readiness check."
        return 0
    fi

    if kube_apiserver_ready "$selected_kubeconfig"; then
        print_status "info" "✓ Kubernetes apiserver reports ready"
        KUBECONFIG="$selected_kubeconfig" kubectl get nodes -o wide 2>/dev/null | tee -a "$LOG_FILE" || true
    else
        print_status "warn" "Kubernetes apiserver not ready yet (this may be normal during bootstrap)"
    fi

    return 0
}

validate_ssh_authentication() {
    print_status "step" "Validating SSH authentication..."

    local validator="${PROJECT_ROOT}/scripts/validate_ssh_auth.sh"
    if [[ ! -f "$validator" ]]; then
        print_status "warn" "SSH validation script not found: $validator"
        return 0
    fi

    chmod +x "$validator" 2>/dev/null || true

    if "$validator" --tfvars "$VAR_FILE" --fix-known-hosts >>"$LOG_FILE" 2>&1; then
        print_status "success" "SSH authentication validated"
        return 0
    fi

    print_status "warn" "SSH authentication validation failed (non-critical). See: ./logs/.ssh_auth_validation.log"
    return 0
}

# Fungsi: Pre-deployment Checks (Comprehensive)
comprehensive_preflight_checks() {
    print_status "step" "Comprehensive Pre-flight Checks"
    
    export PREFLIGHT_CRITICAL_FAILURE=false

    local checks_passed=true
    local sudo_noninteractive_ok=true
    if [[ "${DRY_RUN:-false}" == "true" ]] && ! sudo -n true >/dev/null 2>&1; then
        sudo_noninteractive_ok=false
        print_status "warn" "Dry-run without passwordless sudo. Skipping libvirt pool/volume checks."
    fi
    
    # 1. System Requirements
    print_status "info" "Checking system requirements..."
    
    # Check available memory
    local free_mem=$(free -m | awk '/^Mem:/{print $7}')
    if [[ $free_mem -lt 2048 ]]; then
        print_status "warn" "Low available memory: ${free_mem}MB (recommended: 2048MB+)"
    else
        print_status "info" "✓ Available memory: ${free_mem}MB"
    fi
    
    # Check available disk space
    local free_disk=$(df -BG /var/lib/libvirt/images 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "0")
    if [[ $free_disk -lt 20 ]]; then
        print_status "warn" "Low disk space: ${free_disk}GB (recommended: 20GB+)"
    else
        print_status "info" "✓ Available disk space: ${free_disk}GB"
    fi
    
    # 2. Libvirt Service
    print_status "info" "Checking libvirt service..."
    if systemctl is-active --quiet libvirtd; then
        print_status "info" "✓ Libvirt service is running"
    else
        print_status "error" "Libvirt service is not running"
        print_status "info" "Attempting to start libvirt..."
        if [[ "$sudo_noninteractive_ok" == "true" ]]; then
            sudo systemctl start libvirtd || {
                print_status "error" "Failed to start libvirt service"
                checks_passed=false
            }
        else
            print_status "warn" "Cannot start libvirt service without sudo (dry-run)."
            checks_passed=false
        fi
    fi
    
    # 3. Network Connectivity
    print_status "info" "Checking network connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        print_status "info" "✓ Network connectivity OK"
    else
        print_status "warn" "Network connectivity issue detected"
    fi

    verify_terraform_provider_connectivity || true
    
    # 4. Terraform Version
    print_status "info" "Checking Terraform version..."
    local tf_version=$(terraform version 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")
    print_status "info" "✓ Terraform version: $tf_version"

    if ! ensure_iso_tools; then
        export PREFLIGHT_CRITICAL_FAILURE=true
        print_status "error" "Critical pre-flight check failed"
        return 1
    fi

    if ! ensure_apparmor_virt_aa_helper_can_write_files; then
        export PREFLIGHT_CRITICAL_FAILURE=true
        print_status "error" "Critical pre-flight check failed"
        return 1
    fi
    
    # 5. Required Terraform Providers
    print_status "info" "Checking Terraform providers..."
    if [[ -d "$PROJECT_ROOT/.terraform/providers" ]]; then
        print_status "info" "✓ Terraform providers initialized"
    else
        print_status "warn" "Terraform providers not initialized (will be done in init step)"
    fi
    
    if [[ "$sudo_noninteractive_ok" == "true" ]]; then
        # 6. Storage Pool
        verify_libvirt_pool || checks_passed=false
        
        # 7. Storage Volumes
        verify_storage_volumes || checks_passed=false
        
        # 8. NEW: Ensure pool is ready for volume creation
        ensure_pool_ready_for_volumes || checks_passed=false
        fix_volume_permissions || checks_passed=false
        
        # 9. NEW: Pre-check base image volume
        precreate_and_fix_base_image_volume || checks_passed=false
    fi
    
    # 10. NEW: Verify network connectivity
    verify_network_for_download || checks_passed=false

    # 11. Terraform State
    verify_terraform_state || checks_passed=false
    
    # 12. Kubernetes Configuration
    verify_kubeconfig_status || checks_passed=false
    verify_kubernetes_apiserver_status || checks_passed=false
    
    if [[ "$checks_passed" == "true" ]]; then
        print_status "success" "All pre-flight checks passed ✓"
        return 0
    fi

    print_status "warn" "Some pre-flight checks completed with warnings"
    return 0
}

# Fungsi: Post-deployment Verification
post_deployment_verification() {
    print_status "step" "Post-deployment Verification"
    
    local pool_name="k3s_infra_pool"
    
    # 1. Verify VMs are running
    print_status "info" "Checking VM status..."
    local vm_count=$(sudo virsh list --name 2>/dev/null | grep -c "k3s-" || echo "0")
    print_status "info" "Found $vm_count running VMs"
    
    if [[ $vm_count -gt 0 ]]; then
        print_status "info" "Running VMs:"
        sudo virsh list --all | grep "k3s-" | tee -a "$LOG_FILE"
    fi
    
    # 2. Verify volumes are attached
    print_status "info" "Verifying volume attachments..."
    sudo virsh list --name 2>/dev/null | grep "k3s-" | while read -r vm; do
        if [[ -n "$vm" ]]; then
            print_status "info" "Volumes for VM: $vm"
            sudo virsh domblklist "$vm" 2>/dev/null | tee -a "$LOG_FILE"
        fi
    done
    
    # 3. Check VM network connectivity
    print_status "info" "Checking VM network configuration..."
    sudo virsh list --name 2>/dev/null | grep "k3s-" | while read -r vm; do
        if [[ -n "$vm" ]]; then
            print_status "info" "Network interfaces for VM: $vm"
            sudo virsh domiflist "$vm" 2>/dev/null | tee -a "$LOG_FILE"
        fi
    done
    
    # 4. Verify cloud-init ISOs
    print_status "info" "Verifying cloud-init ISOs..."
    local cloudinit_count=$(sudo virsh vol-list "$pool_name" 2>/dev/null | grep -c "cloudinit-" || echo "0")
    print_status "info" "Found $cloudinit_count cloud-init ISO(s)"
    
    # 5. Check Terraform outputs
    print_status "info" "Verifying Terraform outputs..."
    if terraform output &>/dev/null; then
        print_status "success" "Terraform outputs available"
    else
        print_status "warn" "No Terraform outputs found"
    fi

    if ! verify_n8n_kubernetes_workloads; then
        if [[ "${ROLLBACK_N8N_ON_FAILURE:-false}" == "true" ]]; then
            print_status "warn" "Rollback n8n resources enabled. Attempting terraform destroy -target=kubectl_manifest.n8n..."
            terraform destroy -var-file="$VAR_FILE" -auto-approve -target="kubectl_manifest.n8n" 2>&1 | tee -a "$LOG_FILE" || true
        fi
        return 1
    fi
    
    print_status "success" "Post-deployment verification completed"
    return 0
}

# Fungsi: Verify n8n Kubernetes Workloads and Collect Diagnostics
verify_n8n_kubernetes_workloads() {
    print_status "info" "Checking n8n Kubernetes workloads..."

    local selected_kubeconfig
    selected_kubeconfig=$(kubeconfig_selected_path || true)
    if [[ -z "$selected_kubeconfig" ]] || [[ "$selected_kubeconfig" == "NOT_FOUND" ]]; then
        selected_kubeconfig="${PROJECT_ROOT}/kubeconfig"
    fi

    if [[ ! -f "$selected_kubeconfig" ]]; then
        print_status "warn" "No kubeconfig file found for workload checks: $selected_kubeconfig"
        return 0
    fi

    if kubeconfig_is_dummy "$selected_kubeconfig"; then
        print_status "warn" "Kubeconfig is dummy (127.0.0.1). Skipping workload checks."
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        print_status "warn" "kubectl not found. Skipping workload checks."
        return 0
    fi

    local ns="n8n"

    print_status "info" "Pod summary (namespace: $ns):"
    KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" -o wide 2>&1 | tee -a "$LOG_FILE" || {
        print_status "warn" "Failed to query pods in namespace $ns (non-critical)"
        return 0
    }

    print_status "info" "Node labels (workload=n8n):"
    KUBECONFIG="$selected_kubeconfig" kubectl get nodes -l workload=n8n -o wide 2>&1 | tee -a "$LOG_FILE" || true

    local n8n_nodes=""
    n8n_nodes=$(KUBECONFIG="$selected_kubeconfig" kubectl get nodes -l workload=n8n --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    if [[ -z "$n8n_nodes" ]]; then
        print_status "warn" "No nodes labeled workload=n8n. n8n pods may schedule onto undesired nodes."

        local candidate_nodes=""
        candidate_nodes=$(KUBECONFIG="$selected_kubeconfig" kubectl get nodes --no-headers 2>/dev/null | awk '$1 ~ /^n8n-worker-/ {print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
        if [[ -n "$candidate_nodes" ]]; then
            print_status "info" "Auto-labeling candidate nodes with workload=n8n: $candidate_nodes"
            for node in $candidate_nodes; do
                KUBECONFIG="$selected_kubeconfig" kubectl label node "$node" workload=n8n --overwrite 2>&1 | tee -a "$LOG_FILE" || true
            done
        fi

        n8n_nodes=$(KUBECONFIG="$selected_kubeconfig" kubectl get nodes -l workload=n8n --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)
    fi

    print_status "info" "n8n pod distribution by node:"
    local pod_wide=""
    pod_wide=$(KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" -o wide --no-headers 2>/dev/null || true)
    if [[ -n "$pod_wide" ]]; then
        echo "$pod_wide" | pod_nodes_from_kubectl_wide | summarize_node_counts | tee -a "$LOG_FILE" || true
    else
        echo "No pods found in namespace $ns" | tee -a "$LOG_FILE"
    fi

    local n8n_wait_timeout="${N8N_WAIT_TIMEOUT:-1800s}"
    local n8n_wait_timeout_seconds
    n8n_wait_timeout_seconds=$(parse_duration_seconds "$n8n_wait_timeout")

    local node_stability_timeout="${N8N_NODE_STABILITY_TIMEOUT:-300s}"
    local node_stability_timeout_seconds
    node_stability_timeout_seconds=$(parse_duration_seconds "$node_stability_timeout")

    if [[ -n "$n8n_nodes" ]] && [[ "$node_stability_timeout_seconds" -gt 0 ]]; then
        print_status "info" "Ensuring n8n nodes are stable (Ready, no unreachable taint) before waiting for pods..."
        local stability_start
        stability_start=$(date +%s)
        while true; do
            local stable_count=0
            for node in $n8n_nodes; do
                if node_is_ready "$selected_kubeconfig" "$node" && ! node_has_unreachable_taint "$selected_kubeconfig" "$node"; then
                    stable_count=$((stable_count + 1))
                else
                    if ! node_is_ready "$selected_kubeconfig" "$node"; then
                        print_status "warn" "Node is not Ready: $node"
                    fi
                    if node_has_unreachable_taint "$selected_kubeconfig" "$node"; then
                        print_status "warn" "Node has unreachable taint: $node"
                    fi
                fi
            done
            if [[ "$stable_count" -gt 0 ]]; then
                break
            fi
            local now
            now=$(date +%s)
            if [[ $((now - stability_start)) -ge "$node_stability_timeout_seconds" ]]; then
                print_status "error" "No stable nodes labeled workload=n8n. Aborting readiness wait."
                for node in $n8n_nodes; do
                    KUBECONFIG="$selected_kubeconfig" kubectl describe node "$node" 2>&1 | tee -a "$LOG_FILE" || true
                done
                return 1
            fi
            sleep 10
        done
    fi

    ensure_n8n_deployments_scaled_up "$selected_kubeconfig" "$ns" || true

    print_status "info" "Waiting for n8n pods to become Ready (timeout: $n8n_wait_timeout)..."
    if ! wait_for_n8n_pods_ready "$selected_kubeconfig" "$ns" "$n8n_wait_timeout_seconds"; then
        print_status "warn" "n8n pods did not become Ready within timeout. Collecting diagnostics..."

        print_status "info" "PVC status (namespace: $ns):"
        KUBECONFIG="$selected_kubeconfig" kubectl get pvc -n "$ns" -o wide 2>&1 | tee -a "$LOG_FILE" || true

        print_status "info" "StorageClasses:"
        KUBECONFIG="$selected_kubeconfig" kubectl get storageclass -o wide 2>&1 | tee -a "$LOG_FILE" || true

        local pending_pvcs=""
        pending_pvcs=$(KUBECONFIG="$selected_kubeconfig" kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '$2!="Bound"{print $1}' | head -n 50 || true)
        while read -r pvc; do
            [[ -z "$pvc" ]] && continue
            print_status "info" "Describe PVC: $pvc"
            KUBECONFIG="$selected_kubeconfig" kubectl describe pvc -n "$ns" "$pvc" 2>&1 | tee -a "$LOG_FILE" || true
        done <<< "$pending_pvcs"

        print_status "info" "Recent events (namespace: $ns):"
        local events_tail=""
        events_tail=$(KUBECONFIG="$selected_kubeconfig" kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -n 120 || true)
        echo "$events_tail" | tee -a "$LOG_FILE" || true

        if echo "$events_tail" | log_contains_containerd_name_reservation_issue; then
            print_status "error" "Detected container runtime name reservation issue (containerd). Pods may stay in CreateContainerError."
            print_status "info" "Impacted pods (CreateContainerError):"
            KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" -o wide --no-headers 2>/dev/null \
                | awk '$3 ~ /CreateContainerError/ {print $1 "  node=" $7 "  ip=" $6}' \
                | tee -a "$LOG_FILE" || true
            print_status "info" "Remediation (run on the affected node, e.g. n8n-worker-1):"
            echo "  sudo systemctl restart k3s-agent" | tee -a "$LOG_FILE"
            echo "  sudo k3s crictl ps -a | grep -i n8n || true" | tee -a "$LOG_FILE"
            echo "  sudo k3s crictl pods -a | grep -i n8n || true" | tee -a "$LOG_FILE"
        fi

        print_status "info" "Deployment details (namespace: $ns):"
        for dep in n8n-main n8n-worker n8n-webhook; do
            KUBECONFIG="$selected_kubeconfig" kubectl describe deployment -n "$ns" "$dep" 2>&1 | tee -a "$LOG_FILE" || true
        done

        if [[ -n "$n8n_nodes" ]]; then
            print_status "info" "Node details for workload=n8n:"
            for node in $n8n_nodes; do
                KUBECONFIG="$selected_kubeconfig" kubectl describe node "$node" 2>&1 | tee -a "$LOG_FILE" || true
            done
        fi

        local not_ready_pods=""
        not_ready_pods=$(KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | pods_not_fully_ready_from_kubectl_get_noheaders | head -n 50 || true)
        while read -r pod; do
            [[ -z "$pod" ]] && continue
            print_status "info" "Describe pod: $pod"
            KUBECONFIG="$selected_kubeconfig" kubectl describe pod -n "$ns" "$pod" 2>&1 | tee -a "$LOG_FILE" || true

            if pod_container_has_started_or_terminated "$selected_kubeconfig" "$ns" "$pod" "n8n"; then
                print_status "info" "Logs (tail=200): $pod"
                KUBECONFIG="$selected_kubeconfig" kubectl logs -n "$ns" "$pod" --all-containers=true --tail=200 2>&1 | tee -a "$LOG_FILE" || true
            else
                print_status "info" "Logs not available yet (container not started): $pod"
            fi

            if pod_container_has_previous_logs "$selected_kubeconfig" "$ns" "$pod" "n8n"; then
                print_status "info" "Previous logs (tail=200): $pod"
                KUBECONFIG="$selected_kubeconfig" kubectl logs -n "$ns" "$pod" --all-containers=true --previous --tail=200 2>&1 | tee -a "$LOG_FILE" || true
            else
                print_status "info" "Previous logs not available: $pod"
            fi
        done <<< "$not_ready_pods"

        return 1
    fi

    local bad_pods=""
    bad_pods=$(KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" --no-headers 2>/dev/null \
        | awk '$3 ~ /(CreateContainerError|CreateContainerConfigError|CrashLoopBackOff|ErrImagePull|ImagePullBackOff)/ {print $1}' \
        | head -n 50 || true)

    if [[ -z "$bad_pods" ]]; then
        print_status "success" "n8n workloads look healthy"
        return 0
    fi

    print_status "warn" "Found failing n8n pods. Collecting diagnostics to log..."
    while read -r pod; do
        [[ -z "$pod" ]] && continue
        print_status "info" "Describe pod: $pod"
        KUBECONFIG="$selected_kubeconfig" kubectl describe pod -n "$ns" "$pod" 2>&1 | tee -a "$LOG_FILE" || true

        if pod_container_has_started_or_terminated "$selected_kubeconfig" "$ns" "$pod" "n8n"; then
            print_status "info" "Logs (tail=200): $pod"
            KUBECONFIG="$selected_kubeconfig" kubectl logs -n "$ns" "$pod" --all-containers=true --tail=200 2>&1 | tee -a "$LOG_FILE" || true
        else
            print_status "info" "Logs not available yet (container not started): $pod"
        fi

        if pod_container_has_previous_logs "$selected_kubeconfig" "$ns" "$pod" "n8n"; then
            print_status "info" "Previous logs (tail=200): $pod"
            KUBECONFIG="$selected_kubeconfig" kubectl logs -n "$ns" "$pod" --all-containers=true --previous --tail=200 2>&1 | tee -a "$LOG_FILE" || true
        else
            print_status "info" "Previous logs not available: $pod"
        fi
    done <<< "$bad_pods"

    return 1
}

pod_nodes_from_kubectl_wide() {
    awk '{print $7}'
}

summarize_node_counts() {
    awk 'NF>0{c[$1]++} END{for (n in c) printf "%s %d\n", n, c[n]}' | sort
}

log_contains_containerd_name_reservation_issue() {
    grep -qiE 'failed to reserve container name|is reserved for'
}

pods_not_fully_ready_from_kubectl_get_noheaders() {
    awk '{
        split($2, a, "/")
        if (a[1] != a[2]) print $1
    }'
}

parse_duration_seconds() {
    local v="${1:-}"
    if [[ -z "$v" ]]; then
        echo 0
        return 0
    fi
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "$v"
        return 0
    fi
    if [[ "$v" =~ ^[0-9]+s$ ]]; then
        echo "${v%s}"
        return 0
    fi
    if [[ "$v" =~ ^[0-9]+m$ ]]; then
        echo $(( ${v%m} * 60 ))
        return 0
    fi
    if [[ "$v" =~ ^[0-9]+h$ ]]; then
        echo $(( ${v%h} * 3600 ))
        return 0
    fi
    echo 0
    return 0
}

node_has_unreachable_taint() {
    local kubeconfig_path="$1"
    local node_name="$2"
    local taints=""
    taints=$(KUBECONFIG="$kubeconfig_path" kubectl get node "$node_name" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}' 2>/dev/null || true)
    echo "$taints" | grep -q "^node.kubernetes.io/unreachable:NoExecute$"
}

node_is_ready() {
    local kubeconfig_path="$1"
    local node_name="$2"
    local ready=""
    ready=$(KUBECONFIG="$kubeconfig_path" kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" == "True" ]]
}

pod_container_has_started_or_terminated() {
    local kubeconfig_path="$1"
    local ns="$2"
    local pod="$3"
    local container="${4:-n8n}"

    local running=""
    local terminated=""
    running=$(KUBECONFIG="$kubeconfig_path" kubectl get pod -n "$ns" "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.running.startedAt}" 2>/dev/null || true)
    terminated=$(KUBECONFIG="$kubeconfig_path" kubectl get pod -n "$ns" "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].state.terminated.exitCode}" 2>/dev/null || true)
    [[ -n "$running" || -n "$terminated" ]]
}

pod_container_has_previous_logs() {
    local kubeconfig_path="$1"
    local ns="$2"
    local pod="$3"
    local container="${4:-n8n}"

    local last_terminated=""
    last_terminated=$(KUBECONFIG="$kubeconfig_path" kubectl get pod -n "$ns" "$pod" -o jsonpath="{.status.containerStatuses[?(@.name=='$container')].lastState.terminated.exitCode}" 2>/dev/null || true)
    [[ -n "$last_terminated" ]]
}

n8n_get_deployment_replicas() {
    local kubeconfig_path="$1"
    local ns="$2"
    local dep="$3"
    KUBECONFIG="$kubeconfig_path" kubectl get deployment -n "$ns" "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

n8n_any_deployments_exist() {
    local kubeconfig_path="$1"
    local ns="$2"
    local count="0"
    count=$(KUBECONFIG="$kubeconfig_path" kubectl get deployment -n "$ns" -l app=n8n --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    [[ "$count" -gt 0 ]]
}

ensure_n8n_deployments_scaled_up() {
    local kubeconfig_path="$1"
    local ns="$2"

    if ! n8n_any_deployments_exist "$kubeconfig_path" "$ns"; then
        return 0
    fi

    local auto_scale="${N8N_AUTO_SCALE_UP_ON_ZERO:-true}"
    if [[ "$auto_scale" != "true" ]]; then
        return 0
    fi

    local main_replicas="${N8N_MAIN_REPLICAS:-1}"
    local webhook_replicas="${N8N_WEBHOOK_REPLICAS:-1}"
    local worker_replicas="${N8N_WORKER_REPLICAS:-1}"

    local scaled_any="false"

    local current=""
    current=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-main")
    if [[ "$current" == "0" ]] && [[ "$main_replicas" != "0" ]]; then
        print_status "warn" "n8n-main replicas=0. Scaling up to $main_replicas..."
        KUBECONFIG="$kubeconfig_path" kubectl scale deployment -n "$ns" n8n-main --replicas="$main_replicas" 2>&1 | tee -a "$LOG_FILE" || true
        scaled_any="true"
    fi

    current=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-webhook")
    if [[ "$current" == "0" ]] && [[ "$webhook_replicas" != "0" ]]; then
        print_status "warn" "n8n-webhook replicas=0. Scaling up to $webhook_replicas..."
        KUBECONFIG="$kubeconfig_path" kubectl scale deployment -n "$ns" n8n-webhook --replicas="$webhook_replicas" 2>&1 | tee -a "$LOG_FILE" || true
        scaled_any="true"
    fi

    current=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-worker")
    if [[ "$current" == "0" ]] && [[ "$worker_replicas" != "0" ]]; then
        print_status "warn" "n8n-worker replicas=0. Scaling up to $worker_replicas..."
        KUBECONFIG="$kubeconfig_path" kubectl scale deployment -n "$ns" n8n-worker --replicas="$worker_replicas" 2>&1 | tee -a "$LOG_FILE" || true
        scaled_any="true"
    fi

    if [[ "$scaled_any" == "true" ]]; then
        sleep 3
    fi

    return 0
}

wait_for_n8n_pods_ready() {
    local kubeconfig_path="$1"
    local ns="$2"
    local timeout_seconds="$3"

    local start_ts
    start_ts=$(date +%s)
    local poll_seconds="${N8N_WAIT_POLL_SECONDS:-10}"
    local max_poll_seconds="${N8N_WAIT_MAX_POLL_SECONDS:-60}"
    local no_pods_grace_seconds="${N8N_NO_PODS_GRACE_SECONDS:-120}"

    while true; do
        local now_ts
        now_ts=$(date +%s)
        local elapsed=$((now_ts - start_ts))
        if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
            return 1
        fi

        local pod_lines=""
        pod_lines=$(KUBECONFIG="$kubeconfig_path" kubectl get pods -n "$ns" -l app=n8n -o wide --no-headers 2>/dev/null || true)
        if [[ -z "$pod_lines" ]]; then
            if [[ "$elapsed" -ge "$no_pods_grace_seconds" ]]; then
                if n8n_any_deployments_exist "$kubeconfig_path" "$ns"; then
                    ensure_n8n_deployments_scaled_up "$kubeconfig_path" "$ns" || true
                    local main_repl=""
                    local webhook_repl=""
                    local worker_repl=""
                    main_repl=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-main")
                    webhook_repl=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-webhook")
                    worker_repl=$(n8n_get_deployment_replicas "$kubeconfig_path" "$ns" "n8n-worker")
                    if [[ "$main_repl" == "0" ]] && [[ "$webhook_repl" == "0" ]] && [[ "$worker_repl" == "0" ]]; then
                        return 1
                    fi
                else
                    return 1
                fi
            fi
            sleep "$poll_seconds"
            continue
        fi

        local not_ready=""
        not_ready=$(echo "$pod_lines" | pods_not_fully_ready_from_kubectl_get_noheaders | head -n 50 || true)
        if [[ -z "$not_ready" ]]; then
            return 0
        fi

        if ((elapsed % 60 == 0)); then
            echo "$pod_lines" | tee -a "$LOG_FILE" >/dev/null || true
        fi

        sleep "$poll_seconds"
        poll_seconds=$((poll_seconds * 3 / 2 ))
        if [[ "$poll_seconds" -gt "$max_poll_seconds" ]]; then
            poll_seconds="$max_poll_seconds"
        fi
    done
}

# Fungsi: Classify Terraform apply failure by log content
classify_terraform_apply_failure() {
    local log_file="$1"

    local recent=""
    recent=$(awk '{a[NR]=$0} /Apply attempt [0-9]+\/[0-9]+/{p=NR} END{if(p==0)p=1; for(i=p;i<=NR;i++) print a[i]}' "$log_file" 2>/dev/null || true)
    if [[ -z "$recent" ]]; then
        recent=$(tail -n 400 "$log_file" 2>/dev/null || true)
    fi

    if echo "$recent" | grep -q 'exec: "mkisofs": executable file not found in \$PATH' || echo "$recent" | grep -qiE 'mkisofs.*(not found|not in \$PATH)'; then
        echo "mkisofs_missing"
        return 0
    fi

    if echo "$recent" | grep -qiE "qemu-system-.*Could not open '.*\.qcow2': Permission denied|Could not open '.*\.qcow2': Permission denied"; then
        echo "libvirt_image_permission_denied"
        return 0
    fi

    if echo "$recent" | grep -qiE "domain '.*' already exists with uuid"; then
        echo "libvirt_domain_exists"
        return 0
    fi

    if echo "$recent" | grep -q "timeout while waiting for state to become 'EXISTS'"; then
        echo "volume_timeout"
        return 0
    fi

    if echo "$recent" | grep -q "exists already" && echo "$recent" | grep -q "libvirt_cloudinit_disk"; then
        echo "cloudinit_exists"
        return 0
    fi

    if echo "$recent" | grep -q "Apply failed with 1 conflict" && echo "$recent" | grep -q "conflict"; then
        echo "k8s_ssa_conflict"
        return 0
    fi

    if echo "$recent" | grep -q "no domain with matching uuid" || echo "$recent" | grep -q "retrieving libvirt domain by delete"; then
        echo "libvirt_domain_uuid_stale"
        return 0
    fi

    if echo "$recent" | grep -q "already exists"; then
        echo "resource_exists"
        return 0
    fi

    echo "unknown"
    return 0
}

# Fungsi: Terraform Apply with Retry and Better Error Handling
terraform_apply_with_retry() {
    local max_retries=3
    local retry_count=0
    local success=false

    print_status "info" "Starting Terraform apply with retry logic..."
    
    while [[ $retry_count -lt $max_retries ]]; do
        print_status "info" "Apply attempt $((retry_count + 1))/$max_retries"

        if [[ $retry_count -gt 0 ]]; then
            print_status "info" "Recreating Terraform plan for retry..."
            local selected_kubeconfig
            selected_kubeconfig=$(kubeconfig_selected_path || true)
            if [[ -z "$selected_kubeconfig" ]] || [[ "$selected_kubeconfig" == "NOT_FOUND" ]]; then
                selected_kubeconfig="${PROJECT_ROOT}/kubeconfig"
            fi

            local plan_refresh_arg=""
            if ! kube_apiserver_ready "$selected_kubeconfig"; then
                plan_refresh_arg="-refresh=false"
                print_status "warn" "Kubernetes apiserver belum siap atau kubeconfig masih dummy. Menjalankan plan retry tanpa refresh."
            fi

            terraform plan $plan_refresh_arg \
                -var-file="$VAR_FILE" \
                -out="$PLAN_FILE" \
                -input=false \
                -compact-warnings >> "$LOG_FILE" 2>&1 || {
                print_status "error" "Terraform plan failed during retry"
                return 1
            }
        fi
        
        if terraform apply \
            -var-file="$VAR_FILE" \
            -auto-approve \
            -parallelism="$TF_PARALLELISM" \
            "$PLAN_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            
            success=true
            print_status "success" "Terraform apply completed successfully"
            break
        else
            local exit_code=$?
            ((retry_count++))
            
            print_status "error" "Terraform apply failed (attempt $retry_count/$max_retries)"
            
            if [[ $retry_count -lt $max_retries ]]; then
                print_status "info" "Analyzing failure and preparing retry..."
                
                local failure_kind=""
                failure_kind=$(classify_terraform_apply_failure "$LOG_FILE")

                case "$failure_kind" in
                    mkisofs_missing)
                        print_status "error" "Dependency mkisofs tidak tersedia untuk membuat cloud-init ISO"
                        if ! ensure_iso_tools; then
                            print_status "error" "Gagal menyiapkan mkisofs. Hentikan retry karena tidak akan berhasil tanpa dependency."
                            return 1
                        fi
                        sleep 2
                        ;;

                    libvirt_image_permission_denied)
                        print_status "error" "Detected permission denied saat QEMU membuka disk image"
                        local backing=""
                        backing=$(grep -oE "/var/lib/libvirt/images/[^']+\.qcow2" "$LOG_FILE" | tail -n 1 || true)
                        if [[ -n "$backing" ]]; then
                            audit_libvirt_storage_path "$backing"
                        fi
                        local inferred_domain=""
                        inferred_domain=$(infer_domain_name_from_storage_path "$backing" || true)
                        cleanup_libvirt_domain_if_safe "$inferred_domain" || true
                        ensure_apparmor_virt_aa_helper_can_write_files || true
                        fix_libvirt_storage_permissions || true
                        sleep 5
                        ;;

                    libvirt_domain_exists)
                        print_status "warn" "Detected libvirt domain already exists"
                        local domain_name=""
                        domain_name=$(grep -oE "domain '[^']+' already exists" "$LOG_FILE" | tail -n 1 | sed -E "s/^domain '([^']+)'.*/\1/" || true)
                        [[ -z "$domain_name" ]] && domain_name="k3s-master-01"
                        recover_libvirt_domain_exists "$domain_name" || true
                        sleep 3
                        ;;
                    volume_timeout)
                        print_status "warn" "Detected volume creation timeout"
                        print_status "info" "Cleaning up partial resources..."
                        cleanup_partial_volumes

                        local wait_time=$((retry_count * 30))
                        print_status "info" "Waiting ${wait_time}s before retry..."
                        sleep "$wait_time"
                        ;;

                    cloudinit_exists)
                        print_status "warn" "Detected existing cloudinit volume conflict"
                        print_status "info" "Attempting to remove conflicting cloudinit volumes..."

                        local pool_name="k3s_infra_pool"
                        local vol_name=""
                        vol_name=$(grep -o "cloudinit-[a-zA-Z0-9-]*\.iso" "$LOG_FILE" | tail -1 || true)

                        if [[ -n "$vol_name" ]]; then
                            print_status "info" "Removing specific volume: $vol_name"
                            sudo virsh vol-delete "$vol_name" --pool "$pool_name" 2>/dev/null || true
                        else
                            print_status "info" "Could not extract volume name, running general cleanup..."
                            cleanup_failed_resources
                        fi

                        print_status "info" "Refreshing pool..."
                        sudo virsh pool-refresh "$pool_name" 2>/dev/null || true
                        ;;

                    k8s_ssa_conflict)
                        print_status "warn" "Detected Kubernetes Server-Side Apply conflict"
                        print_status "info" "This usually means a field is managed by another controller (e.g., kubectl-set)."
                        print_status "info" "Use 'force_conflicts = true' in kubectl_manifest to make Terraform the manager."
                        sleep 5
                        ;;

                    resource_exists)
                        print_status "warn" "Detected resource conflict"
                        print_status "info" "Attempting to import existing resources..."
                        import_existing_resources
                        ;;

                    libvirt_domain_uuid_stale)
                        print_status "warn" "Detected stale libvirt domain UUID in Terraform state"
                        print_status "info" "Reconciling domain drift and preparing retry..."
                        reconcile_libvirt_domain_state
                        reconcile_libvirt_state
                        sleep 10
                        ;;

                    *)
                        print_status "warn" "Unknown error, waiting before retry..."
                        sleep 15
                        ;;
                esac
                
                if grep -q "Saved plan is stale" "$LOG_FILE"; then
                    print_status "warn" "Saved plan is stale. A new plan will be generated on the next retry."
                fi

                # Refresh Terraform state
                print_status "info" "Refreshing Terraform state..."
                terraform refresh -var-file="$VAR_FILE" >> "$LOG_FILE" 2>&1 || true
                
            else
                print_status "error" "Maximum retry attempts reached"
                print_status "error" "Deployment failed after $max_retries attempts"
                return 1
            fi
        fi
    done
    
    if [[ "$success" == true ]]; then
        return 0
    else
        return 1
    fi
}

# Fungsi: Cleanup Existing Domains
cleanup_existing_domains() {
    print_status "info" "Cleaning up existing domains..."
    
    local pool_name="k3s_infra_pool"
    
    # Find and destroy existing k3s VMs
    sudo virsh list --all --name 2>/dev/null | grep "k3s-" | while read -r vm; do
        if [[ -n "$vm" ]]; then
            print_status "info" "Processing VM: $vm"
            
            # Destroy if running
            if sudo virsh list --name 2>/dev/null | grep -q "^${vm}$"; then
                print_status "info" "  Destroying running VM: $vm"
                sudo virsh destroy "$vm" 2>/dev/null || true
            fi
            
            # Undefine VM
            print_status "info" "  Undefining VM: $vm"
            sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
        fi
    done
    
    # Refresh pool
    sudo virsh pool-refresh "$pool_name" 2>/dev/null || true
    
    print_status "success" "Domain cleanup completed"
}

# Fungsi: Generate Deployment Report
generate_deployment_report() {
    local report_file="${LOG_DIR}/deployment-report-${TIMESTAMP}.txt"
    
    print_status "info" "Generating deployment report..."
    
    {
        echo "============================================================"
        echo "Quickstack Infrastructure Deployment Report"
        echo "============================================================"
        echo "Timestamp: $(date)"
        echo "Duration: $(($(date +%s) - START_TIME)) seconds"
        echo ""
        echo "--- System Information ---"
        echo "Hostname: $(hostname)"
        echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo "Unknown")"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "--- Terraform Information ---"
        terraform version 2>/dev/null || echo "Terraform version unavailable"
        echo ""
        echo "--- Deployed Resources ---"
        terraform state list 2>/dev/null || echo "No resources in state"
        echo ""
        echo "--- VM Status ---"
        sudo virsh list --all 2>/dev/null || echo "Unable to list VMs"
        echo ""
        echo "--- Storage Pool Status ---"
        sudo virsh pool-info k3s_infra_pool 2>/dev/null || echo "Pool info unavailable"
        echo ""
        echo "--- Storage Volumes ---"
        sudo virsh vol-list k3s_infra_pool 2>/dev/null || echo "Volume list unavailable"
        echo ""
        echo "--- Terraform Outputs ---"
        terraform output 2>/dev/null || echo "No outputs available"
        echo ""
        echo "============================================================"
    } > "$report_file"
    
    print_status "success" "Deployment report saved to: $report_file"
}

# Fungsi: Interactive Menu untuk Troubleshooting
show_troubleshooting_menu() {
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           Troubleshooting Menu                         ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "1. Cleanup failed resources"
    echo "2. Deep clean storage pool (DESTRUCTIVE)"
    echo "3. Verify storage pool and volumes"
    echo "4. Check Terraform state"
    echo "5. Cleanup existing domains"
    echo "6. Generate deployment report"
    echo "7. View recent logs"
    echo "8. Exit"
    echo ""
    read -p "Select option (1-8): " -r option
    
    case $option in
        1)
            cleanup_failed_resources
            ;;
        2)
            deep_clean_storage
            ;;
        3)
            verify_libvirt_pool
            verify_storage_volumes
            ;;
        4)
            verify_terraform_state
            ;;
        5)
            cleanup_existing_domains
            ;;
        6)
            generate_deployment_report
            ;;
        7)
            print_status "info" "Displaying last 50 lines of log..."
            tail -n 50 "$LOG_FILE"
            ;;
        8)
            print_status "info" "Exiting troubleshooting menu"
            return 0
            ;;
        *)
            print_status "error" "Invalid option"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..." -r
    show_troubleshooting_menu
}

# Fungsi: Display Deployment Summary
display_deployment_summary() {
    local duration=$1
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Deployment Summary                           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # VM Information
    print_status "info" "Virtual Machines:"
    local vm_list=$(sudo virsh list --all 2>/dev/null | grep "k3s-" || echo "")
    if [[ -n "$vm_list" ]]; then
        echo "$vm_list" | sed 's/^/  /'
    else
        echo "  No VMs found"
    fi
    
    echo ""
    
    # Storage Information
    print_status "info" "Storage Pool Status:"
    sudo virsh pool-info k3s_infra_pool 2>/dev/null | grep -E "State|Capacity|Allocation|Available" | sed 's/^/  /' || echo "  Pool info unavailable"
    
    echo ""
    
    # Resource Count
    print_status "info" "Terraform Resources:"
    local resource_count=$(terraform state list 2>/dev/null | wc -l || echo "0")
    echo "  Total resources: $resource_count"
    
    echo ""
    
    # Timing Information
    print_status "info" "Deployment Timing:"
    echo "  Total duration: ${duration} seconds"
    echo "  Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    echo ""
    
    # Log Location
    print_status "info" "Log Files:"
    echo "  Deployment log: $LOG_FILE"
    echo "  Log directory: $LOG_DIR"
    
    echo ""
}

# Fungsi: Backup Terraform State
backup_terraform_state() {
    local backup_dir="${PROJECT_ROOT}/terraform-backups"
    local backup_file="${backup_dir}/terraform.tfstate.backup-${TIMESTAMP}"
    
    if [[ -f "$PROJECT_ROOT/terraform.tfstate" ]]; then
        print_status "info" "Backing up Terraform state..."

        if ! mkdir -p "$backup_dir" >>"$LOG_FILE" 2>&1; then
            backup_dir="/tmp/terraform-backups"
            backup_file="${backup_dir}/terraform.tfstate.backup-${TIMESTAMP}"
            mkdir -p "$backup_dir" >>"$LOG_FILE" 2>&1 || true
        fi

        if cp "$PROJECT_ROOT/terraform.tfstate" "$backup_file" >>"$LOG_FILE" 2>&1; then
            print_status "success" "State backed up to: $backup_file"
        else
            print_status "warn" "State backup failed (non-critical). Continuing."
            return 0
        fi
        
        # Keep only last 10 backups
        local backup_count=$(ls -1 "$backup_dir"/terraform.tfstate.backup-* 2>/dev/null | wc -l | tr -d ' ')
        if [[ $backup_count -gt 10 ]]; then
            print_status "info" "Cleaning old backups (keeping last 10)..."
            local old_list
            old_list=$(ls -1t "$backup_dir"/terraform.tfstate.backup-* 2>/dev/null | tail -n +11 || true)
            if [[ -n "$old_list" ]]; then
                printf "%s\n" "$old_list" | xargs rm -f >>"$LOG_FILE" 2>&1 || true
            fi
        fi
    else
        print_status "warn" "No state file to backup"
    fi
}

# Fungsi: Check for Updates
check_for_updates() {
    print_status "info" "Checking for script updates..."

    if [[ "${SKIP_UPDATE_CHECK:-false}" == "true" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_status "info" "Skipping update check"
        return 0
    fi
    
    # Check if we're in a git repository
    if git rev-parse --git-dir > /dev/null 2>&1; then
        local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        print_status "info" "Current branch: $current_branch"
        
        # Fetch latest changes (without pulling)
        if GIT_SSH_COMMAND="ssh -o BatchMode=yes" git fetch origin &>/dev/null; then
            local behind_count=$(git rev-list HEAD..origin/$current_branch --count 2>/dev/null || echo "0")
            if [[ $behind_count -gt 0 ]]; then
                print_status "warn" "Script is $behind_count commit(s) behind origin"
                print_status "info" "Consider running: git pull origin $current_branch"
            else
                print_status "info" "Script is up to date"
            fi
        else
            print_status "warn" "Unable to check for updates (network issue?)"
        fi
    else
        print_status "info" "Not in a git repository, skipping update check"
    fi
}

# Fungsi: Validate Environment Variables
validate_environment() {
    print_status "info" "Validating environment variables..."

    if [[ -f "$VAR_FILE" ]]; then
        local tfvars_libvirt_uri=""
        tfvars_libvirt_uri="$(awk -F'=' '/^[[:space:]]*libvirt_uri[[:space:]]*=/{gsub(/^[[:space:]]+/,"",$2); gsub(/[[:space:]]+$/,"",$2); gsub(/"/,"",$2); print $2; exit}' "$VAR_FILE" 2>/dev/null || true)"
        if [[ -n "$tfvars_libvirt_uri" ]] && [[ "${LIBVIRT_DEFAULT_URI:-qemu:///system}" == "qemu:///system" ]]; then
            export LIBVIRT_DEFAULT_URI="$tfvars_libvirt_uri"
        fi
    fi

    export TF_VAR_libvirt_uri="${TF_VAR_libvirt_uri:-${LIBVIRT_DEFAULT_URI:-qemu:///system}}"

    # Daftar variabel yang diperlukan
    local required_vars=("LIBVIRT_DEFAULT_URI")
    local missing_vars=()

    # Iterasi dengan pengecekan yang aman untuk unbound variables
    for var in "${required_vars[@]}"; do
        # Gunakan parameter expansion yang aman untuk menghindari error unbound variable
        # ${!var:-} akan mengembalikan empty string jika variabel tidak terdefinisi
        local var_value="${!var:-}"

        if [[ -z "$var_value" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_status "warn" "Missing environment variables: ${missing_vars[*]}"
        print_status "info" "Setting default values..."
        
        # Set default untuk setiap variabel yang hilang
        for missing_var in "${missing_vars[@]}"; do
            case "$missing_var" in
                LIBVIRT_DEFAULT_URI)
                    export LIBVIRT_DEFAULT_URI="qemu:///system"
                    print_status "info" "  Set LIBVIRT_DEFAULT_URI=qemu:///system"
                    ;;
                *)
                    print_status "warn" "  No default value for: $missing_var"
                    ;;
            esac
        done
    else
        print_status "info" "✓ All required environment variables set"
        
        # Display current values (optional)
        for var in "${required_vars[@]}"; do
            local var_value="${!var:-}"
            print_status "info" "  $var = $var_value"
        done
    fi

    local tf_log_path="${TF_LOG_PATH:-}"
    if [[ -n "$tf_log_path" ]]; then
        local tf_log_dir=""
        tf_log_dir="$(dirname "$tf_log_path")"
        if [[ ! -d "$tf_log_dir" ]] || [[ ! -w "$tf_log_dir" ]] || { [[ -e "$tf_log_path" ]] && [[ ! -w "$tf_log_path" ]]; }; then
            print_status "warn" "TF_LOG_PATH points to a non-writable location. Unsetting to prevent Terraform failures."
            unset TF_LOG_PATH
        fi
    fi
}

# Fungsi: Ensure Dummy Kubeconfig Exists
ensure_dummy_kubeconfig() {
    local kube_config_path="${PROJECT_ROOT}/kubeconfig"
    local create_dummy=false
    
    if [[ ! -f "$kube_config_path" ]]; then
        create_dummy=true
        print_status "info" "Kubeconfig not found. Preparing to create dummy..."
    elif ! grep -q "server:" "$kube_config_path"; then
        create_dummy=true
        print_status "warn" "Existing kubeconfig is invalid (no server defined). Overwriting with dummy..."
    fi
    
    if [[ "$create_dummy" == "true" ]]; then
        print_status "info" "Creating dummy kubeconfig for Terraform provider initialization..."
        
        cat <<EOF > "$kube_config_path"
apiVersion: v1
clusters:
- cluster:
    server: https://127.0.0.1:6443
    insecure-skip-tls-verify: true
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    token: default
EOF
        
        print_status "success" "Dummy kubeconfig created at: $kube_config_path"
    else
        print_status "info" "Valid kubeconfig found, skipping dummy creation."
    fi
}

kubeconfig_selected_path() {
    local output=""
    output=$(bash "${PROJECT_ROOT}/scripts/get_kubeconfig.sh" 2>/dev/null || true)
    echo "$output" | sed -n 's/.*"kube_config_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

kubeconfig_server_url() {
    local kube_path="$1"
    grep -m1 -E '^[[:space:]]*server:' "$kube_path" 2>/dev/null | awk '{print $2}' | head -n 1 || true
}

kubeconfig_is_dummy() {
    local kube_path="$1"
    local server_url=""
    server_url=$(kubeconfig_server_url "$kube_path" || true)
    [[ "$server_url" == "https://127.0.0.1:6443" ]]
}

kube_apiserver_ready() {
    local kube_path="$1"
    if [[ -z "$kube_path" ]] || [[ ! -f "$kube_path" ]]; then
        return 1
    fi
    if kubeconfig_is_dummy "$kube_path"; then
        return 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        return 1
    fi
    KUBECONFIG="$kube_path" kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1
}

# Fungsi: Cleanup Stuck n8n Pods (Terminating State)
cleanup_stuck_n8n_pods() {
    print_status "info" "Checking for stuck Terminating pods in n8n namespace..."
    
    local selected_kubeconfig
    selected_kubeconfig=$(kubeconfig_selected_path || true)
    if [[ -z "$selected_kubeconfig" ]] || [[ "$selected_kubeconfig" == "NOT_FOUND" ]]; then
        # Fallback if not found, though likely won't work if no kubeconfig
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        return 0
    fi

    local ns="n8n"
    # Find pods that are in Terminating state
    local stuck_pods
    stuck_pods=$(KUBECONFIG="$selected_kubeconfig" kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "Terminating" | awk '{print $1}' || true)

    if [[ -n "$stuck_pods" ]]; then
        print_status "warn" "Found stuck Terminating pods: $stuck_pods"
        
        for pod in $stuck_pods; do
            print_status "info" "Force deleting stuck pod: $pod"
            # Try force delete with 0 grace period
            KUBECONFIG="$selected_kubeconfig" kubectl delete pod "$pod" -n "$ns" --grace-period=0 --force 2>&1 | tee -a "$LOG_FILE" || true
            
            # Check if still exists after a moment
            sleep 2
            if KUBECONFIG="$selected_kubeconfig" kubectl get pod "$pod" -n "$ns" >/dev/null 2>&1; then
                print_status "warn" "Pod $pod still exists after force delete. Patching finalizers..."
                # Patch finalizers to null to allow deletion
                KUBECONFIG="$selected_kubeconfig" kubectl patch pod "$pod" -n "$ns" -p '{"metadata":{"finalizers":null}}' 2>&1 | tee -a "$LOG_FILE" || true
            fi
        done
        print_status "success" "Cleanup of stuck pods completed"
    else
        print_status "info" "No stuck Terminating pods found"
    fi
}

# Fungsi: Enhanced Main Execution Flow
main() {
    clear
    echo -e "${MAGENTA}============================================================${NC}"
    echo -e "${MAGENTA}       🚀 Quickstack Infrastructure Deployment v3.1        ${NC}"
    echo -e "${MAGENTA}============================================================${NC}"
    echo ""
    
    # Initialize
    init_logging
    rotate_logs
    validate_environment
    
    # Check for updates (non-blocking)
    check_for_updates

    # Ensure dummy kubeconfig exists for Terraform providers
    ensure_dummy_kubeconfig

    print_status "info" "Terraform apply parallelism: $TF_PARALLELISM"
    
    cd "$PROJECT_ROOT" || {
        print_status "error" "Failed to change to project root: $PROJECT_ROOT"
        exit 1
    }
    
    # Backup existing state
    backup_terraform_state
    
    # Pre-flight checks
    print_status "step" "Running comprehensive pre-flight checks..."
    if ! comprehensive_preflight_checks; then
        print_status "error" "Pre-flight checks failed"

        if [[ "${PREFLIGHT_CRITICAL_FAILURE:-false}" == "true" ]]; then
            handle_error 1 "Pre-flight Checks"
        fi

        if [[ "${FORCE_MODE:-false}" == "true" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
            print_status "warn" "Continuing despite failed pre-flight checks due to --force/--dry-run"
        else
            read -p "Continue anyway? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                print_status "info" "Deployment cancelled by user"
                exit 1
            fi
        fi
    fi
    
    # Step 1: Terraform Init
    local step_start=$(date +%s)
    print_status "step" "Inisialisasi Terraform..."

    setup_terraform_runtime

    if ! verify_terraform_provider_connectivity; then
        print_status "warn" "Konektivitas ke registry/provider checksum tidak stabil. Terraform init berpotensi gagal."
        if [[ "${FORCE_MODE:-false}" == "true" ]] || [[ "${DRY_RUN:-false}" == "true" ]]; then
            print_status "warn" "Melanjutkan karena --force/--dry-run"
        else
            read -p "Lanjutkan terraform init? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                handle_error 1 "Terraform Provider Connectivity"
            fi
        fi
    fi
    
    if terraform_init_with_retry; then
        print_status "success" "Terraform initialized successfully"
    else
        handle_error $? "Terraform Init"
    fi
    
    local step_end=$(date +%s)
    echo "Step 1 (Init) took $((step_end - step_start))s" >> "$LOG_FILE"
    
    # Step 2: Terraform Validate
    step_start=$(date +%s)
    print_status "step" "Validasi Konfigurasi..."
    
    if terraform validate >> "$LOG_FILE" 2>&1; then
        print_status "success" "Configuration validated successfully"
    else
        print_status "error" "Configuration validation failed"
        terraform validate 2>&1 | tee -a "$LOG_FILE"
        handle_error 1 "Terraform Validate"
    fi
    
    step_end=$(date +%s)
    echo "Step 2 (Validate) took $((step_end - step_start))s" >> "$LOG_FILE"

    # Reconcile libvirt state drift before planning/applying
    reconcile_libvirt_state
    reconcile_libvirt_domain_state
    
    # Cleanup stuck pods before planning to avoid state conflicts
    cleanup_stuck_n8n_pods

    # Step 3: Terraform Plan
    step_start=$(date +%s)
    print_status "step" "Membuat Rencana Perubahan (Plan)..."

    local selected_kubeconfig
    selected_kubeconfig=$(kubeconfig_selected_path || true)
    if [[ -z "$selected_kubeconfig" ]] || [[ "$selected_kubeconfig" == "NOT_FOUND" ]]; then
        selected_kubeconfig="${PROJECT_ROOT}/kubeconfig"
    fi

    local plan_refresh_arg=""
    if ! kube_apiserver_ready "$selected_kubeconfig"; then
        plan_refresh_arg="-refresh=false"
        print_status "warn" "Kubernetes apiserver belum siap atau kubeconfig masih dummy. Menjalankan plan tanpa refresh."
    fi

    if terraform plan $plan_refresh_arg -var-file="$VAR_FILE" -out="$PLAN_FILE" -input=false -compact-warnings >> "$LOG_FILE" 2>&1; then
        print_status "success" "Plan created successfully"
        
        # Display plan summary
        local plan_summary=$(terraform show -no-color "$PLAN_FILE" 2>/dev/null | grep -E "Plan:|will be created|will be updated|will be destroyed" | head -n 5)
        if [[ -n "$plan_summary" ]]; then
            echo -e "${YELLOW}Plan Summary:${NC}"
            echo "$plan_summary" | sed 's/^/  /'
            echo "$plan_summary" >> "$LOG_FILE"
        fi
        
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            print_status "success" "Dry-run mode enabled. Skipping apply."
        elif [[ "${FORCE_MODE:-false}" == "true" ]]; then
            print_status "warn" "--force enabled. Proceeding to apply without prompt."
        else
            echo ""
            read -p "Proceed with apply? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                print_status "info" "Deployment cancelled by user"
                rm -f "$PLAN_FILE"
                exit 0
            fi
        fi
    else
        if tail -n 300 "$LOG_FILE" | grep -q "apiserver not ready"; then
            print_status "warn" "Terraform plan gagal karena apiserver belum siap. Mencoba ulang plan tanpa refresh..."
            if terraform plan -refresh=false -var-file="$VAR_FILE" -out="$PLAN_FILE" -input=false -compact-warnings >> "$LOG_FILE" 2>&1; then
                print_status "success" "Plan created successfully (no refresh)"
            else
                handle_error $? "Terraform Plan"
            fi
        elif tail -n 300 "$LOG_FILE" | grep -q "no domain with matching uuid" || tail -n 300 "$LOG_FILE" | grep -q "retrieving libvirt domain by delete"; then
            print_status "warn" "Terraform plan gagal karena state libvirt domain tidak sinkron. Melakukan rekonsiliasi state dan retry plan..."
            reconcile_libvirt_domain_state
            if terraform plan $plan_refresh_arg -var-file="$VAR_FILE" -out="$PLAN_FILE" -input=false -compact-warnings >> "$LOG_FILE" 2>&1; then
                print_status "success" "Plan created successfully after libvirt reconciliation"
            else
                handle_error $? "Terraform Plan"
            fi
        else
            handle_error $? "Terraform Plan"
        fi
    fi
    
    step_end=$(date +%s)
    echo "Step 3 (Plan) took $((step_end - step_start))s" >> "$LOG_FILE"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        print_status "step" "Dry-run Summary..."
        terraform show -no-color "$PLAN_FILE" 2>/dev/null | sed -n '1,120p' | tee -a "$LOG_FILE" || true
        generate_deployment_report || true
        rm -f "$PLAN_FILE" || true
        print_status "success" "Dry-run completed"
        exit 0
    fi
    
    # Step 4: Terraform Apply (with retry)
    step_start=$(date +%s)
    print_status "step" "Menerapkan Perubahan (Apply)..."
    
    if terraform_apply_with_retry; then
        print_status "success" "Infrastructure deployed successfully"
    else
        print_status "error" "Terraform apply failed after retries"
        
        # Offer troubleshooting menu
        echo ""
        read -p "Open troubleshooting menu? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            show_troubleshooting_menu
        fi
        
        handle_error 1 "Terraform Apply"
    fi
    
    step_end=$(date +%s)
    echo "Step 4 (Apply) took $((step_end - step_start))s" >> "$LOG_FILE"

    # Step 5: Post-deployment Verification
    step_start=$(date +%s)
    print_status "step" "Post-deployment Verification..."
    
    if post_deployment_verification; then
        print_status "success" "Post-deployment verification passed"
    else
        handle_error 1 "Post-deployment Verification"
    fi

    validate_ssh_authentication
    
    step_end=$(date +%s)
    echo "Step 5 (Post-verification) took $((step_end - step_start))s" >> "$LOG_FILE"
    
    # Step 6: Terraform Outputs
    step_start=$(date +%s)
    print_status "step" "Mengambil Output Infrastruktur..."
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              Terraform Outputs                         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    
    if terraform output -no-color > /dev/null 2>&1; then
        terraform output -no-color | sed 's/^/  /' | tee -a "$LOG_FILE"
    else
        print_status "warn" "No outputs available"
    fi
    
    step_end=$(date +%s)
    echo "Step 6 (Outputs) took $((step_end - step_start))s" >> "$LOG_FILE"
    
    # Step 7: Generate Report
    step_start=$(date +%s)
    print_status "step" "Generating Deployment Report..."
    
    generate_deployment_report
    
    step_end=$(date +%s)
    echo "Step 7 (Report) took $((step_end - step_start))s" >> "$LOG_FILE"
    
    # Step 8: Cleanup
    step_start=$(date +%s)
    print_status "step" "Pembersihan File Sementara..."
    
    # Remove plan file
    if [[ -f "$PLAN_FILE" ]]; then
        rm -f "$PLAN_FILE"
        print_status "info" "Removed temporary plan file"
    fi
    
    # Compress old logs
    find "$LOG_DIR" -name "*.log" -mtime +1 -exec gzip {} \; 2>/dev/null || true
    
    draw_progress_bar 100 "Selesai"
    echo -e "\n"
    
    step_end=$(date +%s)
    echo "Step 8 (Cleanup) took $((step_end - step_start))s" >> "$LOG_FILE"
    
    # Final Summary
    local total_duration=$(($(date +%s) - START_TIME))
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
    echo "Deployment completed successfully at $(date)" >> "$LOG_FILE"
    echo "Total duration: ${total_duration} seconds" >> "$LOG_FILE"
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
    
    # Display success banner
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                        ║${NC}"
    echo -e "${GREEN}║          ✓  Deployment Berhasil!  ✓                   ║${NC}"
    echo -e "${GREEN}║                                                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    
    # Display deployment summary
    display_deployment_summary "$total_duration"
    
    # Offer next steps
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Validate SSH (auto-fix known_hosts): bash ./scripts/validate_ssh_auth.sh --fix-known-hosts"
    echo "  2. Verify VM connectivity (manual): ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null qbig_user@<vm-ip>"
    echo "  3. Check VM status: sudo virsh list --all"
    echo "  4. View deployment report: cat ${LOG_DIR}/deployment-report-${TIMESTAMP}.txt"
    echo "  5. Access troubleshooting menu: $0 --troubleshoot"
    echo ""
    
    print_status "success" "Log lengkap tersedia di: $LOG_FILE"
    
    return 0
}

# Fungsi: Destroy Infrastructure
destroy_infrastructure() {
    print_status "warn" "╔════════════════════════════════════════════════════════╗"
    print_status "warn" "║          DESTROY INFRASTRUCTURE                        ║"
    print_status "warn" "╚════════════════════════════════════════════════════════╝"
    print_status "warn" "This will DESTROY all resources managed by Terraform!"
    echo ""
    
    # Show current resources
    print_status "info" "Current resources:"
    terraform state list 2>/dev/null | sed 's/^/  /' || echo "  No resources found"
    
    echo ""
    read -p "Type 'yes' to confirm destruction: " -r
    if [[ ! $REPLY == "yes" ]]; then
        print_status "info" "Destruction cancelled"
        return 0
    fi
    
    # Backup state before destroy
    backup_terraform_state
    
    # Perform destroy
    print_status "step" "Destroying infrastructure..."
    
    if terraform destroy -var-file="$VAR_FILE" -auto-approve >> "$LOG_FILE" 2>&1; then
        print_status "success" "Infrastructure destroyed successfully"
        
        # Cleanup storage pool
        print_status "info" "Cleaning up storage pool..."
        cleanup_failed_resources
        
        print_status "success" "Cleanup completed"
    else
        print_status "error" "Destroy failed"
        print_status "info" "Check log for details: $LOG_FILE"
        return 1
    fi
}

# Fungsi: Show Help
show_help() {
    cat << EOF
${CYAN}╔════════════════════════════════════════════════════════╗${NC}
${CYAN}║     Quickstack Infrastructure Deployment Script        ║${NC}
${CYAN}╚════════════════════════════════════════════════════════╝${NC}

${WHITE}Usage:${NC}
  $0 [OPTIONS]

${WHITE}Options:${NC}
  ${GREEN}--help, -h${NC}              Show this help message
  ${GREEN}--troubleshoot, -t${NC}      Open troubleshooting menu
  ${GREEN}--destroy, -d${NC}           Destroy infrastructure
  ${GREEN}--verify, -v${NC}            Run verification checks only
  ${GREEN}--report, -r${NC}            Generate deployment report
  ${GREEN}--cleanup, -c${NC}           Cleanup failed resources
  ${GREEN}--deep-clean${NC}            Deep clean storage pool (DESTRUCTIVE)
  ${GREEN}--dry-run${NC}               Run init/validate/plan only (no apply)
  ${GREEN}--no-backup${NC}             Skip state backup
  ${GREEN}--force${NC}                 Skip confirmation prompts

${WHITE}Examples:${NC}
  ${YELLOW}# Normal deployment${NC}
  $0

  ${YELLOW}# Run troubleshooting menu${NC}
  $0 --troubleshoot

  ${YELLOW}# Destroy infrastructure${NC}
  $0 --destroy

  ${YELLOW}# Verify infrastructure only${NC}
  $0 --verify

  ${YELLOW}# Cleanup failed resources${NC}
  $0 --cleanup

${WHITE}Log Files:${NC}
  Deployment logs: ${LOG_DIR}/
  Current log: ${LOG_FILE}

${WHITE}Configuration:${NC}
  Project root: ${PROJECT_ROOT}
  Variables file: ${VAR_FILE}

${WHITE}For more information:${NC}
  Documentation: ${PROJECT_ROOT}/README.md
  Issues: https://github.com/your-repo/issues

EOF
}

# Fungsi: Parse Command Line Arguments
parse_arguments() {
    local skip_backup=false
    local force_mode=false
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --troubleshoot|-t)
                init_logging
                show_troubleshooting_menu
                exit 0
                ;;
            --destroy|-d)
                init_logging
                destroy_infrastructure
                exit $?
                ;;
            --verify|-v)
                init_logging
                comprehensive_preflight_checks
                post_deployment_verification
                exit 0
                ;;
            --report|-r)
                init_logging
                generate_deployment_report
                exit 0
                ;;
            --cleanup|-c)
                init_logging
                cleanup_failed_resources
                exit 0
                ;;
            --deep-clean)
                init_logging
                deep_clean_storage
                exit 0
                ;;
            --dry-run)
                dry_run=true
                ;;
            --no-backup)
                skip_backup=true
                ;;
            --force)
                force_mode=true
                ;;
            *)
                print_status "error" "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
        shift
    done
    
    # Export flags for use in main
    export SKIP_BACKUP=$skip_backup
    export FORCE_MODE=$force_mode
    export DRY_RUN=$dry_run
}

# Fungsi: Fix VM Network Issues (New)
fix_vm_network_issues() {
    local vm_name="${1:-k3s-master-01}"
    
    print_status "info" "Attempting to fix network issues for VM: $vm_name"
    
    # Check if fix script exists
    local fix_script="${PROJECT_ROOT}/scripts/fix_vm_network.sh"
    
    if [[ -f "$fix_script" ]]; then
        print_status "info" "Running network fix script..."
        bash "$fix_script" "$vm_name" 2>&1 | tee -a "$LOG_FILE"
        return $?
    else
        print_status "warn" "Network fix script not found, using built-in fixes..."
        
        # Built-in fix: Restart libvirt network
        local network_name=$(sudo virsh domiflist "$vm_name" 2>/dev/null | awk 'NR>2 {print $3; exit}')
        [[ -z "$network_name" ]] && network_name="default"
        
        print_status "info" "Restarting network: $network_name"
        sudo virsh net-destroy "$network_name" 2>/dev/null || true
        sleep 2
        sudo virsh net-start "$network_name" 2>/dev/null || true
        sleep 5
        
        # Restart VM
        print_status "info" "Rebooting VM: $vm_name"
        sudo virsh reboot "$vm_name" >> "$LOG_FILE" 2>&1 || true
        sleep 30
        
        return 0
    fi
}

# Fungsi: Enhanced IP Retrieval with Multiple Methods
get_vm_ip_address() {
    local vm_name="${1:-k3s-master-01}"
    local max_attempts=15
    local attempt=1
    
    print_status "info" "Retrieving IP address for VM: $vm_name"
    
    while [[ $attempt -le $max_attempts ]]; do
        print_status "info" "Attempt $attempt/$max_attempts..."
        
        # Method 1: DHCP leases
        local network_name=$(sudo virsh domiflist "$vm_name" 2>/dev/null | awk 'NR>2 {print $3; exit}')
        [[ -z "$network_name" ]] && network_name="default"
        
        local ip_address=$(sudo virsh net-dhcp-leases "$network_name" 2>/dev/null | grep "$vm_name" | awk '{print $5}' | cut -d'/' -f1 | head -1)
        
        if [[ -n "$ip_address" && "$ip_address" != "N/A" ]]; then
            print_status "success" "IP found via DHCP: $ip_address"
            echo "$ip_address"
            return 0
        fi
        
        # Method 2: virsh domifaddr with different sources
        for source in lease agent arp; do
            ip_address=$(sudo virsh domifaddr "$vm_name" --source "$source" 2>/dev/null | awk 'NR>2 {print $4}' | cut -d'/' -f1 | head -1)
            if [[ -n "$ip_address" && "$ip_address" != "N/A" ]]; then
                print_status "success" "IP found via $source: $ip_address"
                echo "$ip_address"
                return 0
            fi
        done
        
        # Method 3: ARP table
        local mac_address=$(sudo virsh dumpxml "$vm_name" 2>/dev/null | grep "mac address" | head -1 | sed "s/.*'\(.*\)'.*/\1/")
        if [[ -n "$mac_address" ]]; then
            ip_address=$(arp -n 2>/dev/null | grep -i "$mac_address" | awk '{print $1}' | head -1)
            if [[ -n "$ip_address" && "$ip_address" != "N/A" ]]; then
                print_status "success" "IP found via ARP: $ip_address"
                echo "$ip_address"
                return 0
            fi
        fi
        
        # Method 4: Check guest agent
        if sudo virsh qemu-agent-command "$vm_name" '{"execute":"guest-ping"}' &>/dev/null; then
            local guest_info=$(sudo virsh qemu-agent-command "$vm_name" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null)
            ip_address=$(echo "$guest_info" | grep -oP '"ip-address":\s*"\K[0-9.]+' | grep -v "127.0.0.1" | head -1)
            if [[ -n "$ip_address" ]]; then
                print_status "success" "IP found via guest agent: $ip_address"
                echo "$ip_address"
                return 0
            fi
        fi
        
        # If this is attempt 5, try fixing network
        if [[ $attempt -eq 5 ]]; then
            print_status "warn" "IP not found after 5 attempts, trying network fix..."
            fix_vm_network_issues "$vm_name"
        fi
        
        ((attempt++))
        sleep 10
    done
    
    print_status "error" "Failed to retrieve IP address after $max_attempts attempts"
    return 1
}

# Fungsi: Signal Handler untuk Ctrl+C
cleanup_on_interrupt() {
    echo ""
    print_status "warn" "Deployment interrupted by user"
    
    # Cleanup temporary files
    if [[ -f "$PLAN_FILE" ]]; then
        rm -f "$PLAN_FILE"
        print_status "info" "Removed temporary plan file"
    fi
    
    # Log interruption
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
    echo "Deployment interrupted at $(date)" >> "$LOG_FILE"
    echo "----------------------------------------------------------------" >> "$LOG_FILE"
    
    print_status "info" "Partial log available at: $LOG_FILE"
    
    exit 130
}

# ============================================================================
# Script Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap cleanup_on_interrupt SIGINT SIGTERM
    parse_arguments "$@"
    main
    exit 0
fi
