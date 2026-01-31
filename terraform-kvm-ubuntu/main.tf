
# ============================================================================
# STORAGE POOL CONFIGURATION (IDEMPOTENT)
# ============================================================================
# Menggunakan null_resource untuk menangani pool yang mungkin sudah ada
# tanpa menyebabkan error "already exists" pada Terraform state.
resource "null_resource" "pool_management" {
  triggers = {
    pool_name = local.pool_name
    pool_path = "/var/lib/libvirt/images/${local.pool_name}"
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
    detection_version = "1"
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
      
      CLOUDINIT_NAME="${local.cloudinit_iso_name}"
      POOL_NAME="${local.pool_name}"
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
data "external" "virt_detection" {
  program = ["bash", "${path.module}/scripts/virt_detect.sh"]
}

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

  final_virt_type = data.external.virt_detection.result.virt_type
  final_emulator  = data.external.virt_detection.result.emulator
  final_cpu_mode  = local.final_virt_type == "kvm" ? var.cpu_mode : "custom"

  # Extended tags with detected info
  final_tags = merge(local.common_tags, {
    virt_type = local.final_virt_type
    emulator  = local.final_emulator
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

  cloudinit_iso_name = "cloudinit-${local.sanitized_hostname}-${substr(sha1(data.template_file.user_data.rendered), 0, 8)}-${substr(sha1(data.template_file.network_config.rendered), 0, 8)}.iso"

  # UEFI support detection
  uefi_firmware_path = "/usr/share/OVMF/OVMF_CODE.fd"
  use_uefi           = fileexists(local.uefi_firmware_path) && var.enable_uefi

  # Fallback to safe defaults
  domain_type_fallback = "qemu" # Safe default for systems without KVM access

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

# Download image locally to avoid libvirt provider timeout
resource "null_resource" "download_ubuntu_image" {
  triggers = {
    img_url = var.ubuntu_img_url
  }

  provisioner "local-exec" {
    command     = <<EOT
      set -e
      # Create cache directory safely
      CACHE_DIR="${abspath(path.module)}/.cache"
      mkdir -p "$CACHE_DIR"
      
      IMAGE_URL="${var.ubuntu_img_url}"
      IMAGE_NAME=$(basename "$IMAGE_URL")
      LOCAL_PATH="$CACHE_DIR/$IMAGE_NAME"

      echo "Checking for cached image at $LOCAL_PATH..."
      if [ -f "$LOCAL_PATH" ]; then
        echo "Image already exists in cache."
      else
        echo "Image not found. Downloading from $IMAGE_URL..."
        # Download with retry and increased timeout (20 mins)
        if command -v curl >/dev/null 2>&1; then
          curl -L --fail --retry 5 --retry-delay 5 --max-time 1200 -o "$LOCAL_PATH" "$IMAGE_URL"
        elif command -v wget >/dev/null 2>&1; then
          wget --tries=5 --wait=5 --timeout=1200 -O "$LOCAL_PATH" "$IMAGE_URL"
        else
          echo "Error: Neither curl nor wget found."
          exit 1
        fi
        echo "Download complete."
      fi
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

resource "libvirt_volume" "ubuntu_base_img" {
  name = "ubuntu-base-img-${local.sanitized_hostname}.qcow2"
  pool = local.pool_name
  # Use local file source instead of remote URL to bypass provider timeout
  source = "${abspath(path.module)}/.cache/${basename(var.ubuntu_img_url)}"
  format = "qcow2"

  depends_on = [
    null_resource.pool_management,
    null_resource.validation,
    null_resource.pre_deployment_check,
    null_resource.download_ubuntu_image,
    null_resource.verify_downloaded_image,
    null_resource.ensure_pool_ready,
    null_resource.cleanup_cloudinit,
    null_resource.verify_cloudinit_cleanup
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      source, # Ignore changes to source after initial creation
    ]
  }
}

# Wait for volumes to be fully registered in libvirt
resource "time_sleep" "wait_for_volumes" {
  depends_on = [
    libvirt_volume.ubuntu_base,
    libvirt_volume.ubuntu_base_img,
    libvirt_cloudinit_disk.commoninit
  ]

  create_duration = "15s"
}

# ============================================================================
# WAIT FOR CLOUDINIT ISO TO BE READY
# ============================================================================
resource "time_sleep" "wait_for_cloudinit_iso" {
  depends_on = [
    libvirt_cloudinit_disk.commoninit
  ]

  create_duration = "10s"

  triggers = {
    cloudinit_id = libvirt_cloudinit_disk.commoninit.id
  }
}

# ============================================================================
# FORCE POOL REFRESH - IMPROVED WITH VALIDATION
# ============================================================================
resource "null_resource" "force_pool_refresh" {
  depends_on = [
    time_sleep.wait_for_volumes,
    time_sleep.wait_for_cloudinit_iso,
    libvirt_cloudinit_disk.commoninit
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Logging setup
      LOG_FILE="${path.root}/logs/.pool_refresh.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      echo "=== Pool Refresh and Verification ==="
      echo "Timestamp: $(date)"
      
      # CRITICAL: Validate pool name before proceeding
      POOL_NAME="${local.pool_name}"
      
      if [ -z "$POOL_NAME" ]; then
        echo "✗ FATAL ERROR: Pool name is empty!"
        echo "  This indicates a configuration issue in Terraform"
        echo "  Please check:"
        echo "    1. Variable 'libvirt_pool_name' is set correctly"
        echo "    2. Local variable 'pool_name' is properly defined"
        echo "    3. Terraform state is not corrupted"
        exit 1
      fi
      
      echo "Pool: $POOL_NAME"
      echo "Expected cloud-init ISO: ${local.cloudinit_iso_name}"
      echo "Expected disk: ubuntu-disk-${local.sanitized_hostname}.qcow2"
      echo ""
      
      # Verify pool exists before attempting refresh
      echo "Verifying pool exists..."
      if ! sudo virsh pool-list --all | grep -q "$POOL_NAME"; then
        echo "✗ ERROR: Storage pool '$POOL_NAME' does not exist"
        echo ""
        echo "Available pools:"
        sudo virsh pool-list --all
        echo ""
        echo "Please ensure the pool is created before running this script"
        echo "Run: sudo virsh pool-define-as $POOL_NAME dir - - - - /var/lib/libvirt/images/$POOL_NAME"
        echo "     sudo virsh pool-build $POOL_NAME"
        echo "     sudo virsh pool-start $POOL_NAME"
        echo "     sudo virsh pool-autostart $POOL_NAME"
        exit 1
      fi
      
      echo "✓ Pool '$POOL_NAME' exists"
      
      # Check if pool is active
      if ! sudo virsh pool-list | grep -q "$POOL_NAME"; then
        echo "⚠ Pool is not active, attempting to start..."
        if sudo virsh pool-start "$POOL_NAME" 2>/dev/null; then
          echo "✓ Pool started successfully"
        else
          echo "✗ ERROR: Failed to start pool"
          sudo virsh pool-info "$POOL_NAME"
          exit 1
        fi
      fi
      
      # Step 1: Refresh storage pool multiple times to ensure sync
      echo ""
      echo "Step 1: Refreshing storage pool..."
      for i in {1..3}; do
        echo "  Refresh attempt $i/3..."
        if sudo virsh pool-refresh "$POOL_NAME" 2>&1; then
          echo "  ✓ Refresh successful"
        else
          echo "  ⚠ Refresh failed, retrying..."
        fi
        sleep 2
      done
      echo "✓ Pool refresh complete"
      echo ""
      
      # Step 2: Wait for filesystem sync
      echo "Step 2: Waiting for filesystem synchronization..."
      sync
      sleep 3
      echo "✓ Filesystem sync complete"
      echo ""
      
      # Step 3: Verify all volumes are present
      echo "Step 3: Listing all volumes in pool..."
      if sudo virsh vol-list "$POOL_NAME" 2>&1; then
        echo "✓ Volume list retrieved"
      else
        echo "⚠ Failed to list volumes"
      fi
      echo ""
      
      # Step 4: Check for cloud-init ISO with retry mechanism
      echo "Step 4: Verifying cloud-init ISO..."
      CLOUDINIT_NAME="${local.cloudinit_iso_name}"
      MAX_RETRIES=10
      RETRY_COUNT=0
      ISO_FOUND=false
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "  Verification attempt $((RETRY_COUNT + 1))/$MAX_RETRIES..."
        
        # Refresh pool before each check
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
        sleep 2
        
        # Check if ISO exists in pool
        if sudo virsh vol-list "$POOL_NAME" | grep -q "$CLOUDINIT_NAME"; then
          echo "  ✓ Cloud-init ISO found: $CLOUDINIT_NAME"
          ISO_FOUND=true
          break
        fi
        
        # Check if ISO exists in filesystem
        POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+' || echo "/var/lib/libvirt/images/$POOL_NAME")
        if sudo test -f "$POOL_PATH/$CLOUDINIT_NAME"; then
          echo "  ⚠ ISO exists in filesystem but not visible in pool"
          echo "  Attempting to refresh pool again..."
          sudo virsh pool-refresh "$POOL_NAME" || true
          sleep 3
        else
          echo "  ⚠ ISO not found in filesystem: $POOL_PATH/$CLOUDINIT_NAME"
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
          echo "  Waiting 5 seconds before retry..."
          sleep 5
        fi
      done
      
      # Step 5: Check for disk volume
      echo ""
      echo "Step 5: Verifying disk volume..."
      DISK_NAME="ubuntu-disk-${local.sanitized_hostname}.qcow2"
      DISK_FOUND=false
      RETRY_COUNT=0
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "  Verification attempt $((RETRY_COUNT + 1))/$MAX_RETRIES..."
        
        # Refresh pool before each check
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
        sleep 2
        
        # Check if disk exists in pool
        if sudo virsh vol-list "$POOL_NAME" | grep -q "$DISK_NAME"; then
          echo "  ✓ Disk volume found: $DISK_NAME"
          DISK_FOUND=true
          break
        fi
        
        # Check if disk exists in filesystem
        POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+' || echo "/var/lib/libvirt/images/$POOL_NAME")
        if sudo test -f "$POOL_PATH/$DISK_NAME"; then
          echo "  ⚠ Disk exists in filesystem but not visible in pool"
          echo "  Attempting to refresh pool again..."
          sudo virsh pool-refresh "$POOL_NAME" || true
          sleep 3
        else
          echo "  ⚠ Disk not found in filesystem: $POOL_PATH/$DISK_NAME"
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
          echo "  Waiting 5 seconds before retry..."
          sleep 5
        fi
      done
      
      # Step 6: Final verification
      echo ""
      echo "=== Verification Results ==="
      
      if [ "$DISK_FOUND" = true ]; then
        echo "✓ SUCCESS: Disk volume verified"
        
        # Get disk details
        echo ""
        echo "Disk Details:"
        sudo virsh vol-info "$DISK_NAME" --pool "$POOL_NAME" || true
        
        # Check filesystem
        POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+' || echo "/var/lib/libvirt/images/$POOL_NAME")
        if sudo test -f "$POOL_PATH/$DISK_NAME"; then
          echo ""
          echo "Filesystem Details:"
          sudo ls -lh "$POOL_PATH/$DISK_NAME"
        fi
        
        # Verify disk is readable
        echo ""
        echo "Verifying disk accessibility..."
        if sudo qemu-img info "$POOL_PATH/$DISK_NAME" >/dev/null 2>&1; then
          echo "✓ Disk is readable and valid qcow2 format"
          sudo qemu-img info "$POOL_PATH/$DISK_NAME" | grep -E "(file format|virtual size|disk size|backing file)"
        else
          echo "⚠ WARNING: Disk exists but may be corrupted"
        fi
        
        echo ""
        echo "✓ All volumes verified successfully"
        exit 0
      else
        echo "✗ FAILURE: Disk volume not found after $MAX_RETRIES attempts"
        echo ""
        echo "Diagnostic Information:"
        echo "1. Pool contents:"
        sudo virsh vol-list "$POOL_NAME"
        echo ""
        echo "2. Filesystem contents:"
        POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+' || echo "/var/lib/libvirt/images/$POOL_NAME")
        sudo ls -lh "$POOL_PATH/" | grep -E "(ubuntu-disk|qcow2)" || echo "  No disk volumes found"
        echo ""
        echo "3. Pool information:"
        sudo virsh pool-info "$POOL_NAME"
        echo ""
        echo "4. Check Terraform state:"
        echo "  terraform state show 'module.kvm_ubuntu.libvirt_volume.ubuntu_base'"
        echo ""
        echo "Possible causes:"
        echo "  - libvirt_volume.ubuntu_base creation failed"
        echo "  - Insufficient disk space in pool"
        echo "  - Permission issues"
        echo "  - Base image (ubuntu_base_img) is corrupted"
        echo ""
        echo "Recommended actions:"
        echo "  1. Check available space: df -h $POOL_PATH"
        echo "  2. Check pool permissions: sudo ls -ld $POOL_PATH"
        echo "  3. Verify base image: sudo qemu-img info $POOL_PATH/ubuntu-base-img-${local.sanitized_hostname}.qcow2"
        echo "  4. Check Terraform logs for volume creation errors"
        echo "  5. Try: terraform taint module.kvm_ubuntu.libvirt_volume.ubuntu_base"
        echo ""
        exit 1
      fi
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    volumes_ready = join(",", [
      libvirt_volume.ubuntu_base.id,
      libvirt_volume.ubuntu_base_img.id,
      libvirt_cloudinit_disk.commoninit.id # Tambahkan trigger ini
    ])
    pool_name = local.pool_name # Add pool_name to trigger re-run if pool changes
    timestamp = timestamp()
  }
}

# Monitor download progress dan verify integrity
resource "null_resource" "verify_downloaded_image" {
  depends_on = [null_resource.download_ubuntu_image]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      CACHE_DIR="${abspath(path.module)}/.cache"
      IMAGE_NAME=$(basename "${var.ubuntu_img_url}")
      LOCAL_PATH="$CACHE_DIR/$IMAGE_NAME"
      
      echo "=== Verifying Downloaded Image ==="
      
      # Check if file exists
      if [ ! -f "$LOCAL_PATH" ]; then
        echo "✗ ERROR: Downloaded image not found at $LOCAL_PATH"
        exit 1
      fi
      
      # Check file size (should be > 100MB for Ubuntu cloud image)
      FILE_SIZE=$(stat -f%z "$LOCAL_PATH" 2>/dev/null || stat -c%s "$LOCAL_PATH" 2>/dev/null)
      MIN_SIZE=$((100 * 1024 * 1024))  # 100MB
      
      if [ "$FILE_SIZE" -lt "$MIN_SIZE" ]; then
        echo "✗ ERROR: Downloaded file is too small ($FILE_SIZE bytes)"
        echo "  Expected at least $MIN_SIZE bytes"
        echo "  File may be corrupted or download incomplete"
        rm -f "$LOCAL_PATH"
        exit 1
      fi
      
      echo "✓ Image file size: $(numfmt --to=iec-i --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes")"
      
      # Verify it's a valid qcow2 image
      if command -v qemu-img >/dev/null 2>&1; then
        echo "Verifying image format..."
        if qemu-img info "$LOCAL_PATH" >/dev/null 2>&1; then
          echo "✓ Valid qcow2 image format"
          qemu-img info "$LOCAL_PATH" | grep -E "(file format|virtual size|disk size)"
        else
          echo "✗ ERROR: Invalid or corrupted qcow2 image"
          rm -f "$LOCAL_PATH"
          exit 1
        fi
      else
        echo "⚠ qemu-img not available, skipping format verification"
      fi
      
      # Set proper permissions
      chmod 644 "$LOCAL_PATH"
      
      echo "✓ Image verification complete"
      echo "  Path: $LOCAL_PATH"
      
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    image_url = var.ubuntu_img_url
  }
}

# Resource untuk memastikan pool exists sebelum volume
resource "null_resource" "ensure_pool_ready" {
  # Trigger setiap kali pool name berubah
  triggers = {
    pool_name = local.pool_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      set -e
      
      POOL_NAME="${local.pool_name}"
      MAX_WAIT=60
      WAIT_COUNT=0
      
      echo "Waiting for storage pool $POOL_NAME to be ready..."
      
      while ! sudo virsh pool-list | grep -q "$POOL_NAME.*active"; do
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
          echo "ERROR: Storage pool failed to become active"
          exit 1
        fi
        
        echo "Waiting for pool... ($WAIT_COUNT/$MAX_WAIT)"
        sleep 2
        ((WAIT_COUNT++))
      done
      
      echo "Storage pool is ready"
      
      # Refresh pool
      sudo virsh pool-refresh "$POOL_NAME" || true
      
      # Verify pool path is writable
      POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+')
      if [ ! -w "$POOL_PATH" ]; then
        echo "WARNING: Pool path may not be writable"
      fi
      
      echo "Pool verification completed"
    EOT

    interpreter = ["bash", "-c"]
  }
}

# Validate pool name and path
resource "null_resource" "validate_pool_path" {
  depends_on = [null_resource.ensure_pool_ready]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      POOL_NAME="${local.pool_name}"
      
      echo "=== Validating Storage Pool Path ==="
      
      # Get pool path from libvirt
      POOL_PATH=$(sudo virsh pool-dumpxml "$POOL_NAME" | grep -oP '(?<=<path>)[^<]+' || echo "")
      
      if [ -z "$POOL_PATH" ]; then
        echo "✗ ERROR: Could not determine pool path"
        exit 1
      fi
      
      echo "Pool path: $POOL_PATH"
      
      # Verify path exists
      if [ ! -d "$POOL_PATH" ]; then
        echo "✗ ERROR: Pool path does not exist: $POOL_PATH"
        exit 1
      fi
      
      # Verify path is writable
      if ! sudo test -w "$POOL_PATH"; then
        echo "✗ ERROR: Pool path is not writable: $POOL_PATH"
        echo "Current permissions:"
        sudo ls -ld "$POOL_PATH"
        exit 1
      fi
      
      # Verify sufficient space (at least 20GB)
      AVAILABLE_KB=$(df -k "$POOL_PATH" | tail -1 | awk '{print $4}')
      REQUIRED_KB=$((20 * 1024 * 1024))  # 20GB in KB
      
      if [ "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]; then
        AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
        echo "✗ ERROR: Insufficient disk space"
        echo "  Available: $${AVAILABLE_GB}GB"
        echo "  Required: 20GB"
        exit 1
      fi
      
      echo "✓ Pool path validation complete"
      echo "  Path: $POOL_PATH"
      echo "  Available space: $((AVAILABLE_KB / 1024 / 1024))GB"
      
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    pool_name = local.pool_name
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
      
      CLOUDINIT_NAME="${local.cloudinit_iso_name}"
      POOL_NAME="${local.pool_name}"
      MAX_RETRIES=10
      RETRY_COUNT=0
      CLEANUP_NEEDED=false
      CLEANUP_SUCCESS=false

      is_volume_managed_by_terraform() {
        local target_name="$1"
        local addr

        while read -r addr; do
          [ -z "$addr" ] && continue
          if terraform state show -no-color "$addr" 2>/dev/null | awk -F'=' '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}' | grep -qx "$target_name"; then
            echo "$addr"
            return 0
          fi
        done < <(terraform state list 2>/dev/null | grep -E 'libvirt_cloudinit_disk\.commoninit$' || true)

        return 1
      }
      
      # Function to check if volume exists
      volume_exists() {
        # Selalu refresh pool sebelum cek keberadaan volume
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1
        sudo virsh vol-info "$CLOUDINIT_NAME" --pool "$POOL_NAME" >/dev/null 2>&1
        return $?
      }
      
      # Check if volume exists
      if volume_exists; then
        CLEANUP_NEEDED=true
        echo "⚠ Found existing cloudinit volume: $CLOUDINIT_NAME"
        echo "Removing old cloudinit volume..."

        MANAGED_ADDR=$(is_volume_managed_by_terraform "$CLOUDINIT_NAME" || true)
        if [ -n "$MANAGED_ADDR" ]; then
          echo "✓ Cloudinit volume is managed by Terraform state ($MANAGED_ADDR). Skipping cleanup."
          CLEANUP_NEEDED=false
          CLEANUP_SUCCESS=true
        fi

        if [ "$CLEANUP_NEEDED" != true ]; then
          echo "✓ No cleanup required"
          sleep 5
          sudo virsh pool-refresh "$POOL_NAME" 2>/dev/null || true
          {
            echo "✓ Cloudinit Cleanup Check Complete"
            echo "  Managed by Terraform: $CLOUDINIT_NAME"
            echo "  Full log: ${path.root}/logs/.cloudinit_cleanup.log"
          } >&2
          exit 0
        fi
        
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
    ssh_key        = can(regex("^ssh-", var.ssh_public_key)) ? var.ssh_public_key : file(pathexpand(var.ssh_public_key))
    ssh_user       = var.ssh_username
    k8s_version    = "1.31"
    static_ip      = var.vm_ip_address
    gateway        = var.vm_gateway
    nameservers    = local.nameservers_yaml
    extra_hosts    = join("\n", var.extra_hosts_entries)
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

  vars = {
    static_ip       = var.vm_ip_address
    gateway         = var.vm_gateway
    nameservers     = local.nameservers_yaml
    interface_name  = var.vm_interface_name
    interface_match = var.vm_interface_match
  }

  depends_on = [null_resource.validation]
}

data "template_file" "meta_data" {
  template = <<-EOT
    instance-id: $${instance_id}
    local-hostname: $${hostname}
  EOT

  vars = {
    instance_id = "iid-${substr(md5(data.template_file.user_data.rendered), 0, 8)}"
    hostname    = local.sanitized_hostname
  }

  depends_on = [data.template_file.user_data]
}

# ============================================================================
# CLOUDINIT CLEANUP (PRE-CREATION)
# ============================================================================
resource "null_resource" "cleanup_cloudinit_conflict" {
  triggers = {
    # Calculate the exact name that will be used by the cloudinit disk
    # This must match the name definition in libvirt_cloudinit_disk.commoninit
    target_vol_name = local.cloudinit_iso_name
    pool_name       = local.pool_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set +e
      VOL_NAME="${self.triggers.target_vol_name}"
      POOL_NAME="${self.triggers.pool_name}"
      
      echo "Checking for conflicting cloudinit volume: $VOL_NAME in pool $POOL_NAME"
      
      if sudo virsh vol-info "$VOL_NAME" --pool "$POOL_NAME" >/dev/null 2>&1; then
        echo "Found existing conflicting volume: $VOL_NAME"
        echo "Attempting to delete it to allow Terraform to recreate it..."
        
        # Check if it's in use
        if sudo virsh vol-list "$POOL_NAME" | grep -q "$VOL_NAME"; then
             # Try to delete
             if sudo virsh vol-delete "$VOL_NAME" --pool "$POOL_NAME"; then
                 echo "Successfully deleted conflicting volume: $VOL_NAME"
             else
                 echo "Failed to delete volume. It might be in use by a running VM."
                 exit 1
             fi
        fi
      else
        echo "No conflicting volume found."
      fi
    EOT
    interpreter = ["/bin/bash", "-c"]
  }
}

# ============================================================================
# CLOUDINIT DISK WITH PROPER DEPENDENCIES AND ERROR HANDLING
# ============================================================================
resource "libvirt_cloudinit_disk" "commoninit" {
  name           = local.cloudinit_iso_name
  user_data      = data.template_file.user_data.rendered
  network_config = data.template_file.network_config.rendered
  meta_data      = data.template_file.meta_data.rendered
  pool           = local.pool_name

  depends_on = [
    null_resource.pool_management,
    null_resource.cleanup_cloudinit,
    null_resource.verify_cloudinit_cleanup,
    null_resource.pre_deployment_check, # Ensure pre-deployment check completes before ISO creation
    null_resource.cleanup_cloudinit_conflict, # NEW: Ensure conflict cleanup runs before creation
    time_sleep.wait_for_cleanup,
    data.template_file.user_data,
    data.template_file.network_config
  ]

  lifecycle {
    create_before_destroy = false
    replace_triggered_by  = [null_resource.cleanup_cloudinit]
  }
}

# Tambahkan explicit wait setelah cloudinit disk dibuat
resource "time_sleep" "wait_for_cloudinit" {
  depends_on = [
    libvirt_cloudinit_disk.commoninit,
    time_sleep.wait_for_volumes
  ]

  create_duration = "10s"

  triggers = {
    cloudinit_id = libvirt_cloudinit_disk.commoninit.id
  }
}

# Tambahkan null_resource untuk verifikasi file ISO
resource "null_resource" "verify_cloudinit_iso" {
  depends_on = [time_sleep.wait_for_cloudinit]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      ISO_PATH="/var/lib/libvirt/images/${local.pool_name}/${local.cloudinit_iso_name}"
      
      echo "Verifying cloud-init ISO at: $ISO_PATH"
      
      # Wait up to 30 seconds for ISO to appear
      for i in {1..30}; do
        if sudo test -f "$ISO_PATH"; then
          echo "✓ Cloud-init ISO found"
          sudo ls -lh "$ISO_PATH"
          exit 0
        fi
        echo "Waiting for ISO... ($i/30)"
        sleep 1
      done
      
      echo "✗ ERROR: Cloud-init ISO not found after 30 seconds"
      echo "Checking pool contents:"
      sudo virsh vol-list ${local.pool_name}
      exit 1
    EOT
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
      LOG_FILE="${path.root}/logs/.cloudinit_cleanup.log"
      
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
      CLOUDINIT_NAME="${local.cloudinit_iso_name}"
      DISK_NAME="ubuntu-disk-${local.sanitized_hostname}.qcow2"
      POOL_NAME="${local.pool_name}"

      is_volume_managed_by_terraform() {
        local target_name="$1"
        local addr

        while read -r addr; do
          [ -z "$addr" ] && continue
          if terraform state show -no-color "$addr" 2>/dev/null | awk -F'=' '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}' | grep -qx "$target_name"; then
            echo "$addr"
            return 0
          fi
        done < <(terraform state list 2>/dev/null | grep -E 'libvirt_cloudinit_disk\.commoninit$|libvirt_volume\.(ubuntu_base|ubuntu_base_img)$' || true)

        return 1
      }

      # Refresh pool to ensure we have the latest state
      echo "Refreshing storage pool '$POOL_NAME'..."
      sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || echo "  Warning: Pool refresh failed"
      
      for VOL in "$CLOUDINIT_NAME" "$DISK_NAME"; do
        if sudo virsh vol-info "$VOL" --pool "$POOL_NAME" >/dev/null 2>&1; then
          echo "⚠ Found existing volume: $VOL"
          echo "  Attempting to resolve conflict..."

          MANAGED_ADDR=$(is_volume_managed_by_terraform "$VOL" || true)
          if [ -n "$MANAGED_ADDR" ]; then
            echo "  ✓ Volume is managed by Terraform state ($MANAGED_ADDR). Skipping cleanup."
            continue
          fi
          
          # Check if any VM is using it
          USING_VM=$(sudo virsh list --all --name | while read vm; do
            if [ -n "$vm" ] && sudo virsh domblklist "$vm" 2>/dev/null | grep -q "$VOL"; then
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
          if sudo virsh vol-delete "$VOL" --pool "$POOL_NAME" 2>/dev/null; then
            echo "  ✓ Volume $VOL deleted successfully"
          else
            echo "  ⚠ Failed to delete volume $VOL (might be in use or partially deleted)"
            # Don't exit here, maybe Terraform can handle it or other volumes can be cleaned
          fi
        fi
      done
      
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
# VERIFY DISK VOLUME CREATION
# ============================================================================
resource "null_resource" "verify_disk_volume" {
  depends_on = [
    libvirt_volume.ubuntu_base,
    libvirt_volume.ubuntu_base_img,
    time_sleep.wait_for_volumes,
    null_resource.force_pool_refresh
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Logging setup
      LOG_FILE="${path.root}/logs/.disk_verification.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      echo "=== Disk Volume Verification ==="
      echo "Timestamp: $(date)"
      echo "Pool: ${local.pool_name}"
      echo "Expected disk: ubuntu-disk-${local.sanitized_hostname}.qcow2"
      echo "Expected base: ubuntu-base-img-${local.sanitized_hostname}.qcow2"
      echo ""
      
      DISK_NAME="ubuntu-disk-${local.sanitized_hostname}.qcow2"
      BASE_IMG_NAME="ubuntu-base-img-${local.sanitized_hostname}.qcow2"
      POOL_NAME="${local.pool_name}"
      POOL_PATH="/var/lib/libvirt/images/$POOL_NAME"
      MAX_RETRIES=20
      RETRY_COUNT=0
      DISK_FOUND=false
      BASE_FOUND=false
      
      # Step 1: Refresh pool multiple times
      echo "Step 1: Refreshing storage pool..."
      for i in {1..5}; do
        echo "  Refresh attempt $i/5..."
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
        sleep 2
      done
      echo "✓ Pool refresh complete"
      echo ""
      
      # Step 2: Wait for filesystem sync
      echo "Step 2: Filesystem synchronization..."
      sync
      sleep 3
      echo "✓ Sync complete"
      echo ""
      
      # Step 3: Verify base image first
      echo "Step 3: Verifying base image..."
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "  Verification attempt $((RETRY_COUNT + 1))/$MAX_RETRIES..."
        
        # Refresh pool before check
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
        sleep 2
        
        # Check base image in libvirt pool
        if sudo virsh vol-list "$POOL_NAME" | grep -q "$BASE_IMG_NAME"; then
          echo "  ✓ Base image found in libvirt pool"
          BASE_FOUND=true
          break
        fi
        
        # Check in filesystem
        if sudo test -f "$POOL_PATH/$BASE_IMG_NAME"; then
          echo "  ⚠ Base image exists in filesystem but not visible in pool"
          echo "  Attempting pool refresh..."
          sudo virsh pool-refresh "$POOL_NAME" || true
          sleep 3
        else
          echo "  ⚠ Base image not found in filesystem: $POOL_PATH/$BASE_IMG_NAME"
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
          echo "  Waiting 5 seconds before retry..."
          sleep 5
        fi
      done
      
      if [ "$BASE_FOUND" = false ]; then
        echo "✗ FAILURE: Base image not found after $MAX_RETRIES attempts"
        echo ""
        echo "Diagnostic Information:"
        echo "1. Pool contents:"
        sudo virsh vol-list "$POOL_NAME"
        echo ""
        echo "2. Filesystem contents:"
        sudo ls -lh "$POOL_PATH/" | grep -E "(ubuntu-base|qcow2)" || echo "  No disk volumes found"
        echo ""
        echo "3. Check download status:"
        echo "  ls -lh ${abspath(path.module)}/.cache/"
        echo ""
        exit 1
      fi
      
      # Step 4: Verify disk volume
      echo ""
      echo "Step 4: Verifying disk volume..."
      RETRY_COUNT=0
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "  Verification attempt $((RETRY_COUNT + 1))/$MAX_RETRIES..."
        
        # Refresh pool before check
        sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
        sleep 2
        
        # Check in libvirt pool
        if sudo virsh vol-list "$POOL_NAME" | grep -q "$DISK_NAME"; then
          echo "  ✓ Disk found in libvirt pool"
          DISK_FOUND=true
          break
        fi
        
        # Check in filesystem
        if sudo test -f "$POOL_PATH/$DISK_NAME"; then
          echo "  ⚠ Disk exists in filesystem but not visible in pool"
          echo "  Attempting pool refresh..."
          sudo virsh pool-refresh "$POOL_NAME" || true
          sleep 3
        else
          echo "  ⚠ Disk not found in filesystem: $POOL_PATH/$DISK_NAME"
          echo "  Checking if base image is accessible..."
          
          if sudo qemu-img info "$POOL_PATH/$BASE_IMG_NAME" >/dev/null 2>&1; then
            echo "  Base image is accessible, disk creation may be in progress..."
          else
            echo "  ✗ Base image is not accessible!"
            exit 1
          fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
          echo "  Waiting 5 seconds before retry..."
          sleep 5
        fi
      done
      
      # Step 5: Final verification
      echo ""
      echo "=== Verification Results ==="
      if [ "$DISK_FOUND" = true ]; then
        echo "✓ SUCCESS: Disk volume verified"
        
        # Get disk details
        echo ""
        echo "Disk Details:"
        sudo virsh vol-info "$DISK_NAME" --pool "$POOL_NAME" || true
        
        # Check filesystem
        if sudo test -f "$POOL_PATH/$DISK_NAME"; then
          echo ""
          echo "Filesystem Details:"
          sudo ls -lh "$POOL_PATH/$DISK_NAME"
        fi
        
        # Verify disk is readable
        echo ""
        echo "Verifying disk accessibility..."
        IN_USE_BY=""
        for vm in $(sudo virsh list --state-running --name 2>/dev/null); do
          [ -z "$vm" ] && continue
          if sudo virsh domblklist "$vm" 2>/dev/null | grep -q "$DISK_NAME"; then
            IN_USE_BY="$vm"
            break
          fi
        done

        if [ -n "$IN_USE_BY" ]; then
          echo "⚠ Disk is currently attached to running domain: $IN_USE_BY"
          echo "Skipping qemu-img checks to avoid lock errors"
        else
          if sudo qemu-img info "$POOL_PATH/$DISK_NAME" >/dev/null 2>&1; then
            echo "✓ Disk is readable and valid qcow2 format"
            sudo qemu-img info "$POOL_PATH/$DISK_NAME" | grep -E "(file format|virtual size|disk size|backing file)"
          else
            echo "⚠ WARNING: Disk exists but may be corrupted"
          fi

          # Verify backing file relationship
          echo ""
          echo "Verifying backing file relationship..."
          BACKING_FILE=$(sudo qemu-img info "$POOL_PATH/$DISK_NAME" | grep "backing file:" | awk '{print $3}')
          if [ -n "$BACKING_FILE" ]; then
            echo "✓ Backing file: $BACKING_FILE"
            if sudo test -f "$BACKING_FILE"; then
              echo "✓ Backing file exists and is accessible"
            else
              echo "⚠ WARNING: Backing file path may be incorrect"
            fi
          else
            echo "⚠ No backing file found (this may be intentional)"
          fi
        fi
        
        echo ""
        echo "✓ Disk volume ready for VM creation"
        exit 0
      else
        echo "✗ FAILURE: Disk volume not found after $MAX_RETRIES attempts"
        echo ""
        echo "Diagnostic Information:"
        echo "1. Pool contents:"
        sudo virsh vol-list "$POOL_NAME"
        echo ""
        echo "2. Filesystem contents:"
        sudo ls -lh "$POOL_PATH/" | grep -E "(ubuntu-disk|qcow2)" || echo "  No disk volumes found"
        echo ""
        echo "3. Pool information:"
        sudo virsh pool-info "$POOL_NAME"
        echo ""
        echo "4. Check Terraform state:"
        echo "  terraform state show 'module.kvm_ubuntu.libvirt_volume.ubuntu_base'"
        echo ""
        echo "5. Check base image:"
        sudo qemu-img info "$POOL_PATH/$BASE_IMG_NAME" || echo "  Base image check failed"
        echo ""
        echo "Possible causes:"
        echo "  - libvirt_volume.ubuntu_base creation failed"
        echo "  - Insufficient disk space in pool"
        echo "  - Permission issues"
        echo "  - Base image (ubuntu_base_img) is corrupted"
        echo "  - Backing file path mismatch"
        echo ""
        echo "Recommended actions:"
        echo "  1. Check available space: df -h $POOL_PATH"
        echo "  2. Check pool permissions: sudo ls -ld $POOL_PATH"
        echo "  3. Verify base image: sudo qemu-img info $POOL_PATH/$BASE_IMG_NAME"
        echo "  4. Check Terraform logs for volume creation errors"
        echo "  5. Try: terraform taint module.kvm_ubuntu.libvirt_volume.ubuntu_base"
        echo "  6. Check libvirt logs: sudo journalctl -u libvirtd -n 100"
        echo ""
        exit 1
      fi
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  triggers = {
    volume_id   = libvirt_volume.ubuntu_base.id
    base_img_id = libvirt_volume.ubuntu_base_img.id
    timestamp   = timestamp()
  }
}

# ============================================================================
# ADDITIONAL WAIT AFTER DISK VERIFICATION
# ============================================================================
resource "time_sleep" "wait_after_disk_verification" {
  depends_on = [
    null_resource.verify_disk_volume
  ]

  create_duration = "5s"

  triggers = {
    disk_verified = null_resource.verify_disk_volume.id
  }
}

# ============================================================================
# EMULATOR VALIDATION AND FALLBACK
# ============================================================================
resource "null_resource" "validate_emulator" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      LOG_FILE="${path.root}/logs/.emulator_validation.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > "$LOG_FILE" 2>&1
      
      echo "=== Emulator Validation ==="
      echo "Timestamp: $(date)"
      
      DETECTED_EMULATOR="${local.detected_emulator}"
      DETECTED_VIRT_TYPE="${local.detected_virt_type}"
      
      echo "Detected Emulator: $DETECTED_EMULATOR"
      echo "Detected Virt Type: $DETECTED_VIRT_TYPE"
      
      # Validate emulator exists and is executable
      if [ ! -x "$DETECTED_EMULATOR" ]; then
        echo "✗ ERROR: Emulator not executable: $DETECTED_EMULATOR"
        
        # Try to find alternative
        echo "Searching for alternative emulator..."
        
        ALTERNATIVE=""
        if [ -x /usr/bin/qemu-system-x86_64 ]; then
          ALTERNATIVE="/usr/bin/qemu-system-x86_64"
        elif [ -x /usr/bin/kvm ]; then
          ALTERNATIVE="/usr/bin/kvm"
        elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
          ALTERNATIVE=$(command -v qemu-system-x86_64)
        fi
        
        if [ -n "$ALTERNATIVE" ]; then
          echo "✓ Found alternative: $ALTERNATIVE"
          echo "$ALTERNATIVE" > "${path.module}/.emulator_path"
          
          # Adjust virt type based on KVM availability
          if [ -w /dev/kvm ] && "$ALTERNATIVE" -accel help 2>/dev/null | grep -q "kvm"; then
            echo "kvm" > "${path.module}/.virt_type"
            echo "✓ KVM acceleration available"
          else
            echo "qemu" > "${path.module}/.virt_type"
            echo "⚠ Falling back to QEMU emulation"
          fi
        else
          echo "✗ FATAL: No suitable emulator found"
          exit 1
        fi
      else
        echo "✓ Emulator is valid and executable"
        
        # Verify virt type compatibility
        if [ "$DETECTED_VIRT_TYPE" = "kvm" ]; then
          if ! "$DETECTED_EMULATOR" -accel help 2>/dev/null | grep -q "kvm"; then
            echo "⚠ Emulator does not support KVM, switching to QEMU"
            echo "qemu" > "${path.module}/.virt_type"
          elif [ ! -w /dev/kvm ]; then
            echo "⚠ /dev/kvm not accessible, switching to QEMU"
            echo "qemu" > "${path.module}/.virt_type"
          fi
        fi
      fi
      
      # Final verification
      FINAL_EMULATOR=$(cat "${path.module}/.emulator_path")
      FINAL_VIRT_TYPE=$(cat "${path.module}/.virt_type")
      
      echo ""
      echo "=== Final Configuration ==="
      echo "Emulator: $FINAL_EMULATOR"
      echo "Virt Type: $FINAL_VIRT_TYPE"
      
      if [ ! -x "$FINAL_EMULATOR" ]; then
        echo "✗ FATAL: Final emulator validation failed"
        exit 1
      fi
      
      echo "✓ Emulator validation complete"
    EOT

    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    null_resource.detect_virtualization,
    data.local_file.virt_type,
    data.local_file.emulator_path
  ]

  triggers = {
    validation_version = "1"
    detected_virt_type = local.detected_virt_type
    detected_emulator  = local.detected_emulator
  }
}

# Re-read configuration after validation
data "local_file" "validated_virt_type" {
  filename = "${path.module}/.virt_type"

  depends_on = [null_resource.validate_emulator]
}

data "local_file" "validated_emulator_path" {
  filename = "${path.module}/.emulator_path"

  depends_on = [null_resource.validate_emulator]
}

# ============================================================================
# VIRTUAL MACHINE DOMAIN
# ============================================================================
resource "libvirt_domain" "ubuntu_vm" {
  name   = local.sanitized_hostname
  memory = var.vm_memory
  vcpu   = var.vm_vcpu

  # Domain type (kvm or qemu) - CRITICAL: use detected type
  type = local.final_virt_type

  # Emulator - FIXED: only set if detected AND compatible with domain type
  # Let libvirt auto-detect if we don't have a compatible emulator
  emulator = (
    local.final_emulator != "" &&
    fileexists(local.final_emulator)
  ) ? local.final_emulator : null

  # CPU Configuration untuk performa optimal
  cpu {
    mode = local.final_cpu_mode
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
    null_resource.verify_cloudinit_iso,
    null_resource.verify_disk_volume,        # NEW: Verify disk exists
    time_sleep.wait_after_disk_verification, # NEW: Wait after verification
    libvirt_volume.ubuntu_base,
    libvirt_volume.ubuntu_base_img,
    libvirt_cloudinit_disk.commoninit,
    time_sleep.wait_for_volumes,
    null_resource.force_pool_refresh,
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
      export SSH_PORT_MAX_WAIT="${min(var.ssh_timeout, 240)}"
      export SSH_AUTH_MAX_WAIT="${min(var.ssh_timeout, 300)}"
      SSH_KEY_PATH="${pathexpand(var.ssh_private_key_path)}"
      bash "${path.module}/scripts/health_check.sh" \
        "${local.sanitized_hostname}" \
        "${var.vm_hostname}" \
        "${local.sanitized_hostname}" \
        "${var.vm_ip_address}" \
        "${local.node_ip}" \
        "${var.ssh_username}" \
        "${var.network_name}" \
        "${local.pool_name}" \
        "$SSH_KEY_PATH"
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }

  triggers = {
    vm_id     = libvirt_domain.ubuntu_vm.id
    timestamp = timestamp()
  }
}


# ============================================================================
# SSH READINESS CHECK (OPTIONAL - RUNS AFTER HEALTH CHECK)
# ============================================================================
resource "null_resource" "wait_for_ssh" {
  count = var.wait_for_ssh ? 1 : 0

  depends_on = [
    null_resource.health_check,
    libvirt_domain.ubuntu_vm
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Setup logging with absolute path
      export LOG_FILE="${abspath(path.root)}/logs/.ssh_wait.log"
      mkdir -p "$(dirname "$LOG_FILE")"

      # Log initial information
      {
        echo "=== SSH Readiness Check Started ==="
        echo "Timestamp: $(date)"
        echo "Target: ${var.ssh_username}@${local.node_ip}"
        echo "Hostname: ${local.sanitized_hostname}"
        echo ""
      } | tee -a "$LOG_FILE"

      # Verify script exists before execution
      SCRIPT_PATH="${abspath(path.module)}/scripts/wait_for_ssh.sh"
      
      if [ ! -f "$SCRIPT_PATH" ]; then
        {
          echo "ERROR: Script not found at: $SCRIPT_PATH"
          echo ""
          echo "Checking scripts directory..."
          if [ -d "${abspath(path.module)}/scripts/" ]; then
            echo "Scripts directory exists. Contents:"
            ls -la "${abspath(path.module)}/scripts/" | grep -E "\.sh$" || echo "  No shell scripts found"
          else
            echo "Scripts directory does not exist: ${abspath(path.module)}/scripts/"
          fi
          echo ""
          echo "Please ensure wait_for_ssh.sh exists in the scripts directory"
        } | tee -a "$LOG_FILE" >&2
        exit 1
      fi

      # Ensure script is executable
      chmod +x "$SCRIPT_PATH" || {
        echo "ERROR: Cannot make script executable: $SCRIPT_PATH" | tee -a "$LOG_FILE" >&2
        exit 1
      }
      # Verify SSH private key exists
      SSH_KEY_PATH="${pathexpand(var.ssh_private_key_path)}"
      
      if [ ! -f "$SSH_KEY_PATH" ]; then
        {
          echo "ERROR: SSH private key not found at: $SSH_KEY_PATH"
          echo ""
          echo "Please ensure:"
          echo "  1. The SSH key file exists"
          echo "  2. The path is correct in your terraform.tfvars"
          echo "  3. You have read permissions on the key file"
          echo ""
          echo "Current ssh_private_key_path variable: ${var.ssh_private_key_path}"
          echo "Expanded path: $SSH_KEY_PATH"
        } | tee -a "$LOG_FILE" >&2
        exit 1
      fi
      
      # Verify SSH key permissions
      KEY_PERMS=$(stat -c %a "$SSH_KEY_PATH" 2>/dev/null || stat -f %A "$SSH_KEY_PATH" 2>/dev/null || echo "unknown")
      if [ "$KEY_PERMS" != "600" ] && [ "$KEY_PERMS" != "400" ]; then
        {
          echo "WARNING: SSH key has insecure permissions: $KEY_PERMS"
          echo "Recommended permissions: 600 or 400"
          echo "Attempting to fix permissions..."
        } | tee -a "$LOG_FILE"
        
        chmod 600 "$SSH_KEY_PATH" 2>/dev/null || {
          echo "WARNING: Could not change key permissions. Continuing anyway..." | tee -a "$LOG_FILE"
        }
      fi
      
      # Verify target IP is reachable
      {
        echo "Verifying network connectivity to ${local.node_ip}..."
      } | tee -a "$LOG_FILE"
      
      if ! ping -c 1 -W 5 "${local.node_ip}" >/dev/null 2>&1; then
        {
          echo "WARNING: Target IP ${local.node_ip} is not responding to ping"
          echo "This may be normal if ICMP is blocked. Continuing with SSH check..."
        } | tee -a "$LOG_FILE"
      else
        {
          echo "✓ Target IP is reachable via ping"
        } | tee -a "$LOG_FILE"
      fi
      
      # Run enhanced SSH wait script with proper error handling
      {
        echo ""
        echo "Starting SSH authentication check..."
        echo "Script: $SCRIPT_PATH"
        echo "Arguments:"
        echo "  1. Hostname: ${local.sanitized_hostname}"
        echo "  2. IP: ${local.node_ip}"
        echo "  3. Username: ${var.ssh_username}"
        echo "  4. SSH Key: $SSH_KEY_PATH"
        echo ""
      } | tee -a "$LOG_FILE"
      
      # Execute the wait_for_ssh script
      "$SCRIPT_PATH" \
        "${local.sanitized_hostname}" \
        "${local.node_ip}" \
        "${var.ssh_username}" \
        "$SSH_KEY_PATH" 2>&1 | tee -a "$LOG_FILE"
      
      EXIT_CODE=$${PIPESTATUS[0]}
      
      # Check exit code and provide appropriate feedback
      echo "" | tee -a "$LOG_FILE"
      
      if [ $EXIT_CODE -eq 0 ]; then
        {
          echo "╔════════════════════════════════════════════════════════════╗"
          echo "║  ✓ SSH READINESS CHECK COMPLETED SUCCESSFULLY             ║"
          echo "╚════════════════════════════════════════════════════════════╝"
          echo ""
          echo "SSH Connection Details:"
          echo "  Target: ${var.ssh_username}@${local.node_ip}"
          echo "  Hostname: ${local.sanitized_hostname}"
          echo "  Status: READY"
          echo ""
          echo "You can now connect via:"
          echo "  ssh -i $SSH_KEY_PATH ${var.ssh_username}@${local.node_ip}"
          echo ""
          echo "Log file: $LOG_FILE"
        } | tee -a "$LOG_FILE"
        exit 0
      else
        {
          echo "╔════════════════════════════════════════════════════════════╗"
          echo "║  ✗ SSH READINESS CHECK FAILED                             ║"
          echo "╚════════════════════════════════════════════════════════════╝"
          echo ""
          echo "Exit Code: $EXIT_CODE"
          echo "Target: ${var.ssh_username}@${local.node_ip}"
          echo "Log file: $LOG_FILE"
          echo ""
          echo "═══════════════════════════════════════════════════════════"
          echo "TROUBLESHOOTING GUIDE"
          echo "═══════════════════════════════════════════════════════════"
          echo ""
          echo "1. CHECK VM STATUS"
          echo "   Command: virsh domstate ${local.sanitized_hostname}"
          echo "   Expected: running"
          echo ""
          echo "2. CHECK VM CONSOLE"
          echo "   Command: virsh console ${local.sanitized_hostname}"
          echo "   Look for: Boot messages and login prompt"
          echo "   Exit console: Press Ctrl+] to exit"
          echo ""
          echo "3. CHECK CLOUD-INIT STATUS"
          echo "   After SSH access is available:"
          echo "   Command: ssh ${var.ssh_username}@${local.node_ip} 'sudo cloud-init status'"
          echo "   Expected: status: done"
          echo ""
          echo "4. VERIFY NETWORK CONNECTIVITY"
          echo "   Command: ping -c 4 ${local.node_ip}"
          echo "   Expected: 0% packet loss"
          echo ""
          echo "5. CHECK SSH SERVICE ON VM"
          echo "   Via console: sudo systemctl status ssh"
          echo "   Expected: active (running)"
          echo ""
          echo "6. VERIFY FIREWALL RULES"
          echo "   Host firewall: sudo iptables -L -n | grep 22"
          echo "   VM firewall (via console): sudo ufw status"
          echo ""
          echo "7. CHECK SSH KEY AUTHORIZATION"
          echo "   Verify key is in authorized_keys:"
          echo "   Via console: cat ~/.ssh/authorized_keys"
          echo ""
          echo "8. MANUAL SSH TEST"
          echo "   Command: ssh -vvv -i $SSH_KEY_PATH ${var.ssh_username}@${local.node_ip}"
          echo "   This will show detailed connection debug info"
          echo ""
          echo "9. CHECK LIBVIRT NETWORK"
          echo "   Command: virsh net-list --all"
          echo "   Command: virsh net-info ${var.network_name}"
          echo "   Ensure network is active"
          echo ""
          echo "10. REVIEW LOGS"
          echo "    Deployment log: $LOG_FILE"
          echo "    Health check: ${abspath(path.root)}/logs/.health_check.log"
          echo "    VM console: virsh console ${local.sanitized_hostname}"
          echo ""
          echo "═══════════════════════════════════════════════════════════"
          echo "COMMON ISSUES AND SOLUTIONS"
          echo "═══════════════════════════════════════════════════════════"
          echo ""
          echo "Issue: Connection timeout"
          echo "  → VM may still be booting. Wait 2-3 minutes and retry"
          echo "  → Check if VM is running: virsh list --all"
          echo ""
          echo "Issue: Permission denied (publickey)"
          echo "  → Verify SSH key is correct"
          echo "  → Check cloud-init user-data configuration"
          echo "  → Ensure key permissions are 600: chmod 600 $SSH_KEY_PATH"
          echo ""
          echo "Issue: No route to host"
          echo "  → Check libvirt network is active"
          echo "  → Verify VM has correct IP: virsh domifaddr ${local.sanitized_hostname}"
          echo "  → Check host firewall rules"
          echo ""
          echo "Issue: Connection refused"
          echo "  → SSH service may not be running on VM"
          echo "  → Check via console: sudo systemctl status ssh"
          echo "  → Verify port 22 is open: sudo netstat -tulpn | grep :22"
          echo ""
          echo "═══════════════════════════════════════════════════════════"
          echo ""
          echo "For immediate access, try connecting via console:"
          echo "  virsh console ${local.sanitized_hostname}"
          echo ""
          echo "Please review the log file for detailed diagnostics:"
          echo "  cat $LOG_FILE"
          echo ""
        } | tee -a "$LOG_FILE" >&2
        exit $EXIT_CODE
      fi
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = fail  # Changed from continue to fail for better error handling
  }

  triggers = {
    vm_id     = libvirt_domain.ubuntu_vm.id
    node_ip   = local.node_ip
    timestamp = timestamp()
  }
}

# ============================================================================
# K3S API READINESS CHECK (ENHANCED VERSION)
# ============================================================================
resource "null_resource" "wait_for_k3s" {
  count = var.k3s_node_role == "server" ? 1 : 0

  depends_on = [
    libvirt_domain.ubuntu_vm,
    null_resource.wait_for_ssh
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Logging setup
      LOG_FILE="${path.root}/logs/.k3s_wait.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      echo "=== Waiting for K3s API to be Ready ==="
      echo "Timestamp: $(date)"
      echo "Node IP: ${local.node_ip}"
      echo "API Endpoint: https://${local.node_ip}:6443"
      echo ""
      
      # Configuration
      MAX_WAIT_MINUTES=15
      CHECK_INTERVAL=10
      MAX_ITERATIONS=$((MAX_WAIT_MINUTES * 60 / CHECK_INTERVAL))
      
      # SSH configuration
      SSH_OPTS="-o StrictHostKeyChecking=no"
      SSH_OPTS="$SSH_OPTS -o UserKnownHostsFile=/dev/null"
      SSH_OPTS="$SSH_OPTS -o ConnectTimeout=10"
      SSH_OPTS="$SSH_OPTS -o BatchMode=yes"
      SSH_OPTS="$SSH_OPTS -o LogLevel=ERROR"
      SSH_OPTS="$SSH_OPTS -i ${pathexpand(var.ssh_private_key_path)}"
      
      # Counters
      iteration=0
      k3s_installed=false
      k3s_running=false
      api_reachable=false
      node_ready=false
      
      echo "Configuration:"
      echo "  Max wait time: $MAX_WAIT_MINUTES minutes"
      echo "  Check interval: $CHECK_INTERVAL seconds"
      echo "  Max iterations: $MAX_ITERATIONS"
      echo ""
      
      # Function to check K3s installation
      check_k3s_installed() {
        ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
            "command -v k3s >/dev/null 2>&1"
        return $?
      }
      
      # Function to check K3s service status
      check_k3s_service() {
        ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
            "sudo systemctl is-active k3s 2>/dev/null" | grep -q "active"
        return $?
      }
      
      # Function to check K3s API endpoint
      check_k3s_api() {
        timeout 10 bash -c "cat < /dev/null > /dev/tcp/${local.node_ip}/6443" >/dev/null 2>&1
        return $?
      }
      
      # Function to check node readiness
      check_node_ready() {
        ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
            "sudo k3s kubectl get nodes 2>/dev/null | grep -v NAME | grep -q Ready"
        return $?
      }
      
      # Main wait loop with progressive checks
      echo "Starting K3s readiness checks..."
      echo ""
      
      while [ $iteration -lt $MAX_ITERATIONS ]; do
        iteration=$((iteration + 1))
        elapsed_seconds=$((iteration * CHECK_INTERVAL))
        elapsed_minutes=$((elapsed_seconds / 60))
        remaining_seconds=$((elapsed_seconds % 60))
        
        echo "=== Check #$iteration ($${elapsed_minutes}m $${remaining_seconds}s elapsed) ==="
        
        # Stage 1: K3s Installation Check
        if [ "$k3s_installed" = false ]; then
          echo -n "  [1/4] Checking K3s installation... "
          if check_k3s_installed; then
            echo "✓ INSTALLED"
            k3s_installed=true
          else
            echo "⏳ NOT INSTALLED YET"
            
            # Show installation progress
            ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
                "ps aux | grep -E 'k3s|curl.*k3s' | grep -v grep | head -3" 2>/dev/null || \
                echo "    No installation process detected"
            
            sleep $CHECK_INTERVAL
            continue
          fi
        fi
        
        # Stage 2: K3s Service Status
        if [ "$k3s_running" = false ]; then
          echo -n "  [2/4] Checking K3s service status... "
          if check_k3s_service; then
            echo "✓ RUNNING"
            k3s_running=true
          else
            echo "⏳ NOT RUNNING"
            
            # Show service status
            SERVICE_STATUS=$(ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
                            "sudo systemctl status k3s --no-pager -l 2>/dev/null | head -3" || \
                            echo "Status unavailable")
            echo "    $SERVICE_STATUS"
            
            sleep $CHECK_INTERVAL
            continue
          fi
        fi
        
        # Stage 3: K3s API Endpoint
        if [ "$api_reachable" = false ]; then
          echo -n "  [3/4] Checking K3s API endpoint... "
          if check_k3s_api; then
            echo "✓ REACHABLE"
            api_reachable=true
          else
            echo "⏳ NOT REACHABLE"
            
            # Show API server logs
            ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
                "sudo journalctl -u k3s -n 3 --no-pager 2>/dev/null | tail -3" || \
                echo "    Logs unavailable"
            
            sleep $CHECK_INTERVAL
            continue
          fi
        fi
        
        # Stage 4: Node Ready Status
        if [ "$node_ready" = false ]; then
          echo -n "  [4/4] Checking node ready status... "
          if check_node_ready; then
            echo "✓ READY"
            node_ready=true
            break
          else
            echo "⏳ NOT READY"
            
            # Show node status
            ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
                "sudo k3s kubectl get nodes 2>/dev/null" || \
                echo "    Unable to get node status"
            
            sleep $CHECK_INTERVAL
            continue
          fi
        fi
        
        sleep $CHECK_INTERVAL
      done
      
      echo ""
      echo "=== Final Status ==="
      
      if [ "$node_ready" = true ]; then
        echo "✓ SUCCESS: K3s cluster is fully operational!"
        echo ""
        echo "Summary:"
        echo "  K3s Installed: ✓"
        echo "  K3s Service Running: ✓"
        echo "  K3s API Reachable: ✓"
        echo "  Node Ready: ✓"
        echo ""
        echo "Total time: $${elapsed_minutes}m $${remaining_seconds}s"
        echo "API Endpoint: https://${local.node_ip}:6443"
        echo ""
        
        # Get K3s version
        K3S_VERSION=$(ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
                      "k3s --version 2>/dev/null | head -1" || echo "unknown")
        echo "K3s Version: $K3S_VERSION"
        
        # Get detailed node status
        echo ""
        echo "=== Node Details ==="
        ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
            "sudo k3s kubectl get nodes -o wide 2>/dev/null" || \
            echo "Unable to retrieve node details"
        
        # Get pod status
        echo ""
        echo "=== System Pods ==="
        ssh $SSH_OPTS ${var.ssh_username}@${local.node_ip} \
            "sudo k3s kubectl get pods -A 2>/dev/null" || \
            echo "Unable to retrieve pod status"
        
        echo ""
        exit 0
      else
        echo "✗ TIMEOUT: K3s cluster failed to become ready within $MAX_WAIT_MINUTES minutes"
        echo ""
        echo "Progress Summary:"
        echo "  K3s Installed: $([ "$k3s_installed" = true ] && echo "✓" || echo "✗")"
        echo "  K3s Service Running: $([ "$k3s_running" = true ] && echo "✓" || echo "✗")"
        echo "  K3s API Reachable: $([ "$api_reachable" = true ] && echo "✓" || echo "✗")"
        echo "  Node Ready: $([ "$node_ready" = true ] && echo "✓" || echo "✗")"
        echo ""
        echo "Total time elapsed: $${elapsed_minutes}m $${remaining_seconds}s"
        echo ""
        
        # Diagnostic information
        echo "=== Diagnostic Information ==="
        echo ""
        
        if [ "$k3s_installed" = false ]; then
          echo "Issue: K3s installation failed or incomplete"
          echo "Possible causes:"
          echo "  - K3s installation script failed"
          echo "  - Network issues downloading K3s"
          echo "  - Insufficient system resources"
          echo ""
          echo "Troubleshooting steps:"
          echo "  1. SSH to VM: ssh ${var.ssh_username}@${local.node_ip}"
          echo "  2. Check cloud-init logs: sudo cat /var/log/cloud-init-output.log | grep -A 20 'k3s'"
          echo "  3. Manual install: curl -sfL https://get.k3s.io | sh -"
          echo "  4. Check system resources: free -h && df -h"
        elif [ "$k3s_running" = false ]; then
          echo "Issue: K3s service is not running"
          echo "Possible causes:"
          echo "  - K3s service failed to start"
          echo "  - Configuration errors"
          echo "  - Port conflicts"
          echo ""
          echo "Troubleshooting steps:"
          echo "  1. SSH to VM: ssh ${var.ssh_username}@${local.node_ip}"
          echo "  2. Check service status: sudo systemctl status k3s"
          echo "  3. View service logs: sudo journalctl -u k3s -n 50"
          echo "  4. Check for port conflicts: sudo netstat -tulpn | grep 6443"
          echo "  5. Try restarting: sudo systemctl restart k3s"
        elif [ "$api_reachable" = false ]; then
          echo "Issue: K3s API endpoint not reachable"
          echo "Possible causes:"
          echo "  - API server still initializing"
          echo "  - Firewall blocking port 6443"
          echo "  - Certificate generation issues"
          echo ""
          echo "Troubleshooting steps:"
          echo "  1. SSH to VM: ssh ${var.ssh_username}@${local.node_ip}"
          echo "  2. Check API server: sudo k3s kubectl get nodes"
          echo "  3. Check API logs: sudo journalctl -u k3s | grep apiserver"
          echo "  4. Verify port listening: sudo netstat -tulpn | grep 6443"
          echo "  5. Test locally: curl -k https://localhost:6443/healthz"
        else
          echo "Issue: Node not reaching Ready state"
          echo "Possible causes:"
          echo "  - Container runtime issues"
          echo "  - Network plugin not ready"
          echo "  - System pods failing to start"
          echo ""
          echo "Troubleshooting steps:"
          echo "  1. SSH to VM: ssh ${var.ssh_username}@${local.node_ip}"
          echo "  2. Check node status: sudo k3s kubectl get nodes -o wide"
          echo "  3. Check node conditions: sudo k3s kubectl describe node"
          echo "  4. Check system pods: sudo k3s kubectl get pods -A"
          echo "  5. Check pod logs: sudo k3s kubectl logs -n kube-system <pod-name>"
        fi
        
        echo ""
        echo "=== Quick Access Commands ==="
        echo "  SSH to VM: ssh ${var.ssh_username}@${local.node_ip}"
        echo "  Check K3s status: ssh ${var.ssh_username}@${local.node_ip} 'sudo systemctl status k3s'"
        echo "  View K3s logs: ssh ${var.ssh_username}@${local.node_ip} 'sudo journalctl -u k3s -f'"
        echo "  Check nodes: ssh ${var.ssh_username}@${local.node_ip} 'sudo k3s kubectl get nodes'"
        echo ""
        
        exit 1
      fi
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }

  triggers = {
    vm_id = libvirt_domain.ubuntu_vm.id
    node_ip   = local.node_ip
    timestamp = timestamp()
  }
}

# ============================================================================
# KUBECONFIG RETRIEVAL (ONLY FOR K3S SERVER NODES)
# ============================================================================
resource "null_resource" "retrieve_kubeconfig" {
  count = var.k3s_node_role == "server" ? 1 : 0

  depends_on = [
    null_resource.wait_for_k3s
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "=== Retrieving K3s Kubeconfig ==="
      echo "Node IP: ${local.node_ip}"
      echo ""
      
      # Create kubeconfig directory
      KUBECONFIG_DIR="${path.root}/kubeconfigs"
      mkdir -p "$KUBECONFIG_DIR"
      
      # Retrieve kubeconfig from server
      echo "Downloading kubeconfig from K3s server..."
      scp -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          ${var.ssh_username}@${local.node_ip}:/etc/rancher/k3s/k3s.yaml \
          "$KUBECONFIG_DIR/k3s-${local.sanitized_hostname}.yaml"
      
      # Replace localhost with actual IP
      echo "Updating server address in kubeconfig..."
      sed -i.bak "s/127.0.0.1/${local.node_ip}/g" \
          "$KUBECONFIG_DIR/k3s-${local.sanitized_hostname}.yaml"
      
      # Set proper permissions
      chmod 600 "$KUBECONFIG_DIR/k3s-${local.sanitized_hostname}.yaml"
      
      echo ""
      echo "✓ Kubeconfig retrieved successfully"
      echo "  Location: $KUBECONFIG_DIR/k3s-${local.sanitized_hostname}.yaml"
      echo ""
      echo "To use this kubeconfig:"
      echo "  export KUBECONFIG=$KUBECONFIG_DIR/k3s-${local.sanitized_hostname}.yaml"
      echo "  kubectl get nodes"
      echo ""
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }

  triggers = {
    k3s_ready = join(",", null_resource.wait_for_k3s[*].id)
  }
}

# ============================================================================
# FINAL DEPLOYMENT SUMMARY
# ============================================================================
resource "null_resource" "deployment_summary" {
  depends_on = [
    libvirt_domain.ubuntu_vm,
    null_resource.health_check,
    null_resource.wait_for_ssh,
    null_resource.wait_for_k3s,
    null_resource.retrieve_kubeconfig
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      # Logging setup
      LOG_FILE="${path.root}/logs/.deployment_summary.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      echo ""
      echo "╔════════════════════════════════════════════════════════════════╗"
      echo "║           🎉 VM DEPLOYMENT COMPLETED SUCCESSFULLY 🎉           ║"
      echo "╚════════════════════════════════════════════════════════════════╝"
      echo ""
      echo "=== VM Information ==="
      echo "  Hostname: ${var.vm_hostname}"
      echo "  Domain Name: ${local.sanitized_hostname}"
      echo "  IP Address: ${local.node_ip}"
      echo "  Username: ${var.ssh_username}"
      echo "  Memory: ${var.vm_memory} MB"
      echo "  vCPU: ${var.vm_vcpu}"
      echo "  Disk Size: $(echo "scale=2; ${var.vm_disk_size} / 1024 / 1024 / 1024" | bc) GB"
      echo ""
      
      echo "=== Network Configuration ==="
      echo "  Network: ${var.network_name}"
      echo "  Gateway: ${var.vm_gateway}"
      echo "  DNS Servers: ${join(", ", var.vm_nameservers)}"
      echo ""
      
      echo "=== K3s Configuration ==="
      echo "  Node Role: ${var.k3s_node_role}"
      echo "  K3s Version: ${var.k3s_version}"
      
      if [ "${var.k3s_node_role}" = "server" ]; then
        echo "  API Endpoint: https://${local.node_ip}:6443"
        echo "  Kubeconfig: ${path.root}/kubeconfigs/k3s-${local.sanitized_hostname}.yaml"
      else
        echo "  Server URL: ${var.k3s_server_url}"
      fi
      echo ""
      
      echo "=== Access Commands ==="
      echo "  SSH Access:"
      echo "    ssh ${var.ssh_username}@${local.node_ip}"
      echo ""
      
      if [ "${var.k3s_node_role}" = "server" ]; then
        echo "  Kubectl Access:"
        echo "    export KUBECONFIG=${path.root}/kubeconfigs/k3s-${local.sanitized_hostname}.yaml"
        echo "    kubectl get nodes"
        echo "    kubectl get pods -A"
        echo ""
      fi
      
      echo "  VM Management:"
      echo "    virsh list --all"
      echo "    virsh dominfo ${local.sanitized_hostname}"
      echo "    virsh console ${local.sanitized_hostname}"
      echo ""
      
      echo "=== Log Files ==="
      echo "  Deployment logs: ${path.root}/logs/"
      echo "  - Virtualization detection: .virt_detection.log"
      echo "  - Pre-deployment check: .pre_deployment_check.log"
      echo "  - Health check: .health_check.log"
      echo "  - K3s wait: .k3s_wait.log"
      echo "  - Deployment summary: .deployment_summary.log"
      echo ""
      
      echo "=== Next Steps ==="
      if [ "${var.k3s_node_role}" = "server" ]; then
        echo "  1. Verify K3s cluster:"
        echo "     export KUBECONFIG=${path.root}/kubeconfigs/k3s-${local.sanitized_hostname}.yaml"
        echo "     kubectl get nodes -o wide"
        echo "     kubectl get pods -A"
        echo ""
        echo "  2. Deploy applications:"
        echo "     kubectl apply -f your-app.yaml"
        echo ""
        echo "  3. Access K3s dashboard (if installed):"
        echo "     kubectl proxy"
        echo ""

        echo "  4. Add worker nodes:"
        echo "     Use the K3s token and server URL from this deployment"
        echo "     Server URL: https://${local.node_ip}:6443"
        echo "     Token: (retrieve from /var/lib/rancher/k3s/server/node-token)"
      else
        echo "  1. Verify node joined the cluster:"
        echo "     ssh ${var.ssh_username}@${local.node_ip}"
        echo "     sudo k3s kubectl get nodes"
        echo ""
        echo "  2. Check node status from server:"
        echo "     kubectl get nodes -o wide"
        echo "     kubectl describe node ${var.vm_hostname}"
      fi
      echo ""
      
      echo "=== Troubleshooting ==="
      echo "  If you encounter issues:"
      echo "  1. Check VM status: virsh domstate ${local.sanitized_hostname}"
      echo "  2. View VM console: virsh console ${local.sanitized_hostname}"
      echo "  3. Check K3s logs: ssh ${var.ssh_username}@${local.node_ip} 'sudo journalctl -u k3s -f'"
      echo "  4. Review deployment logs in: ${path.root}/logs/"
      echo ""
      
      echo "╔════════════════════════════════════════════════════════════════╗"
      echo "║                    DEPLOYMENT SUMMARY END                      ║"
      echo "╚════════════════════════════════════════════════════════════════╝"
      echo ""
      
      # Save summary to a dedicated file
      SUMMARY_FILE="${path.root}/deployment-summary-${local.sanitized_hostname}.txt"
      cat > "$SUMMARY_FILE" << 'SUMMARY'
╔════════════════════════════════════════════════════════════════╗
║           VM DEPLOYMENT SUMMARY                                ║
╚════════════════════════════════════════════════════════════════╝

VM Information:
  Hostname: ${var.vm_hostname}
  Domain: ${local.sanitized_hostname}
  IP Address: ${local.node_ip}
  Username: ${var.ssh_username}
  Memory: ${var.vm_memory} MB
  vCPU: ${var.vm_vcpu}

K3s Configuration:
  Role: ${var.k3s_node_role}
  Version: ${var.k3s_version}
  API Endpoint: https://${local.node_ip}:6443

Quick Access:
  SSH: ssh ${var.ssh_username}@${local.node_ip}
  Kubeconfig: ${path.root}/kubeconfigs/k3s-${local.sanitized_hostname}.yaml

Generated: $(date)
SUMMARY
      
      echo "✓ Deployment summary saved to: $SUMMARY_FILE"
      echo ""
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }

  triggers = {
    vm_id     = libvirt_domain.ubuntu_vm.id
    timestamp = timestamp()
  }
}


# ============================================================================
# CLEANUP ON DESTROY
# ============================================================================
resource "null_resource" "cleanup_on_destroy" {
  triggers = {
    vm_id     = libvirt_domain.ubuntu_vm.id
    hostname  = local.sanitized_hostname
    pool_name = local.pool_name
    node_ip   = local.node_ip
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set +e
      
      echo "=== Cleanup on Destroy ==="
      echo "Timestamp: $(date)"
      echo "VM: ${self.triggers.hostname}"
      echo "Pool: ${self.triggers.pool_name}"
      echo ""
      
      # Stop VM if running
      echo "Checking VM state..."
      if sudo virsh domstate "${self.triggers.hostname}" 2>/dev/null | grep -q "running"; then
        echo "Stopping VM..."
        sudo virsh destroy "${self.triggers.hostname}" 2>/dev/null || true
        sleep 3
      fi
      
      # Undefine VM
      echo "Undefining VM..."
      sudo virsh undefine "${self.triggers.hostname}" --remove-all-storage 2>/dev/null || true
      sleep 2
      
      # Clean up volumes
      echo "Cleaning up volumes..."
      VOLUMES=(
        "cloudinit-${self.triggers.hostname}.iso"
        "ubuntu-disk-${self.triggers.hostname}.qcow2"
        "ubuntu-base-img-${self.triggers.hostname}.qcow2"
      )
      
      for VOL in "$${VOLUMES[@]}"; do
        if sudo virsh vol-info "$VOL" --pool "${self.triggers.pool_name}" >/dev/null 2>&1; then
          echo "  Deleting volume: $VOL"
          sudo virsh vol-delete "$VOL" --pool "${self.triggers.pool_name}" 2>/dev/null || true
        fi
      done
      
      # Refresh pool
      echo "Refreshing storage pool..."
      sudo virsh pool-refresh "${self.triggers.pool_name}" 2>/dev/null || true
      
      # Clean up kubeconfig
      KUBECONFIG_FILE="${path.root}/kubeconfigs/k3s-${self.triggers.hostname}.yaml"
      if [ -f "$KUBECONFIG_FILE" ]; then
        echo "Removing kubeconfig..."
        rm -f "$KUBECONFIG_FILE" "$KUBECONFIG_FILE.bak"
      fi
      
      # Clean up summary file
      SUMMARY_FILE="${path.root}/deployment-summary-${self.triggers.hostname}.txt"
      if [ -f "$SUMMARY_FILE" ]; then
        echo "Removing deployment summary..."
        rm -f "$SUMMARY_FILE"
      fi
      
      echo ""
      echo "✓ Cleanup completed"
      echo "Completed at: $(date)"
    EOT

    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue
  }
}
