
# ============================================================================
# STORAGE POOL CONFIGURATION (IDEMPOTENT)
# ============================================================================
# Menggunakan null_resource untuk menangani pool yang mungkin sudah ada
# tanpa menyebabkan error "already exists" pada Terraform state.
resource "null_resource" "pool_management" {
  triggers = {
    pool_name = var.libvirt_pool_name
    pool_path = "/var/lib/libvirt/images/${var.libvirt_pool_name}"
  }

  provisioner "local-exec" {
    command = <<-EOT
      POOL_NAME="${self.triggers.pool_name}"
      POOL_PATH="${self.triggers.pool_path}"
      
      echo "Checking storage pool '$POOL_NAME'..."
      
      # Cek apakah pool sudah didefinisikan di libvirt
      if sudo virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
        echo "✓ Pool '$POOL_NAME' already exists."
        
        # Cek apakah pool aktif (running)
        if ! sudo virsh pool-list --persistent | grep -q "$POOL_NAME"; then
             echo "Starting pool '$POOL_NAME'..."
             sudo virsh pool-start "$POOL_NAME"
        else
             echo "✓ Pool '$POOL_NAME' is active."
        fi
      else
        echo "Pool '$POOL_NAME' does not exist. Creating..."
        # Define, Build, Start, Autostart
        sudo virsh pool-define-as --name "$POOL_NAME" --type dir --target "$POOL_PATH"
        sudo virsh pool-build "$POOL_NAME"
        sudo virsh pool-start "$POOL_NAME"
        sudo virsh pool-autostart "$POOL_NAME"
        echo "✓ Pool '$POOL_NAME' created and started."
      fi
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }
}

# ============================================================================
# KVM CAPABILITY DETECTION & AUTO-CONFIGURATION (IMPROVED)
# ============================================================================
resource "null_resource" "detect_virtualization" {
  provisioner "local-exec" {
    command = <<-EOT
      set +e
      
      # Redirect all output to log file
      LOG_FILE="${path.root}/logs/.virt_detection.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > "$LOG_FILE" 2>&1

      # Helper function for logging
      log() { echo "[$(date +'%H:%M:%S')] $1"; }
      log_warn() { echo "[$(date +'%H:%M:%S')] ⚠ WARNING: $1"; }
      log_err() { echo "[$(date +'%H:%M:%S')] ✗ ERROR: $1"; }

      echo "=== Detecting Virtualization Capabilities ==="
      
      VIRT_TYPE="qemu"
      EMULATOR_PATH=""
      CAN_USE_KVM=false
      DETECTION_FAILED=false
      
      # 1. Check /dev/kvm accessibility
      echo -n "Checking /dev/kvm... "
      if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            echo "OK"
            log "✓ /dev/kvm is accessible"
            CAN_USE_KVM=true
            VIRT_TYPE="kvm"
        else
            echo "PERMISSION DENIED"
            log_warn "/dev/kvm exists but user lacks permission"
            log_warn "Current user: $(whoami)"
            log_warn "Permissions: $(ls -l /dev/kvm)"
            log_warn "To enable KVM: sudo usermod -aG kvm $(whoami) && newgrp kvm"
            CAN_USE_KVM=false
            VIRT_TYPE="qemu"
        fi
      else
        echo "NOT FOUND"
        log_warn "/dev/kvm not found - will use QEMU emulation"
        CAN_USE_KVM=false
        VIRT_TYPE="qemu"
      fi
      
      # 2. Detect emulator based on virt type
      log "Detecting suitable emulator for type: $VIRT_TYPE..."
      
      # Function to find emulator
      find_emulator() {
        local virt_type="$1"
        
        if [ "$virt_type" = "qemu" ]; then
          # For QEMU emulation, prefer qemu-system-x86_64
          if [ -x /usr/bin/qemu-system-x86_64 ]; then
              echo "/usr/bin/qemu-system-x86_64"
              return 0
          fi
          
          # Fallback to other locations
          local emulator_path
          emulator_path=$(command -v qemu-system-x86_64 2>/dev/null)
          if [ -n "$emulator_path" ]; then
              echo "$emulator_path"
              return 0
          fi
          
          # Last resort: check qemu-kvm but will use with qemu type
          if [ -x /usr/libexec/qemu-kvm ]; then
              echo "/usr/libexec/qemu-kvm"
              return 0
          fi
        else
          # For KVM, prefer qemu-kvm or qemu-system-x86_64 with KVM support
          if [ -x /usr/libexec/qemu-kvm ]; then
              echo "/usr/libexec/qemu-kvm"
              return 0
          elif [ -x /usr/bin/qemu-system-x86_64 ]; then
              echo "/usr/bin/qemu-system-x86_64"
              return 0
          fi
          
          local emulator_path
          emulator_path=$(command -v qemu-system-x86_64 2>/dev/null)
          if [ -n "$emulator_path" ]; then
              echo "$emulator_path"
              return 0
          fi
        fi
        
        return 1
      }

      # Try to find emulator
      FOUND_PATH=$(find_emulator "$VIRT_TYPE")
      if [ -n "$FOUND_PATH" ]; then
        EMULATOR_PATH="$FOUND_PATH"
        log "✓ Found emulator: $EMULATOR_PATH"
      else
        log_err "No suitable QEMU/KVM emulator found"
        DETECTION_FAILED=true
      fi

      # 3. Handle Detection Failure
      if [ "$DETECTION_FAILED" = true ]; then
        echo ""
        log_err "Cannot proceed without a suitable emulator"
        echo "Quick fix:"
        echo "  Ubuntu/Debian: sudo apt-get update && sudo apt-get install -y qemu-system-x86 qemu-utils"
        echo "  RHEL/CentOS:   sudo yum install -y qemu-kvm"
        exit 1
      fi
      
      # 4. Final verification
      if [ ! -x "$EMULATOR_PATH" ]; then
        log_err "Emulator not executable: $EMULATOR_PATH"
        exit 1
      fi
      
      # 5. Verify emulator supports the virt type
      log "Verifying emulator compatibility..."
      if [ "$VIRT_TYPE" = "kvm" ]; then
        # Double check KVM is actually usable
        if ! "$EMULATOR_PATH" -accel help 2>/dev/null | grep -q "kvm"; then
          log_warn "Emulator does not support KVM acceleration, falling back to QEMU"
          VIRT_TYPE="qemu"
          CAN_USE_KVM=false
        fi
      fi
      
      # 6. Save results
      echo "$VIRT_TYPE" > ${path.module}/.virt_type
      echo "$EMULATOR_PATH" > ${path.module}/.emulator_path
      
      echo ""
      echo "=== Virtualization Configuration ==="
      echo "Type: $VIRT_TYPE"
      echo "Emulator: $EMULATOR_PATH"
      echo "KVM Available: $CAN_USE_KVM"
      echo "==================================="
      
      if [ "$CAN_USE_KVM" = false ]; then
        echo ""
        log_warn "Running in QEMU emulation mode (Slow Performance)"
        if [ -e /dev/kvm ]; then
            echo "  To enable KVM acceleration:"
            echo "    1. Add user to kvm group: sudo usermod -aG kvm $(whoami)"
            echo "    2. Logout and login again"
        else
            echo "  To enable KVM acceleration:"
            echo "    1. Check CPU virtualization: egrep -c '(vmx|svm)' /proc/cpuinfo"
            echo "    2. Enable in BIOS if needed"
            echo "    3. Load KVM module: sudo modprobe kvm && sudo modprobe kvm_intel (or kvm_amd)"
        fi
      fi
      
      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    always_run = timestamp()
  }
}

# ============================================================================
# VERIFY CLOUDINIT CLEANUP (BEFORE CREATING NEW ONE)
# ============================================================================
resource "null_resource" "verify_cloudinit_cleanup" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e

      # Step 1: Check cloud-init status
      LOG_FILE="${path.root}/logs/.cloudinit_verification.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > "$LOG_FILE" 2>&1

      echo "=== Verifying cloudinit volume cleanup ==="
      echo "Timestamp: $(date)"
      
      CLOUDINIT_NAME="cloudinit-${local.sanitized_hostname}.iso"
      POOL_NAME="${var.libvirt_pool_name}"
      VERIFICATION_FAILED=false

      # Wait a bit more to ensure cleanup is complete
      echo "Waiting for cleanup to settle..."
      sleep 3
      
      # Refresh pool to get latest state
      echo "Refreshing storage pool..."
      sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || true
      sleep 2

      # Check if volume still exists
      if sudo virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
        echo "✗ ERROR: Cloudinit volume still exists after cleanup!"
        echo "Volume: $CLOUDINIT_NAME"
        echo "Pool: $POOL_NAME"
        echo ""
        echo "This should not happen. Attempting emergency cleanup..."
        
        # Emergency cleanup
        sudo virsh vol-delete "$CLOUDINIT_NAME" --pool "$POOL_NAME" --force 2>/dev/null || true
        sleep 3

        # Refresh again
        sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || true
        sleep 2

        # Check again
        if sudo virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
          echo "✗ FATAL: Cannot remove existing volume"
          echo "Please manually run:"
          echo "  virsh vol-delete $CLOUDINIT_NAME --pool $POOL_NAME"
          echo "  virsh pool-refresh $POOL_NAME"

          VERIFICATION_FAILED=true
        else
          echo "✓ Emergency cleanup successful"
        fi
      else
        echo "✓ Verified: No conflicting cloudinit volume exists"
      fi
      
      # Final wait before allowing Terraform to proceed
      if [ "$VERIFICATION_FAILED" = false ]; then
        echo "Final synchronization wait..."
        sleep 3
        echo "✓ Verification complete"
      fi
      
      echo "=== Verification Summary ==="
      echo "Verification Failed: $VERIFICATION_FAILED"
      echo "Completed at: $(date)"
      
      # Output summary to console
      {
        if [ "$VERIFICATION_FAILED" = true ]; then
          echo "✗ Cloudinit Verification Failed"
          echo "  Volume still exists: $CLOUDINIT_NAME"
          echo "  Manual cleanup required"
          echo "  Full log: ${path.root}/logs/.cloudinit_verification.log"
        else
          echo "✓ Cloudinit Verification Complete"
          echo "  No volume conflicts detected"
          echo "  Full log: ${path.root}/logs/.cloudinit_verification.log"
        fi
      } >&2
      
      if [ "$VERIFICATION_FAILED" = true ]; then
        exit 1
      fi
      
      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    null_resource.cleanup_cloudinit
  ]
}

# ============================================================================
# DATA SOURCES FOR VIRTUALIZATION DETECTION
# ============================================================================
data "local_file" "virt_type" {
  filename = "${path.module}/.virt_type"
  
  depends_on = [null_resource.detect_virtualization]
}

data "local_file" "emulator_path" {
  filename = "${path.module}/.emulator_path"
  
  depends_on = [null_resource.detect_virtualization]
}

# ============================================================================
# COMPUTED LOCALS (AFTER DATA SOURCES)
# ============================================================================
locals {
  # Read detected configuration from data sources
  detected_virt_type = trimspace(data.local_file.virt_type.content)
  detected_emulator  = trimspace(data.local_file.emulator_path.content)
  
  # Final domain type
  domain_type = local.detected_virt_type
  
  # CPU mode based on detected type
  effective_cpu_mode = local.detected_virt_type == "kvm" ? var.cpu_mode : "custom"
  
  # Extended tags with detected info
  extended_tags = merge(local.common_tags, {
    virt_type = local.domain_type
    emulator  = local.detected_emulator
  })
}

# ============================================================================
# LOCAL VARIABLES - CONSOLIDATED
# ============================================================================
locals {
  # Use pool name directly since we can't use data source
  pool_name = var.libvirt_pool_name

  # Validasi dan parsing IP address
  node_ip = var.vm_ip_address != "" ? (
    can(split("/", var.vm_ip_address)[0]) ? split("/", var.vm_ip_address)[0] : ""
  ) : ""

  # Validasi IP address format
  is_valid_ip = var.vm_ip_address != "" ? can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$", var.vm_ip_address)) : true

  # Format nameservers untuk cloud-init dengan validasi
  nameservers_yaml = length(var.vm_nameservers) > 0 ? jsonencode(var.vm_nameservers) : jsonencode(["8.8.8.8", "8.8.4.4"])

  # Validasi konfigurasi K3s
  is_k3s_server = var.k3s_node_role == "server"
  is_k3s_agent  = var.k3s_node_role == "agent"

  # K3s server URL validation untuk agent nodes
  k3s_server_url_valid = local.is_k3s_agent ? (
    var.k3s_server_url != "" && can(regex("^https?://", var.k3s_server_url))
  ) : true

  # K3s token validation untuk agent nodes
  k3s_token_valid = local.is_k3s_agent ? var.k3s_token != "" : true

  # Timestamp untuk tracking
  deployment_timestamp = timestamp()

  # Resource naming dengan sanitization
  sanitized_hostname = replace(lower(var.vm_hostname), "/[^a-z0-9-]/", "-")

  # UEFI support detection
  uefi_firmware_path = "/usr/share/OVMF/OVMF_CODE.fd"
  use_uefi           = fileexists(local.uefi_firmware_path) && var.enable_uefi

  # Fallback to safe defaults
  domain_type_fallback = "qemu"  # Safe default for systems without KVM access

  # Tags untuk resource management
  common_tags = {
    managed_by  = "terraform"
    environment = "production"
    created_at  = local.deployment_timestamp
    hostname    = var.vm_hostname
  }
}

# ============================================================================
# VALIDATION CHECKS
# ============================================================================
# Pre-flight validation checks - SEMUA PRECONDITION DALAM SATU LIFECYCLE BLOCK
resource "null_resource" "validation" {
  lifecycle {
    # Validasi IP address format
    precondition {
      condition     = local.is_valid_ip
      error_message = "Invalid IP address format. Expected format: x.x.x.x or x.x.x.x/xx"
    }

    # Validasi K3s server URL untuk agent nodes
    precondition {
      condition     = local.k3s_server_url_valid
      error_message = "K3s server URL is required and must start with http:// or https:// for agent nodes"
    }

    # Validasi K3s token untuk agent nodes
    precondition {
      condition     = local.k3s_token_valid
      error_message = "K3s token is required for agent nodes"
    }

    # Validasi hostname
    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.vm_hostname))
      error_message = "Hostname must be valid DNS name (lowercase alphanumeric and hyphens only)"
    }

    # Validasi resource requirements - Memory
    precondition {
      condition     = var.vm_memory >= 2048
      error_message = "VM memory must be at least 2048 MB for Kubernetes workloads"
    }

    # Validasi resource requirements - vCPU
    precondition {
      condition     = var.vm_vcpu >= 2
      error_message = "VM must have at least 2 vCPUs for Kubernetes workloads"
    }
  }

  depends_on = [null_resource.detect_virtualization]
}

# ============================================================================
# KVM CAPABILITY CHECK
# ============================================================================
resource "null_resource" "kvm_check" {
  provisioner "local-exec" {
    command = <<-EOT
      set +e  # Don't exit on error, we want to handle it gracefully
      
      echo "=== Checking KVM Capabilities ==="
      
      # Check if /dev/kvm exists
      if [ -e /dev/kvm ]; then
        echo "✓ /dev/kvm exists"
        
        # Check if user has access to /dev/kvm
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
          echo "✓ User has access to /dev/kvm"
        else
          echo "⚠ User does not have access to /dev/kvm"
          echo "  Add user to kvm group: sudo usermod -aG kvm $USER"
          echo "  Then logout and login again"
        fi
      else
        echo "⚠ /dev/kvm not found - KVM acceleration not available"
        echo "  Will use QEMU emulation (slower performance)"
        echo "  To enable KVM:"
        echo "    1. Check if CPU supports virtualization: egrep -c '(vmx|svm)' /proc/cpuinfo"
        echo "    2. Enable in BIOS if needed"
        echo "    3. Load KVM module: sudo modprobe kvm"
        echo "    4. For Intel: sudo modprobe kvm_intel"
        echo "    5. For AMD: sudo modprobe kvm_amd"
      fi
      
      # Check QEMU/KVM installation
      if command -v qemu-system-x86_64 &>/dev/null; then
        echo "✓ QEMU installed: $(qemu-system-x86_64 --version | head -1)"
      else
        echo "⚠ QEMU not found - attempting to detect alternative installations"
        
        # Check for common QEMU locations
        if command -v /usr/bin/qemu-system-x86_64 &>/dev/null; then
          echo "✓ QEMU found at: /usr/bin/qemu-system-x86_64"
        elif command -v /usr/libexec/qemu-kvm &>/dev/null; then
          echo "✓ QEMU-KVM found at: /usr/libexec/qemu-kvm"
        else
          echo "✗ QEMU not found in standard locations"
          echo "  Please install QEMU/KVM:"
          echo "    Ubuntu/Debian: sudo apt-get install qemu-kvm qemu-system-x86"
          echo "    RHEL/CentOS: sudo yum install qemu-kvm"
          echo ""
          echo "⚠ Continuing deployment - libvirt provider will handle QEMU detection"
        fi
      fi
      
      # Check libvirt
      if command -v virsh &>/dev/null; then
        echo "✓ Libvirt installed: $(virsh --version)"
      else
        echo "✗ Libvirt not found"
        echo "  Please install libvirt:"
        echo "    Ubuntu/Debian: sudo apt-get install libvirt-daemon-system libvirt-clients"
        echo "    RHEL/CentOS: sudo yum install libvirt"
        exit 1
      fi
      
      echo "=== KVM Check Complete ==="
      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [null_resource.validation]
}

# ============================================================================
# STORAGE VOLUMES
# ============================================================================
resource "libvirt_volume" "ubuntu_base_img" {
  name   = "ubuntu-base-img-${local.sanitized_hostname}.qcow2"
  pool   = local.pool_name
  source = var.ubuntu_img_url
  format = "qcow2"

  depends_on = [
    null_resource.pool_management,
    null_resource.validation
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "libvirt_volume" "ubuntu_base" {
  name           = "ubuntu-disk-${local.sanitized_hostname}.qcow2"
  pool           = local.pool_name
  base_volume_id = libvirt_volume.ubuntu_base_img.id
  format         = "qcow2"
  size           = var.vm_disk_size

  depends_on = [libvirt_volume.ubuntu_base_img]

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# CLOUDINIT VOLUME CLEANUP (IMPROVED WITH VERIFICATION)
# ============================================================================
resource "null_resource" "cleanup_cloudinit" {
  provisioner "local-exec" {
    command = <<-EOT
      set +e  # Don't exit on error
      
      # Redirect all output to log file
      LOG_FILE="${path.root}/logs/.cloudinit_cleanup.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > "$LOG_FILE" 2>&1

      echo "=== Checking for existing cloudinit volume ==="
      echo "Timestamp: $(date)"
      
      CLOUDINIT_NAME="cloudinit-${local.sanitized_hostname}.iso"
      POOL_NAME="${var.libvirt_pool_name}"
      MAX_RETRIES=5
      RETRY_COUNT=0
      CLEANUP_NEEDED=false
      CLEANUP_SUCCESS=false
      
      # Function to check if volume exists
      volume_exists() {
        sudo virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1
        return $?
      }
      
      # Check if volume exists
      if volume_exists; then
        CLEANUP_NEEDED=true
        echo "⚠ Found existing cloudinit volume: $CLOUDINIT_NAME"
        echo "Removing old cloudinit volume..."
        
        # Find and stop any VMs using this volume FIRST
        echo "Checking for VMs using this volume..."
        for vm in $(sudo virsh list --all --name); do
          if [ -n "$vm" ]; then
            if sudo virsh domblklist "$vm" 2>/dev/null | grep -q "$CLOUDINIT_NAME"; then
              echo "  Found VM using volume: $vm"
              
              # Check if VM is running
              if sudo virsh list --state-running --name | grep -q "^$vm$"; then
                echo "  Stopping running VM: $vm"
                sudo virsh destroy "$vm" 2>/dev/null || true
                sleep 3
              fi
              
              # Undefine VM to release volume
              echo "  Undefining VM: $vm"
              sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
              sleep 2
            fi
          fi
        done
        
        # Now try to delete the volume with retries
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
          echo "Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES to delete volume..."
          
          if sudo virsh vol-delete "$CLOUDINIT_NAME" --pool "$POOL_NAME" 2>/dev/null; then
            echo "✓ Successfully deleted volume"
            sleep 2
            
            # Verify deletion
            if ! volume_exists; then
              echo "✓ Verified: Volume no longer exists"
              CLEANUP_SUCCESS=true
              break
            else
              echo "⚠ Volume still exists after deletion, retrying..."
            fi
          else
            echo "⚠ Delete command failed, retrying..."
          fi
          
          RETRY_COUNT=$((RETRY_COUNT + 1))
          sleep 2
        done
        
        # Final verification
        if ! $CLEANUP_SUCCESS; then
          echo "✗ Failed to delete volume after $MAX_RETRIES attempts"
          echo "Attempting nuclear option: refresh pool and retry..."
          
          # Refresh pool
          sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || true
          sleep 2
          
          # One last try
          sudo virsh vol-delete "$CLOUDINIT_NAME" --pool "$POOL_NAME" 2>/dev/null || true
          sleep 3
          
          if volume_exists; then
            echo "✗ Volume still exists. Manual intervention may be required."
            echo "Run: virsh vol-delete $CLOUDINIT_NAME --pool $POOL_NAME"

                        # Output error to console
            {
              echo "✗ Cloudinit cleanup failed"
              echo "  Volume: $CLOUDINIT_NAME"
              echo "  Manual cleanup required: virsh vol-delete $CLOUDINIT_NAME --pool $POOL_NAME"
              echo "  Full log: ${path.root}/logs/.cloudinit_cleanup.log"
            } >&2

            exit 1
          fi

          echo "✓ Nuclear option successful"
          CLEANUP_SUCCESS=true
        fi
        
        echo "✓ Cleanup complete"
      else
        echo "✓ No existing cloudinit volume found"
      fi
      
      # CRITICAL: Final wait to ensure filesystem and libvirt state sync
      echo "Waiting for libvirt state synchronization..."
      sleep 5
      
      # Final pool refresh
      sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || true
      
      echo "=== Cleanup Summary ==="
      echo "Cleanup Needed: $CLEANUP_NEEDED"
      if [ "$CLEANUP_NEEDED" = true ]; then
        echo "Cleanup Success: $CLEANUP_SUCCESS"
        echo "Retry Count: $RETRY_COUNT"
      fi
      echo "Completed at: $(date)"
      
      # Output summary to console (redirect back to stderr for visibility)
      {
        if [ "$CLEANUP_NEEDED" = true ]; then
          if [ "$CLEANUP_SUCCESS" = true ]; then
            echo "✓ Cloudinit Cleanup Complete"
            echo "  Removed existing volume: $CLOUDINIT_NAME"
            echo "  Attempts: $RETRY_COUNT"
          fi
        else
          echo "✓ Cloudinit Cleanup Check Complete"
          echo "  No existing volume found"
        fi
        echo "  Full log: ${path.root}/logs/.cloudinit_cleanup.log"
      } >&2

      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    # Run cleanup whenever hostname changes
    hostname = local.sanitized_hostname
  }

  depends_on = [
    null_resource.pool_management,
    null_resource.validation
  ]
}

# ============================================================================
# TIME BUFFER BEFORE CLOUDINIT CREATION
# ============================================================================
resource "time_sleep" "wait_for_cleanup" {
  depends_on = [
    null_resource.verify_cloudinit_cleanup
  ]

  create_duration = "5s"
}

# ============================================================================
# CLOUD-INIT CONFIGURATION
# ============================================================================
data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")

  vars = {
    hostname       = var.vm_hostname
    ssh_key        = file(pathexpand(var.ssh_public_key))
    ssh_user       = var.ssh_username
    k8s_version    = "1.31"
    static_ip      = var.vm_ip_address
    gateway        = var.vm_gateway
    nameservers    = local.nameservers_yaml
    k3s_version    = var.k3s_version
    k3s_role       = var.k3s_node_role
    k3s_server_url = var.k3s_server_url
    k3s_token      = var.k3s_token
    node_ip        = local.node_ip
  }

  depends_on = [null_resource.validation]
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config.cfg")

  depends_on = [null_resource.validation]
}

# ============================================================================
# CLOUDINIT DISK WITH PROPER DEPENDENCIES AND ERROR HANDLING
# ============================================================================
resource "libvirt_cloudinit_disk" "commoninit" {
  name           = "cloudinit-${local.sanitized_hostname}.iso"
  user_data      = data.template_file.user_data.rendered
  network_config = data.template_file.network_config.rendered
  pool           = local.pool_name

  depends_on = [
    null_resource.pool_management,
    null_resource.cleanup_cloudinit,
    null_resource.verify_cloudinit_cleanup,
    null_resource.pre_deployment_check, # Ensure pre-deployment check completes before ISO creation
    time_sleep.wait_for_cleanup,
    data.template_file.user_data,
    data.template_file.network_config
  ]

  lifecycle {
    create_before_destroy = false
    replace_triggered_by = [null_resource.cleanup_cloudinit]
  }
}

# ============================================================================
# PRE-DEPLOYMENT CHECK
# ============================================================================
resource "null_resource" "pre_deployment_check" {
  provisioner "local-exec" {
    command = <<-EOT
      set +e
      
      # Step 1: Initialize logging with absolute paths
      LOG_DIR="${path.root}/logs"
      LOG_FILE="${path.root}/logs/.cloudinit_cleanup.log"
      
      # Ensure log directory exists with correct permissions
      if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        chmod 755 "$LOG_DIR"
      fi
      
      # Redirect all output to log file
      exec > "$LOG_FILE" 2>&1
      
      echo "=== Pre-deployment Validation ==="
      echo "Timestamp: $(date)"
      echo "Working Directory: $(pwd)"
      echo "User: $(whoami)"
      
      # Function to log to both file and stderr (so it shows in terraform output if failed)
      log_error() {
        echo "✗ ERROR: $1" >&2
        echo "✗ ERROR: $1"
      }
      
      # Step 2: Wait for detection files to be created by detect_virtualization
      MAX_WAIT=60
      WAIT_COUNT=0
      echo "Waiting for virtualization detection files in ${path.module}..."
      
      while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if [ -f "${path.module}/.virt_type" ] && [ -f "${path.module}/.emulator_path" ]; then
          echo "✓ Detection files found after $WAIT_COUNT seconds"
          break
        fi
        
        [ $((WAIT_COUNT % 5)) -eq 0 ] && echo "  Waiting... ($WAIT_COUNT/$MAX_WAIT)"
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
      done

      # Step 3: Verify detection results
      if [ ! -f "${path.module}/.virt_type" ] || [ ! -f "${path.module}/.emulator_path" ]; then
        log_error "Virtualization detection files not found after $MAX_WAIT seconds"
        log_error "Expected files in: ${path.module}"
        log_error "Please check ${path.root}/logs/.virt_detection.log for details"
        exit 1
      fi
      
      VIRT_TYPE=$(cat "${path.module}/.virt_type" | tr -d '\n\r')
      EMULATOR=$(cat "${path.module}/.emulator_path" | tr -d '\n\r')
      
      echo "Detected: type=$VIRT_TYPE, emulator=$EMULATOR"

      # Step 4: KVM accessibility check
      if [ "$VIRT_TYPE" = "kvm" ]; then
        if [ ! -w /dev/kvm ]; then
          echo "⚠ KVM type selected but user lacks /dev/kvm access"
          echo "  Current user: $(whoami)"
          echo "  /dev/kvm permissions: $(ls -l /dev/kvm 2>/dev/null || echo 'not found')"
          echo "  Falling back to QEMU emulation"
          echo "qemu" > "${path.module}/.virt_type"
          VIRT_TYPE="qemu"
        else
          echo "✓ KVM available and accessible"
        fi
      fi
      
      # Step 5: Check for volume conflicts
      echo ""
      echo "Checking for volume conflicts..."
      CLOUDINIT_NAME="cloudinit-${local.sanitized_hostname}.iso"
      POOL_NAME="${var.libvirt_pool_name}"

      # Refresh pool to ensure we have the latest state
      echo "Refreshing storage pool '$POOL_NAME'..."
      sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || echo "  Warning: Pool refresh failed"
      
      if sudo virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
        echo "⚠ Found existing cloudinit volume: $CLOUDINIT_NAME"
        echo "  Attempting to resolve conflict..."
        
        # Check if any VM is using it
        USING_VM=$(sudo virsh list --all --name | while read vm; do
          if [ -n "$vm" ] && sudo virsh domblklist "$vm" 2>/dev/null | grep -q "$CLOUDINIT_NAME"; then
            echo "$vm"
            break
          fi
        done)
        
        if [ -n "$USING_VM" ]; then
          echo "  Volume is in use by VM: $USING_VM"
          echo "  Stopping and undefining VM..."
          sudo virsh destroy "$USING_VM" 2>/dev/null || true
          sudo virsh undefine "$USING_VM" --remove-all-storage 2>/dev/null || true
          sleep 2
        fi
        
        # Delete volume
        if sudo virsh vol-delete "$CLOUDINIT_NAME" --pool "$POOL_NAME" 2>/dev/null; then
          echo "  ✓ Volume deleted successfully"
        else
          log_error "Failed to delete conflicting volume: $CLOUDINIT_NAME"
          log_error "Manual fix: virsh vol-delete $CLOUDINIT_NAME --pool $POOL_NAME"
          exit 1
        fi
      fi
      
      # Step 6: Check for existing domain
      echo ""
      echo "Checking for existing domain..."
      DOMAIN_NAME="${local.sanitized_hostname}"
      
      if sudo virsh dominfo "$DOMAIN_NAME" >/dev/null 2>&1; then
        echo "⚠ Domain already exists: $DOMAIN_NAME"
        DOMAIN_STATE=$(sudo virsh domstate "$DOMAIN_NAME" 2>/dev/null || echo "unknown")
        echo "  Current state: $DOMAIN_STATE"
        
        # Check if domain is in Terraform state
        if terraform state list 2>/dev/null | grep -q "libvirt_domain.ubuntu_vm"; then
          echo "  Domain is in Terraform state"
        else
          echo "  Domain NOT in Terraform state"
          echo "  This may cause conflicts during apply"
        fi
      else
        echo "✓ No existing domain found"
      fi

      # Step 7: Verify storage pool exists and is active
      echo ""
      echo "Verifying storage pool status..."
      if ! sudo virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
        log_error "Storage pool '$POOL_NAME' not found"
        log_error "Please ensure the pool is defined and started"
        exit 1
      fi

      if ! sudo virsh pool-list --persistent | grep -q "$POOL_NAME"; then
        echo "⚠ Storage pool '$POOL_NAME' is not active. Attempting to start..."
        if ! sudo virsh pool-start "$POOL_NAME" 2>/dev/null; then
          log_error "Could not start storage pool '$POOL_NAME'"
          exit 1
        fi
      fi

      # Step 8: Verify storage pool has enough space
      echo ""
      echo "Checking storage pool capacity..."
      POOL_INFO=$(sudo virsh pool-info "$POOL_NAME" 2>/dev/null || echo "")
      if [ -n "$POOL_INFO" ]; then
        AVAILABLE=$(echo "$POOL_INFO" | grep "Available:" | awk '{print $2}')
        echo "  Available space: $AVAILABLE"
        
        # Simple check for low space
        if echo "$AVAILABLE" | grep -q "M"; then
          echo "⚠ WARNING: Low disk space in storage pool (< 1GB)"
        fi
      fi

      # Step 9: Final system checks
      if [ ! -x "$EMULATOR" ]; then
        log_error "Emulator not executable: $EMULATOR"
        exit 1
      fi
      
      echo ""
      echo "✓ Pre-deployment validation passed"
      echo "  Virt Type: $VIRT_TYPE"
      echo "  Emulator: $EMULATOR"
      echo "  Domain: $DOMAIN_NAME"
      echo "  Pool: $POOL_NAME"
      echo "Completed at: $(date)"
      
      # Output summary to console
      {
        echo "✓ Pre-deployment Check Complete"
        echo "  Type: $VIRT_TYPE | Emulator: $EMULATOR"
        echo "  Log: ${path.root}/logs/.pre_deployment_check.log"
      } >&2
      
      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    # Re-run on hostname change
    hostname = local.sanitized_hostname
    # Use timestamp of detection resource instead of file hash
    detection_id = null_resource.detect_virtualization.id
  }

  depends_on = [
    null_resource.detect_virtualization,
    null_resource.validation,
    null_resource.cleanup_cloudinit,
    null_resource.verify_cloudinit_cleanup,
    time_sleep.wait_for_cleanup, # Wait for cleanup to settle before final pre-deployment check
    data.local_file.virt_type,
    data.local_file.emulator_path
  ]
}

# ============================================================================
# VIRTUAL MACHINE DOMAIN
# ============================================================================
resource "libvirt_domain" "ubuntu_vm" {
  name   = local.sanitized_hostname
  memory = var.vm_memory
  vcpu   = var.vm_vcpu

  # Domain type (kvm or qemu) - CRITICAL: use detected type
  type = local.domain_type

  # Emulator - FIXED: only set if detected AND compatible with domain type
  # Let libvirt auto-detect if we don't have a compatible emulator
  emulator = (
    local.detected_emulator != "" && 
    fileexists(local.detected_emulator)
  ) ? local.detected_emulator : null

  # CPU Configuration untuk performa optimal
  cpu {
    mode = local.effective_cpu_mode
  }

  # Machine type untuk kompatibilitas
  machine = local.use_uefi ? "q35" : "pc"
  arch    = "x86_64"

  # Firmware - conditional UEFI
  firmware = local.use_uefi ? local.uefi_firmware_path : null

  # QEMU Agent untuk monitoring (Disabled to prevent plan failure if agent is slow)
  qemu_agent = false

  # Autostart
  autostart = var.autostart

  # Cloud-init
  cloudinit = libvirt_cloudinit_disk.commoninit.id

  # Network Interface dengan error handling
  network_interface {
    network_name   = var.network_name
    addresses      = var.vm_ip_address != "" ? [local.node_ip] : null
    wait_for_lease = var.vm_ip_address == "" ? true : false

    # MAC address untuk DHCP reservation consistency
    mac = var.vm_mac_address != "" ? var.vm_mac_address : null
  }

  # Boot Disk
  disk {
    volume_id = libvirt_volume.ubuntu_base.id
    scsi      = false
  }

  # Serial Console untuk debugging
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  # VNC Console untuk remote access
  graphics {
    type           = "vnc"
    listen_type    = "address"
    listen_address = "0.0.0.0"
  }

  # Video adapter
  video {
    type = "virtio"
  }

  # Dependencies - FIXED: Strict ordering to avoid race conditions with cloudinit ISO
  depends_on = [
    libvirt_volume.ubuntu_base,
    libvirt_cloudinit_disk.commoninit,
    null_resource.validation,
    null_resource.kvm_check,
    null_resource.detect_virtualization,
    null_resource.pre_deployment_check,
    data.local_file.virt_type,
    data.local_file.emulator_path
  ]

  # Lifecycle management
  lifecycle {
    # Prevent accidental destruction
    prevent_destroy = false
    # Create before destroy to minimize downtime
    create_before_destroy = false
    ignore_changes = [
      network_interface[0].addresses,
      qemu_agent,
    ]
  }

  # Timeouts untuk operasi yang lama
  timeouts {
    create = "15m"
  }
}

# ============================================================================
# POST-DEPLOYMENT VERIFICATION (ENHANCED WITH COMPREHENSIVE DIAGNOSTICS)
# ============================================================================
resource "null_resource" "health_check" {
  depends_on = [libvirt_domain.ubuntu_vm]

  provisioner "local-exec" {
    command = <<-EOT
      export LOG_FILE="${path.root}/logs/.health_check.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      bash "${path.module}/scripts/health_check.sh" \
        "${local.sanitized_hostname}" \
        "${var.vm_hostname}" \
        "${local.sanitized_hostname}" \
        "${var.vm_ip_address}" \
        "${local.node_ip}" \
        "${var.ssh_username}" \
        "${var.network_name}" \
        "${var.libvirt_pool_name}"
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }

  triggers = {
    vm_id = libvirt_domain.ubuntu_vm.id
    timestamp = timestamp()
  }
}


# ============================================================================
# SSH READINESS CHECK (OPTIONAL - RUNS AFTER HEALTH CHECK)
# ============================================================================
resource "null_resource" "wait_for_ssh" {
  count = var.wait_for_ssh ? 1 : 0
  
  depends_on = [null_resource.health_check]

  provisioner "local-exec" {
    command = <<-EOT
      bash "${path.module}/scripts/wait_for_ssh.sh" \
        "${local.sanitized_hostname}" \
        "${local.node_ip}" \
        "${var.ssh_username}"
    EOT

    on_failure = continue
  }

  triggers = {
    vm_id = libvirt_domain.ubuntu_vm.id
  }
}