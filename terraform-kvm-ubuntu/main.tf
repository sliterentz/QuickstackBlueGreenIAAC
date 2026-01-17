
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
      if virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
        echo "✓ Pool '$POOL_NAME' already exists."
        
        # Cek apakah pool aktif (running)
        if ! virsh pool-list --active | grep -q "$POOL_NAME"; then
             echo "Starting pool '$POOL_NAME'..."
             virsh pool-start "$POOL_NAME"
        else
             echo "✓ Pool '$POOL_NAME' is active."
        fi
      else
        echo "Pool '$POOL_NAME' does not exist. Creating..."
        # Define, Build, Start, Autostart
        virsh pool-define-as --name "$POOL_NAME" --type dir --target "$POOL_PATH"
        virsh pool-build "$POOL_NAME"
        virsh pool-start "$POOL_NAME"
        virsh pool-autostart "$POOL_NAME"
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
      LOG_FILE="${path.module}/.virt_detection.log"
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

      # Redirect all output to log file
      LOG_FILE="${path.module}/.cloudinit_verification.log"
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
          echo "  Full log: ${path.module}/.cloudinit_verification.log"
        else
          echo "✓ Cloudinit Verification Complete"
          echo "  No volume conflicts detected"
          echo "  Full log: ${path.module}/.cloudinit_verification.log"
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
      LOG_FILE="${path.module}/.cloudinit_cleanup.log"
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
        for vm in $(virsh list --all --name); do
          if [ -n "$vm" ]; then
            if virsh domblklist "$vm" 2>/dev/null | grep -q "$CLOUDINIT_NAME"; then
              echo "  Found VM using volume: $vm"
              
              # Check if VM is running
              if virsh list --state-running --name | grep -q "^$vm$"; then
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
              echo "  Full log: ${path.module}/.cloudinit_cleanup.log"
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
        echo "  Full log: ${path.module}/.cloudinit_cleanup.log"
      } >&2

      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    # Run cleanup whenever hostname changes
    hostname = local.sanitized_hostname
    # Always run on apply
    timestamp = timestamp()
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
    ssh_key        = var.ssh_public_key
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
    time_sleep.wait_for_cleanup,
    data.template_file.user_data,
    data.template_file.network_config
  ]

  lifecycle {
    create_before_destroy = false
  }
}

# ============================================================================
# PRE-DEPLOYMENT CHECK
# ============================================================================
resource "null_resource" "pre_deployment_check" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=== Pre-deployment Validation ==="
      
      # Read detected configuration
      if [ ! -f "${path.module}/.virt_type" ]; then
        echo "✗ Virtualization type file not found"
        exit 1
      fi
      
      if [ ! -f "${path.module}/.emulator_path" ]; then
        echo "✗ Emulator path file not found"
        exit 1
      fi
      
      VIRT_TYPE=$(cat ${path.module}/.virt_type)
      EMULATOR=$(cat ${path.module}/.emulator_path)
      
      echo "Detected Configuration:"
      echo "  Virt Type: $VIRT_TYPE"
      echo "  Emulator: $EMULATOR"
      
      # Validate configuration
      if [ -z "$VIRT_TYPE" ]; then
        echo "✗ Virtualization type is empty"
        exit 1
      fi
      
      if [ -z "$EMULATOR" ]; then
        echo "✗ Emulator path is empty"
        exit 1
      fi
      
      if [ ! -x "$EMULATOR" ]; then
        echo "✗ Emulator not executable: $EMULATOR"
        exit 1
      fi
      
      # Test emulator
      echo "Testing emulator..."
      if ! "$EMULATOR" --version >/dev/null 2>&1; then
        echo "✗ Emulator test failed"
        exit 1
      fi
      
      # Verify virt type compatibility
      echo "Verifying virt type compatibility..."
      if [ "$VIRT_TYPE" = "kvm" ]; then
        if [ ! -e /dev/kvm ]; then
          echo "✗ KVM type selected but /dev/kvm not found"
          exit 1
        fi
        if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
          echo "✗ KVM type selected but user lacks /dev/kvm access"
          exit 1
        fi
      fi

      # ADDED: Check for volume conflicts
      echo ""
      echo "Checking for volume conflicts..."
      CLOUDINIT_NAME="cloudinit-${local.sanitized_hostname}.iso"
      POOL_NAME="${var.libvirt_pool_name}"

      if virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
        echo "✗ CRITICAL: Cloudinit volume still exists!"
        echo "  Volume: $CLOUDINIT_NAME"
        echo "  Pool: $POOL_NAME"
        echo ""
        echo "Emergency cleanup..."
        
        # Last ditch effort
        virsh vol-delete "$CLOUDINIT_NAME" --pool "$POOL_NAME" 2>/dev/null || true
        sleep 3
        
        # Final check
        if virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
          echo "✗ FATAL: Cannot proceed with existing volume"
          echo "Please manually remove:"
          echo "  virsh vol-delete $CLOUDINIT_NAME --pool $POOL_NAME"
          exit 1
        fi
        
        echo "✓ Emergency cleanup successful"
      else
        echo "✓ No volume conflicts detected"
      fi

      echo "✓ Pre-deployment validation passed"
      echo "  Will use: $VIRT_TYPE with $EMULATOR"
      exit 0
    EOT
    
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    null_resource.detect_virtualization,
    null_resource.validation,
    null_resource.cleanup_cloudinit,
    null_resource.verify_cloudinit_cleanup
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

  # QEMU Agent untuk monitoring
  qemu_agent = true

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

  # Dependencies
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
      set +e  # Don't exit on error, we want to collect diagnostics

      # Redirect detailed output to log file
      LOG_FILE="${path.module}/.health_check.log"
      exec > >(tee -a "$LOG_FILE") 2>&1

      echo "=== Deployment Health Check ==="
      echo "Timestamp: $(date)"
      echo "Hostname: ${var.vm_hostname}"
      echo "Sanitized Name: ${local.sanitized_hostname}"

      # FIXED: Properly display IP address variables
      RAW_IP_ADDRESS="${var.vm_ip_address}"
      NODE_IP="${local.node_ip}"

      echo "IP Address (raw): $RAW_IP_ADDRESS"
      echo "Node IP (parsed): $NODE_IP"
      echo "Domain Type: ${local.domain_type}"
      echo "Emulator: ${local.detected_emulator}"
      echo ""
      
      # FIXED: Extract IP properly if not already done
      if [ -z "$NODE_IP" ] && [ -n "$RAW_IP_ADDRESS" ]; then
        # Extract IP from CIDR notation if present
        NODE_IP=$(echo "$RAW_IP_ADDRESS" | cut -d'/' -f1)
        echo "Extracted Node IP: $NODE_IP"
      fi

      VM_NAME="${local.sanitized_hostname}"
      TARGET_IP="$NODE_IP"
      SSH_USER="${var.ssh_username}"
      MAX_WAIT=300  # 5 minutes
      ELAPSED=0
      
      # Validate variables
      if [ -z "$VM_NAME" ]; then
        echo "✗ CRITICAL: VM_NAME is empty"
        exit 1
      fi
      
      echo "VM Name to check: $VM_NAME"
      echo ""

      # ========================================================================
      # PHASE 0: LIBVIRT CONNECTION CHECK
      # ========================================================================
      echo "=== Phase 0: Libvirt Connection Check ==="
      
      # Check if we can connect to libvirt
      if ! virsh version >/dev/null 2>&1; then
        echo "✗ Cannot connect to libvirt"
        echo "Checking libvirt service status..."
        sudo systemctl status libvirtd --no-pager || true
        echo ""
        echo "Attempting to start libvirtd..."
        sudo systemctl start libvirtd || true
        sleep 3
        
        if ! virsh version >/dev/null 2>&1; then
          echo "✗ Still cannot connect to libvirt"
          exit 1
        fi
      fi
      
      echo "✓ Libvirt connection OK"
      echo "Libvirt version: $(virsh version | head -1)"
      echo ""
      
      # Check user permissions
      CURRENT_USER=$(whoami)
      echo "Current user: $CURRENT_USER"
      echo "User groups: $(groups)"
      
      if ! groups | grep -q libvirt; then
        echo "⚠ WARNING: User '$CURRENT_USER' is not in 'libvirt' group"
        echo "  This may cause permission issues"
        echo "  To fix: sudo usermod -aG libvirt $CURRENT_USER && newgrp libvirt"
      fi
      echo ""

      # ========================================================================
      # PHASE 1: VM EXISTENCE AND STATE CHECK
      # ========================================================================
      echo "=== Phase 1: VM Existence Check ==="
      
      # FIXED: Use sudo for virsh commands if needed
      VIRSH_CMD="virsh"
      if ! virsh list --all >/dev/null 2>&1; then
        echo "⚠ Permission denied, trying with sudo..."
        VIRSH_CMD="sudo virsh"
      fi
      
      echo "Listing all VMs..."
      $VIRSH_CMD list --all
      echo ""
      
      # FIXED: More robust VM existence check
      VM_EXISTS=false
      if $VIRSH_CMD list --all --name | grep -q "^$VM_NAME$"; then
        VM_EXISTS=true
        echo "✓ VM '$VM_NAME' exists"
      else
        echo "✗ CRITICAL: VM '$VM_NAME' not found in virsh list"
        echo ""
        echo "Available VMs:"
        $VIRSH_CMD list --all --name
        echo ""
        echo "Searching for similar VM names..."
        $VIRSH_CMD list --all --name | grep -i "$(echo $VM_NAME | cut -d'-' -f1)" || echo "No similar VMs found"
        echo ""
        
        # Check if VM was just created
        echo "Waiting 10 seconds for VM to register..."
        sleep 10
        
        if $VIRSH_CMD list --all --name | grep -q "^$VM_NAME$"; then
          VM_EXISTS=true
          echo "✓ VM '$VM_NAME' now exists"
        else
          echo "✗ VM still not found after waiting"
          echo ""
          echo "Possible causes:"
          echo "  1. VM creation failed"
          echo "  2. Name mismatch (check sanitized_hostname)"
          echo "  3. Libvirt state not synchronized"
          echo ""
          echo "Troubleshooting:"
          echo "  - Check Terraform state: terraform show"
          echo "  - Refresh libvirt pool: virsh pool-refresh ${var.libvirt_pool_name}"
          echo "  - Check libvirt logs: sudo journalctl -u libvirtd -n 50"
          exit 1
        fi
      fi
      
      # ========================================================================
      # PHASE 2: WAIT FOR VM TO START
      # ========================================================================
      echo ""
      echo "=== Phase 2: Waiting for VM to Start ==="
      echo "Waiting up to $MAX_WAIT seconds..."
      
      while [ $ELAPSED -lt $MAX_WAIT ]; do
        if $VIRSH_CMD list --state-running --name | grep -q "^$VM_NAME$"; then
          echo "✓ VM is running (waited $ELAPSED seconds)"
          break
        fi
        
        # Check VM state
        VM_STATE=$($VIRSH_CMD domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        
        if [ "$VM_STATE" = "shut off" ] || [ "$VM_STATE" = "crashed" ]; then
          echo "⚠ VM is in '$VM_STATE' state, attempting to start..."
          $VIRSH_CMD start "$VM_NAME" 2>&1 || true
          sleep 5
        fi
        
        if [ $((ELAPSED % 10)) -eq 0 ]; then
          echo "  Still waiting... ($ELAPSED/$MAX_WAIT seconds) - State: $VM_STATE"
        fi
        
        sleep 2
        ELAPSED=$((ELAPSED + 2))
      done
      
      # Final check
      if ! $VIRSH_CMD list --state-running --name | grep -q "^$VM_NAME$"; then
        echo "✗ VM failed to start within $MAX_WAIT seconds"
        echo ""
        echo "VM State:"
        $VIRSH_CMD domstate "$VM_NAME"
        echo ""
        echo "VM Info:"
        $VIRSH_CMD dominfo "$VM_NAME"
        echo ""
        echo "Last 20 lines of VM console log:"
        $VIRSH_CMD console "$VM_NAME" --force 2>&1 | tail -20 || echo "Cannot access console"
        echo ""
        echo "Attempting final start..."
        $VIRSH_CMD start "$VM_NAME" 2>&1 || true
        sleep 10
        
        if ! $VIRSH_CMD list --state-running --name | grep -q "^$VM_NAME$"; then
          echo "✗ Failed to start VM after all attempts"
          echo ""
          echo "Please check:"
          echo "  1. Libvirt logs: sudo journalctl -u libvirtd -n 100"
          echo "  2. VM definition: virsh dumpxml $VM_NAME"
          echo "  3. Storage pool: virsh pool-list --all"
          echo "  4. Available resources: free -h && df -h"
          exit 1
        fi
        
        echo "✓ VM started successfully after retry"
      fi
      
      # ========================================================================
      # PHASE 3: VM DETAILS AND DIAGNOSTICS
      # ========================================================================
      echo ""
      echo "=== Phase 3: VM Details ==="
      
      echo "VM State:"
      $VIRSH_CMD domstate "$VM_NAME"
      echo ""
      
      echo "VM Info:"
      $VIRSH_CMD dominfo "$VM_NAME" | grep -E "(State|CPU|Memory|UUID)"
      echo ""
      
      echo "VM Network Interfaces:"
      $VIRSH_CMD domiflist "$VM_NAME"
      echo ""
      
      echo "VM IP Addresses (from QEMU agent):"
      $VIRSH_CMD domifaddr "$VM_NAME" --source agent 2>/dev/null || echo "  QEMU agent not ready yet"
      echo ""
      
      echo "VM IP Addresses (from lease):"
      $VIRSH_CMD domifaddr "$VM_NAME" --source lease 2>/dev/null || echo "  No DHCP lease found"
      echo ""
      
      # ========================================================================
      # PHASE 4: NETWORK CONNECTIVITY CHECK
      # ========================================================================
      echo "=== Phase 4: Network Connectivity ==="
      
      if [ -z "$TARGET_IP" ]; then
        echo "⚠ No static IP configured, attempting to detect..."
        echo ""
        
        # Try multiple methods to get IP
        echo "Method 1: Checking QEMU agent..."
        DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source agent 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)
        
        if [ -z "$DETECTED_IP" ]; then
          echo "  QEMU agent not available"
          echo ""
          echo "Method 2: Checking DHCP lease..."
          DETECTED_IP=$($VIRSH_CMD domifaddr "$VM_NAME" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)
        fi
        
        if [ -z "$DETECTED_IP" ]; then
          echo "  No DHCP lease found"
          echo ""
          echo "Method 3: Checking ARP table..."
          VM_MAC=$($VIRSH_CMD domiflist "$VM_NAME" | grep -oP '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
          if [ -n "$VM_MAC" ]; then
            echo "  VM MAC: $VM_MAC"
            DETECTED_IP=$(arp -n | grep "$VM_MAC" | awk '{print $1}' | head -1)
          fi
        fi
        
        if [ -n "$DETECTED_IP" ]; then
          echo "✓ Detected IP: $DETECTED_IP"
          TARGET_IP="$DETECTED_IP"
        else
          echo "⚠ Could not detect IP address automatically"
          echo ""
          echo "The VM may be using DHCP and the IP is not yet assigned."
          echo "Please wait a few moments and check manually:"
          echo "  virsh domifaddr $VM_NAME"
          echo ""
          echo "Or access via console:"
          echo "  virsh console $VM_NAME"
          echo "  (then run: ip addr show)"
        fi
      fi
      
      if [ -n "$TARGET_IP" ]; then
        echo ""
        echo "Testing connectivity to $TARGET_IP..."
        
        # Wait for network to be ready
        NETWORK_WAIT=0
        NETWORK_MAX_WAIT=120
        NETWORK_READY=false
        
        while [ $NETWORK_WAIT -lt $NETWORK_MAX_WAIT ]; do
          if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
            echo "✓ Network is reachable (waited $NETWORK_WAIT seconds)"
            NETWORK_READY=true
            break
          fi
          
          if [ $((NETWORK_WAIT % 10)) -eq 0 ]; then
            echo "  Waiting for network... ($NETWORK_WAIT/$NETWORK_MAX_WAIT seconds)"
          fi
          
          sleep 2
          NETWORK_WAIT=$((NETWORK_WAIT + 2))
        done
        
        if [ "$NETWORK_READY" = false ]; then
          echo "✗ Network not reachable after $NETWORK_MAX_WAIT seconds"
          echo ""
          echo "Network Diagnostics:"
          echo ""
          echo "Host network interfaces:"
          ip addr show | grep -E "(^[0-9]|inet )" || true
          echo ""
          echo "Libvirt networks:"
          $VIRSH_CMD net-list --all
          echo ""
          echo "Network details:"
          $VIRSH_CMD net-info ${var.network_name} 2>/dev/null || echo "  Network '${var.network_name}' not found"
          echo ""
          echo "Bridge status:"
          brctl show 2>/dev/null || ip link show type bridge || echo "  Cannot show bridge info"
          echo ""
          echo "Troubleshooting steps:"
          echo "  1. Check if libvirt network is active:"
          echo "     virsh net-start ${var.network_name}"
          echo "  2. Check VM console for network errors:"
          echo "     virsh console $VM_NAME"
          echo "  3. Check host firewall rules:"
          echo "     sudo iptables -L -n -v"
          echo "  4. Restart libvirt network:"
          echo "     virsh net-destroy ${var.network_name} && virsh net-start ${var.network_name}"
        fi
      fi

      # ========================================================================
      # PHASE 5: CLOUD-INIT STATUS CHECK
      # ========================================================================
      echo ""
      echo "=== Phase 5: Cloud-Init Status ==="
      
      if [ -n "$TARGET_IP" ] && [ "$NETWORK_READY" = true ]; then
        echo "Checking cloud-init status..."
        echo "(This requires SSH access, may take a moment)"
        echo ""
        
        # Wait a bit for SSH to be ready
        sleep 10
        
        # Try to check cloud-init status via SSH
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
        
        if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "cloud-init status" 2>/dev/null; then
          echo "✓ Cloud-init status retrieved"
        else
          echo "⚠ Cannot retrieve cloud-init status yet"
          echo "  This is normal during initial boot"
          echo "  Cloud-init may still be running"
        fi
      else
        echo "⚠ Skipping cloud-init check (network not ready)"
      fi
      
      # ========================================================================
      # PHASE 6: SSH CONNECTIVITY TEST
      # ========================================================================
      echo ""
      echo "=== Phase 6: SSH Connectivity ==="
      
      if [ -n "$TARGET_IP" ] && [ "$NETWORK_READY" = true ]; then
        echo "Testing SSH connectivity to $SSH_USER@$TARGET_IP..."
        
        SSH_WAIT=0
        SSH_MAX_WAIT=180  # 3 minutes for SSH to be ready
        SSH_READY=false
        
        while [ $SSH_WAIT -lt $SSH_MAX_WAIT ]; do
          if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes \
             "$SSH_USER@$TARGET_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
            echo "✓ SSH is accessible (waited $SSH_WAIT seconds)"
            SSH_READY=true
            
            # Get some basic info
            echo ""
            echo "VM System Info:"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
                "$SSH_USER@$TARGET_IP" "hostname; uname -a; uptime" 2>/dev/null || true
            
            break
          fi
          
          if [ $((SSH_WAIT % 15)) -eq 0 ]; then
            echo "  Waiting for SSH... ($SSH_WAIT/$SSH_MAX_WAIT seconds)"
            
            # Check if port 22 is open
            if [ $((SSH_WAIT % 30)) -eq 0 ]; then
              if nc -zv -w 2 "$TARGET_IP" 22 2>&1 | grep -q "succeeded\|open"; then
                echo "  Port 22 is open, SSH service may be starting..."
              else
                echo "  Port 22 not yet open..."
              fi
            fi
          fi
          
          sleep 3
          SSH_WAIT=$((SSH_WAIT + 3))
        done
        
        if [ "$SSH_READY" = false ]; then
          echo "✗ SSH not accessible after $SSH_MAX_WAIT seconds"
          echo ""
          echo "SSH Troubleshooting:"
          echo "  1. Check if SSH service is running in VM:"
          echo "     virsh console $VM_NAME"
          echo "     (then run: sudo systemctl status ssh)"
          echo ""
          echo "  2. Verify SSH key is correctly configured"
          echo "     Check cloud-init logs in VM: /var/log/cloud-init.log"
          echo ""
          echo "  3. Check VM console for errors:"
          echo "     virsh console $VM_NAME"
          echo ""
          echo "  4. Check cloud-init output:"
          echo "     tail -f /var/log/cloud-init-output.log"
          echo ""
          echo "  5. Verify firewall settings in VM:"
          echo "     sudo ufw status"
        fi
      else
        echo "⚠ Skipping SSH test (network not ready)"
      fi
      
      # ========================================================================
      # PHASE 7: CONSOLE ACCESS INFO
      # ========================================================================
      echo ""
      echo "=== Phase 7: Console Access ==="
      echo "If SSH is not working, you can access the VM console:"
      echo "  virsh console $VM_NAME"
      echo "  (Press Ctrl+] to exit console)"
      echo ""
      echo "Or use VNC:"
      VNC_PORT=$($VIRSH_CMD vncdisplay "$VM_NAME" 2>/dev/null | cut -d: -f2)
      if [ -n "$VNC_PORT" ]; then
        VNC_FULL_PORT=$((5900 + VNC_PORT))
        echo "  VNC Display: :$VNC_PORT"
        echo "  VNC Port: $VNC_FULL_PORT"
        echo "  Connect with: vncviewer localhost:$VNC_FULL_PORT"
        echo "  Or: vncviewer localhost:$VNC_PORT"
      else
        echo "  VNC not available"
      fi
      
      # ========================================================================
      # SUMMARY
      # ========================================================================
      echo ""
      echo "=== Health Check Summary ==="
      echo "VM Name: $VM_NAME"
      echo "VM State: $($VIRSH_CMD domstate "$VM_NAME")"
      
      if [ -n "$TARGET_IP" ]; then
        echo "IP Address: $TARGET_IP"
        
        if [ "$NETWORK_READY" = true ]; then
          echo "Network: ✓ Reachable"
        else
          echo "Network: ✗ Not reachable"
        fi
        
        if [ "$SSH_READY" = true ]; then
          echo "SSH: ✓ Accessible"
        else
          echo "SSH: ✗ Not accessible yet"
        fi
      else
        echo "IP Address: Not configured/detected (DHCP pending)"
      fi
      
      echo ""
      echo "=== Next Steps ==="
      echo ""
      
      if [ -n "$TARGET_IP" ] && [ "$SSH_READY" = true ]; then
        echo "✓ VM is ready for use!"
        echo ""
        echo "Connect to VM:"
        echo "  ssh $SSH_USER@$TARGET_IP"
        echo ""
        echo "Check cloud-init status:"
        echo "  ssh $SSH_USER@$TARGET_IP 'cloud-init status --wait'"
        echo ""
        echo "Check K3s status (if installed):"
        echo "  ssh $SSH_USER@$TARGET_IP 'sudo kubectl get nodes'"
        echo ""
        echo "View cloud-init logs:"
        echo "  ssh $SSH_USER@$TARGET_IP 'sudo tail -f /var/log/cloud-init-output.log'"
      elif [ -n "$TARGET_IP" ] && [ "$NETWORK_READY" = true ]; then
        echo "⚠ VM is running but SSH is not ready yet"
        echo ""
        echo "Wait for cloud-init to complete (typically 2-5 minutes):"
        echo "  watch -n 5 'ssh -o ConnectTimeout=5 $SSH_USER@$TARGET_IP \"cloud-init status\"'"
        echo ""
        echo "Or check VM console:"
        echo "  virsh console $VM_NAME"
        echo ""
        echo "Monitor cloud-init progress:"
        echo "  ssh $SSH_USER@$TARGET_IP 'tail -f /var/log/cloud-init-output.log'"
        echo ""
        echo "Check if SSH service is running:"
        echo "  ssh $SSH_USER@$TARGET_IP 'sudo systemctl status ssh'"
      elif [ -n "$TARGET_IP" ]; then
        echo "⚠ VM is running but network is not reachable"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Check VM console for network errors:"
        echo "     virsh console $VM_NAME"
        echo ""
        echo "  2. Verify network configuration:"
        echo "     virsh net-list --all"
        echo "     virsh net-info ${var.network_name}"
        echo ""
        echo "  3. Check if network is active:"
        echo "     virsh net-start ${var.network_name}"
        echo ""
        echo "  4. Restart VM if needed:"
        echo "     virsh reboot $VM_NAME"
      else
        echo "⚠ VM is running but IP address not detected"
        echo ""
        echo "Get VM IP address:"
        echo "  virsh domifaddr $VM_NAME --source agent"
        echo "  virsh domifaddr $VM_NAME --source lease"
        echo ""
        echo "Or access via console to check network:"
        echo "  virsh console $VM_NAME"
        echo "  (then run: ip addr show)"
        echo ""
        echo "Wait a few moments for DHCP lease, then retry:"
        echo "  sleep 30 && virsh domifaddr $VM_NAME"
      fi
      
      echo ""
      echo "=== Troubleshooting Commands ==="
      echo ""
      echo "Check VM status:"
      echo "  virsh dominfo $VM_NAME"
      echo "  virsh domstate $VM_NAME"
      echo ""
      echo "Check VM console output:"
      echo "  virsh console $VM_NAME"
      echo ""
      echo "Check VM network:"
      echo "  virsh domifaddr $VM_NAME --source agent"
      echo "  virsh domifaddr $VM_NAME --source lease"
      echo "  virsh domiflist $VM_NAME"
      echo ""
      echo "Check libvirt network:"
      echo "  virsh net-list --all"
      echo "  virsh net-info ${var.network_name}"
      echo ""
      echo "Restart VM if needed:"
      echo "  virsh reboot $VM_NAME"
      echo ""
      echo "Force stop and start:"
      echo "  virsh destroy $VM_NAME && virsh start $VM_NAME"
      echo ""
      echo "Check libvirt logs:"
      echo "  sudo journalctl -u libvirtd -n 100 --no-pager"
      echo ""
      echo "Full health check log available at:"
      echo "  $LOG_FILE"
      echo ""
      echo "=== Health Check Complete ==="
      
      # Return success even if SSH is not ready yet
      # The VM is deployed and running, SSH may just need more time
      exit 0
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
      set +e
      
      echo "=== Waiting for SSH to be Ready ==="
      echo "This may take 2-5 minutes for cloud-init to complete..."
      echo ""
      
      TARGET_IP="${local.node_ip}"
      SSH_USER="${var.ssh_username}"
      MAX_WAIT=600  # 10 minutes
      ELAPSED=0
      
      if [ -z "$TARGET_IP" ]; then
        echo "⚠ No IP address configured, attempting to detect..."
        
        # Try to get IP from virsh
        for i in {1..30}; do
          DETECTED_IP=$(virsh domifaddr "${local.sanitized_hostname}" --source lease 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)
          
          if [ -n "$DETECTED_IP" ]; then
            echo "✓ Detected IP: $DETECTED_IP"
            TARGET_IP="$DETECTED_IP"
            break
          fi
          
          echo "  Attempt $i/30: Waiting for IP address..."
          sleep 5
        done
        
        if [ -z "$TARGET_IP" ]; then
          echo "✗ Could not detect IP address"
          echo "Please check manually: virsh domifaddr ${local.sanitized_hostname}"
          exit 1
        fi
      fi
      
      echo "Target: $SSH_USER@$TARGET_IP"
      echo "Timeout: $MAX_WAIT seconds"
      echo ""
      
      # Wait for network first
      echo "Waiting for network connectivity..."
      NETWORK_READY=false
      
      for i in {1..60}; do
        if ping -c 1 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
          echo "✓ Network is reachable"
          NETWORK_READY=true
          break
        fi
        
        if [ $((i % 10)) -eq 0 ]; then
          echo "  Still waiting for network... ($i/60)"
        fi
        
        sleep 2
      done
      
      if [ "$NETWORK_READY" = false ]; then
        echo "✗ Network not reachable after 120 seconds"
        exit 1
      fi
      
      # Wait for SSH
      echo ""
      echo "Waiting for SSH service..."
      
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes"
      
      while [ $ELAPSED -lt $MAX_WAIT ]; do
        if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "echo 'SSH Ready'" >/dev/null 2>&1; then
          echo "✓ SSH is ready! (waited $ELAPSED seconds)"
          echo ""
          
          # Get system info
          echo "=== VM System Information ==="
          ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "hostname; uname -a; uptime" 2>/dev/null
          echo ""
          
          # Check cloud-init status
          echo "=== Cloud-Init Status ==="
          ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "cloud-init status" 2>/dev/null || echo "Cloud-init status not available"
          echo ""
          
          # Check if K3s is installed
          if ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "command -v kubectl" >/dev/null 2>&1; then
            echo "=== K3s Status ==="
            ssh $SSH_OPTS "$SSH_USER@$TARGET_IP" "sudo kubectl get nodes 2>/dev/null" || echo "K3s not ready yet"
            echo ""
          fi
          
          echo "✓ VM is fully accessible via SSH"
          echo ""
          echo "Connect now:"
          echo "  ssh $SSH_USER@$TARGET_IP"
          
          exit 0
        fi
        
        if [ $((ELAPSED % 30)) -eq 0 ]; then
          echo "  Still waiting for SSH... ($ELAPSED/$MAX_WAIT seconds)"
          
          # Show what's happening
          if [ $((ELAPSED % 60)) -eq 0 ]; then
            echo "  Checking SSH port..."
            nc -zv -w 2 "$TARGET_IP" 22 2>&1 | grep -E "(succeeded|open)" || echo "    Port 22 not open yet"
          fi
        fi
        
        sleep 5
        ELAPSED=$((ELAPSED + 5))
      done
      
      echo ""
      echo "✗ SSH not ready after $MAX_WAIT seconds"
      echo ""
      echo "Troubleshooting steps:"
      echo "  1. Check VM console: virsh console ${local.sanitized_hostname}"
      echo "  2. Check cloud-init logs: ssh $SSH_USER@$TARGET_IP 'tail -100 /var/log/cloud-init-output.log'"
      echo "  3. Check SSH service: ssh $SSH_USER@$TARGET_IP 'sudo systemctl status ssh'"
      echo "  4. Check firewall: ssh $SSH_USER@$TARGET_IP 'sudo ufw status'"
      echo ""
      echo "The VM may still be completing cloud-init setup."
      echo "Try connecting manually in a few minutes."
      
      exit 1
    EOT

    on_failure = continue
  }

  triggers = {
    vm_id = libvirt_domain.ubuntu_vm.id
  }
}