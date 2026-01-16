
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

resource "libvirt_cloudinit_disk" "commoninit" {
  name           = "cloudinit-${local.sanitized_hostname}.iso"
  user_data      = data.template_file.user_data.rendered
  network_config = data.template_file.network_config.rendered
  pool           = local.pool_name

  depends_on = [
    null_resource.pool_management,
    data.template_file.user_data,
    data.template_file.network_config
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# VIRTUAL MACHINE DOMAIN
# ============================================================================
resource "libvirt_domain" "ubuntu_vm" {
  name   = local.sanitized_hostname
  memory = var.vm_memory
  vcpu   = var.vm_vcpu

  # Domain type (kvm or qemu)
  type = var.libvirt_domain_type

  # CPU Configuration untuk performa optimal
  cpu {
    mode = var.cpu_mode
  }

  # Machine type untuk kompatibilitas
  machine = local.use_uefi ? "q35" : "pc"
  arch    = "x86_64"

  # Firmware - conditional UEFI (FIXED: only set if file exists)
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
    wait_for_lease = true

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
    null_resource.validation
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
    create = "10m"
  }
}

# ============================================================================
# POST-DEPLOYMENT VERIFICATION
# ============================================================================
resource "null_resource" "health_check" {
  depends_on = [libvirt_domain.ubuntu_vm]

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Deployment Health Check ==="
      echo "Hostname: ${var.vm_hostname}"
      echo "IP Address: ${local.node_ip}"
      echo "Timestamp: ${local.deployment_timestamp}"
      echo "Waiting for VM to be ready..."
      sleep 30
      
      # Verify VM is running
      if virsh list --all | grep -q "${local.sanitized_hostname}.*running"; then
        echo "✓ VM is running"
      else
        echo "✗ VM is not running"
        exit 1
      fi
      
      # Verify network connectivity (jika IP tersedia)
      if [ -n "${local.node_ip}" ]; then
        echo "Testing network connectivity to ${local.node_ip}..."
        timeout 60 bash -c "until ping -c 1 ${local.node_ip} &>/dev/null; do sleep 2; done" && echo "✓ Network is reachable" || echo "✗ Network not reachable (may need more time)"
      fi
      
      echo "=== Health Check Complete ==="
    EOT

    on_failure = continue
  }

  triggers = {
    vm_id = libvirt_domain.ubuntu_vm.id
  }
}