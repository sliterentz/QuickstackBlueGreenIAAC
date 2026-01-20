# ============================================================================
# LIBVIRT CONFIGURATION
# ============================================================================

variable "libvirt_pool_name" {
  description = "Nama storage pool untuk VM (Default: k3s_infra_pool)"
  type        = string
  default     = "k3s_infra_pool"
}

variable "enable_uefi" {
  description = "Enable UEFI firmware (requires OVMF package installed)"
  type        = bool
  default     = false # Set to false to use BIOS by default
}

variable "cpu_mode" {
  description = "CPU mode for VM (host-passthrough, host-model, or custom)"
  type        = string
  default     = "host-passthrough"

  validation {
    condition     = contains(["host-passthrough", "host-model", "custom"], var.cpu_mode)
    error_message = "CPU mode must be one of: host-passthrough, host-model, custom"
  }
}

variable "enable_qemu_agent" {
  description = "Enable QEMU guest agent"
  type        = bool
  default     = true
}

variable "autostart" {
  description = "Autostart VM on host boot"
  type        = bool
  default     = false
}

variable "video_type" {
  description = "Video adapter type (virtio, qxl, vga)"
  type        = string
  default     = "virtio"

  validation {
    condition     = contains(["virtio", "qxl", "vga"], var.video_type)
    error_message = "Video type must be one of: virtio, qxl, vga"
  }
}

variable "vm_hostname" {
  description = "Hostname untuk virtual machine"
  type        = string
  default     = "k3s-master-01"
}

variable "vm_memory" {
  description = "Jumlah RAM dalam MB (Rekomendasi min 8GB untuk K8s)"
  type        = number
  default     = 8192
}

variable "vm_vcpu" {
  description = "Jumlah virtual CPU (Rekomendasi min 4 core untuk K8s)"
  type        = number
  default     = 4
}

variable "vm_disk_size" {
  description = "Ukuran disk dalam bytes (Rekomendasi min 50GB untuk K8s)"
  type        = number
  default     = 53687091200 # 50GB
}

variable "ubuntu_img_url" {
  description = "URL download image Ubuntu Cloud (qcow2)"
  type        = string
  # Ubuntu 24.04 LTS (Noble Numbat) Cloud Image
  default = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  description = "Public key SSH untuk akses ke VM"
  type        = string
  # Ganti dengan path ke public key Anda yang sebenarnya, misal ~/.ssh/id_rsa.pub
  default = "~/.ssh/id_rsa.pub"
}

variable "ssh_username" {
  description = "Username untuk SSH"
  type        = string
  default     = "ubuntu"
}

variable "network_name" {
  description = "Nama network bridge libvirt (default biasanya 'default')"
  type        = string
  default     = "default"
}

# Konfigurasi IP baru untuk K3s
variable "vm_ip_address" {
  description = "Static IP address untuk VM (format: 192.168.122.10/24)"
  type        = string
  default     = ""
}

variable "vm_gateway" {
  description = "Gateway IP address"
  type        = string
  default     = "192.168.122.1"
}

variable "vm_nameservers" {
  description = "DNS nameservers"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "vm_mac_address" {
  description = "MAC address untuk VM network interface (kosong untuk auto-generate)"
  type        = string
  default     = ""

  validation {
    condition     = var.vm_mac_address == "" || can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", var.vm_mac_address))
    error_message = "MAC address must be in format XX:XX:XX:XX:XX:XX or empty for auto-generation"
  }
}

variable "k3s_version" {
  description = "Versi K3s yang akan diinstall"
  type        = string
  default     = "v1.31.0+k3s1"
}

variable "k3s_token" {
  description = "Token untuk K3s cluster (untuk multi-node setup)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "k3s_server_url" {
  description = "URL K3s server untuk agent nodes (kosongkan jika ini server node)"
  type        = string
  default     = ""
}

variable "k3s_node_role" {
  description = "Role node: server atau agent"
  type        = string
  default     = "server"
  validation {
    condition     = contains(["server", "agent"], var.k3s_node_role)
    error_message = "Node role harus 'server' atau 'agent'."
  }
}

variable "libvirt_domain_type" {
  description = "Domain type for libvirt (kvm or qemu). Use 'qemu' if nested virtualization is not available."
  type        = string
  default     = "kvm"
  validation {
    condition     = contains(["kvm", "qemu"], var.libvirt_domain_type)
    error_message = "Domain type must be 'kvm' or 'qemu'."
  }
}

# ============================================================================
# DEPLOYMENT BEHAVIOR VARIABLES
# ============================================================================
variable "wait_for_ssh" {
  description = "Wait for SSH to be ready before completing deployment"
  type        = bool
  default     = true
}

variable "ssh_timeout" {
  description = "Maximum time to wait for SSH in seconds"
  type        = number
  default     = 600
}

# ============================================
# Worker Node Configuration (N8N)
# ============================================
variable "worker_n8n_count" {
  description = "Number of N8N worker nodes"
  type        = number
  default     = 1
}

variable "worker_n8n_hostname" {
  description = "Hostname prefix for N8N worker nodes"
  type        = string
  default     = "n8n-worker"
}

variable "worker_n8n_memory" {
  description = "Memory for N8N worker nodes (MB)"
  type        = number
  default     = 4096
}

variable "worker_n8n_vcpu" {
  description = "vCPU for N8N worker nodes"
  type        = number
  default     = 2
}

variable "worker_n8n_ip_start" {
  description = "Starting IP address for N8N worker nodes (must be CIDR format e.g. 192.168.122.251/24)"
  type        = string
  default     = "192.168.122.251/24"
}
