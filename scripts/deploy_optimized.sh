#!/bin/bash

# ==============================================================================
# Terraform Optimized Deployment Script (v3 - Real-time Progress)
# ==============================================================================
# Deskripsi: Skrip untuk menjalankan validasi, perencanaan, dan penerapan
#            infrastruktur Terraform dengan visualisasi progres real-time.
# ==============================================================================

set -euo pipefail

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
    if ! sudo virsh pool-list --all | grep -q "$pool_name"; then
        print_status "error" "Storage pool '$pool_name' not found"
        print_status "info" "Attempting to create storage pool..."

        # Create pool if not exists
        sudo virsh pool-define-as "$pool_name" dir --target "$pool_path" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to define storage pool"
            handle_error 1 "Define Storage Pool"
        }

        # PERBAIKAN: Menghapus spasi berlebih sebelum sudo yang menyebabkan error
        sudo virsh pool-build "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to build storage pool"
            handle_error 1 "Build Storage Pool"
        }
        
        sudo virsh pool-start "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to start storage pool"
            handle_error 1 "Start Storage Pool"
        }
        
        sudo virsh pool-autostart "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "warn" "Failed to set pool autostart (non-critical)"
        }
        
        print_status "success" "Storage pool created successfully"
    fi
    
    # Check if pool is active
    if ! sudo virsh pool-list | grep -q "$pool_name"; then
        print_status "info" "Activating storage pool..."
        sudo virsh pool-start "$pool_name" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to start storage pool"
            handle_error 1 "Start Storage Pool"
        }
    fi
    
    # Verify pool path exists and is writable
    if [[ ! -d "$pool_path" ]]; then
        print_status "warn" "Pool path does not exist, creating: $pool_path"
        sudo mkdir -p "$pool_path" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to create pool path"
            handle_error 1 "Create Pool Path"
        }
        sudo chmod 755 "$pool_path" >> "$LOG_FILE" 2>&1
    fi
    
     # Check write permission
    if ! sudo test -w "$pool_path"; then
        print_status "warn" "Pool path is not writable, fixing permissions..."
        sudo chmod 755 "$pool_path" >> "$LOG_FILE" 2>&1 || {
            print_status "error" "Failed to fix pool path permissions"
            handle_error 1 "Fix Pool Permissions"
        }
    fi
    
    # Refresh pool to sync with filesystem
    print_status "info" "Refreshing storage pool..."
    sudo virsh pool-refresh "$pool_name" >> "$LOG_FILE" 2>&1 || {
        print_status "warn" "Pool refresh failed (non-critical)"
    }
    
    # Display pool info
    print_status "info" "Storage pool status:"
    sudo virsh pool-info "$pool_name" | tee -a "$LOG_FILE"
    
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
    sudo virsh vol-list "$pool_name" 2>&1 | tee -a "$LOG_FILE"
    
    # Check for orphaned or problematic volumes
    print_status "info" "Checking for orphaned volumes..."
    
    # List files in pool directory
    print_status "info" "Files in pool directory:"
    sudo ls -lh "$pool_path" 2>&1 | tee -a "$LOG_FILE"
    
    # Verify each expected volume type
    local volume_types=("ubuntu-base-img" "ubuntu-disk" "cloudinit")
    local found_issues=false
    
    for vol_type in "${volume_types[@]}"; do
        local vol_count
        vol_count=$(sudo virsh vol-list "$pool_name" 2>/dev/null | grep -c "$vol_type" || echo "0")
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

            if ! sudo virsh vol-list "$pool_name" 2>/dev/null | grep -q "$basename"; then
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


# Fungsi: Pre-deployment Checks (Comprehensive)
comprehensive_preflight_checks() {
    print_status "step" "Comprehensive Pre-flight Checks"
    
    local checks_passed=true
    
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
        sudo systemctl start libvirtd || {
            print_status "error" "Failed to start libvirt service"
            checks_passed=false
        }
    fi
    
    # 3. Network Connectivity
    print_status "info" "Checking network connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        print_status "info" "✓ Network connectivity OK"
    else
        print_status "warn" "Network connectivity issue detected"
    fi
    
    # 4. Terraform Version
    print_status "info" "Checking Terraform version..."
    local tf_version=$(terraform version 2>/dev/null | head -n1 | awk '{print $2}' || echo "unknown")
    print_status "info" "✓ Terraform version: $tf_version"
    
    # 5. Required Terraform Providers
    print_status "info" "Checking Terraform providers..."
    if [[ -d "$PROJECT_ROOT/.terraform/providers" ]]; then
        print_status "info" "✓ Terraform providers initialized"
    else
        print_status "warn" "Terraform providers not initialized (will be done in init step)"
    fi
    
    # 6. Storage Pool
    verify_libvirt_pool || checks_passed=false
    
    # 7. Storage Volumes
    verify_storage_volumes || checks_passed=false
    
    # 8. Terraform State
    verify_terraform_state || checks_passed=false
    
    # Final verdict
    if [[ "$checks_passed" == "true" ]]; then
        print_status "success" "All pre-flight checks passed ✓"
        return 0
    else
        print_status "warn" "Some pre-flight checks completed with warnings"
        return 0
    fi
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
    
    print_status "success" "Post-deployment verification completed"
    return 0
}

# Fungsi: Terraform Apply with Retry and Better Error Handling
terraform_apply_with_retry() {
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        print_status "info" "Terraform apply attempt $attempt/$max_attempts"
        
        # Capture both stdout and stderr
        local apply_output
        local apply_exit_code
        
        if apply_output=$(terraform apply -auto-approve "$PLAN_FILE" 2>&1); then
            print_status "success" "Terraform apply succeeded"
            echo "$apply_output" >> "$LOG_FILE"
            return 0
        else
            apply_exit_code=$?
            echo "$apply_output" >> "$LOG_FILE"
            print_status "warn" "Terraform apply failed (attempt $attempt/$max_attempts)"
            
            # Check for specific errors
            if echo "$apply_output" | grep -q "Storage volume not found"; then
                print_status "info" "Detected storage volume issue, cleaning up..."
                cleanup_failed_resources
            elif echo "$apply_output" | grep -q "domain already exists"; then
                print_status "info" "Detected existing domain, attempting cleanup..."
                cleanup_existing_domains
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                print_status "info" "Waiting 5 seconds before retry..."
                sleep 5
                
                # Refresh pool before retry
                print_status "info" "Refreshing storage pool..."
                sudo virsh pool-refresh "k3s_infra_pool" 2>/dev/null || true
            fi
            
            ((attempt++))
        fi
    done
    
    print_status "error" "Terraform apply failed after $max_attempts attempts"
    return 1
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
        mkdir -p "$backup_dir"
        cp "$PROJECT_ROOT/terraform.tfstate" "$backup_file"
        print_status "success" "State backed up to: $backup_file"
        
        # Keep only last 10 backups
        local backup_count=$(ls -1 "$backup_dir"/terraform.tfstate.backup-* 2>/dev/null | wc -l)
        if [[ $backup_count -gt 10 ]]; then
            print_status "info" "Cleaning old backups (keeping last 10)..."
            ls -1t "$backup_dir"/terraform.tfstate.backup-* | tail -n +11 | xargs rm -f
        fi
    else
        print_status "warn" "No state file to backup"
    fi
}

# Fungsi: Check for Updates
check_for_updates() {
    print_status "info" "Checking for script updates..."
    
    # Check if we're in a git repository
    if git rev-parse --git-dir > /dev/null 2>&1; then
        local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        print_status "info" "Current branch: $current_branch"
        
        # Fetch latest changes (without pulling)
        if git fetch origin &>/dev/null; then
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
        read -p "Continue anyway? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            print_status "info" "Deployment cancelled by user"
            exit 1
        fi
    fi
    
    # Step 1: Terraform Init
    local step_start=$(date +%s)
    print_status "step" "Inisialisasi Terraform..."
    
    if terraform init -input=false -upgrade >> "$LOG_FILE" 2>&1; then
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
    
    # Step 3: Terraform Plan
    step_start=$(date +%s)
    print_status "step" "Membuat Rencana Perubahan (Plan)..."
    
    if terraform plan -var-file="$VAR_FILE" -out="$PLAN_FILE" -input=false -compact-warnings >> "$LOG_FILE" 2>&1; then
        print_status "success" "Plan created successfully"
        
        # Display plan summary
        local plan_summary=$(terraform show -no-color "$PLAN_FILE" 2>/dev/null | grep -E "Plan:|will be created|will be updated|will be destroyed" | head -n 5)
        if [[ -n "$plan_summary" ]]; then
            echo -e "${YELLOW}Plan Summary:${NC}"
            echo "$plan_summary" | sed 's/^/  /'
            echo "$plan_summary" >> "$LOG_FILE"
        fi
        
        # Ask for confirmation
        echo ""
        read -p "Proceed with apply? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            print_status "info" "Deployment cancelled by user"
            rm -f "$PLAN_FILE"
            exit 0
        fi
    else
        handle_error $? "Terraform Plan"
    fi
    
    step_end=$(date +%s)
    echo "Step 3 (Plan) took $((step_end - step_start))s" >> "$LOG_FILE"
    
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
        print_status "warn" "Some post-deployment checks failed (non-critical)"
    fi
    
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
    echo "  1. Verify VM connectivity: ssh -i <key> ubuntu@<vm-ip>"
    echo "  2. Check VM status: sudo virsh list --all"
    echo "  3. View deployment report: cat ${LOG_DIR}/deployment-report-${TIMESTAMP}.txt"
    echo "  4. Access troubleshooting menu: $0 --troubleshoot"
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
            --no-backup)
                skip_backup=true
                shift
                ;;
            --force)
                force_mode=true
                shift
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

# Fungsi: Trap Signals
trap cleanup_on_interrupt SIGINT SIGTERM

# ============================================================================
# Script Entry Point
# ============================================================================

# Parse command line arguments
parse_arguments "$@"

# Run main deployment
main

# Exit with success
exit 0
