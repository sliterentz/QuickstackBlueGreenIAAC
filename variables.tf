# ============================================
# Server Configuration Variables
# ============================================
variable "server_ips" {
  description = "List of server IP addresses untuk K3s cluster"
  type        = list(string)
}

variable "kube_config_path" {
  description = "Path untuk menyimpan kubeconfig file"
  type        = string
  default     = "kubeconfig"
}

# ============================================
# K3s Configuration Variables
# ============================================
variable "k3s_default_namespace" {
  description = "Default namespace untuk K3s resources"
  type        = string
  default     = "kube-system"
}

variable "k3s_version" {
  description = "Versi K3s yang akan diinstall"
  type        = string
  default     = "v1.31.0+k3s1"
}

variable "k3s_node_role" {
  description = "Role K3s node: server atau agent"
  type        = string
  default     = "server"
  validation {
    condition     = contains(["server", "agent"], var.k3s_node_role)
    error_message = "Node role harus 'server' atau 'agent'."
  }
}

variable "k3s_server_url" {
  description = "URL K3s server untuk agent nodes"
  type        = string
  default     = ""
}

variable "k3s_token" {
  description = "Token untuk K3s cluster"
  type        = string
  default     = ""
  sensitive   = true
}

# ============================================
# PostgreSQL Configuration Variables
# ============================================
variable "postgres_database" {
  description = "Nama database PostgreSQL"
  type        = string
}

variable "postgres_root_password" {
  description = "Root password untuk PostgreSQL"
  type        = string
  sensitive   = true
}

variable "postgres_username" {
  description = "Username untuk PostgreSQL"
  type        = string
}

variable "postgres_password" {
  description = "Password untuk PostgreSQL user"
  type        = string
  sensitive   = true
}

# ============================================
# MariaDB Configuration Variables
# ============================================
variable "mariadb_database" {
  description = "Nama database MariaDB"
  type        = string
}

variable "mariadb_username" {
  description = "Username untuk MariaDB"
  type        = string
}

variable "mariadb_password" {
  description = "Password untuk MariaDB user"
  type        = string
  sensitive   = true
}

variable "mariadb_root_password" {
  description = "Root password untuk MariaDB"
  type        = string
  sensitive   = true
}

# ============================================
# MongoDB Configuration Variables
# ============================================
variable "mongo_username" {
  description = "Username untuk MongoDB admin"
  type        = string
}

variable "mongo_password" {
  description = "Password untuk MongoDB admin"
  type        = string
  sensitive   = true
}

# ============================================
# Redis Configuration Variables
# ============================================
variable "redis_password" {
  description = "Password untuk Redis"
  type        = string
  sensitive   = true
}

# ============================================
# N8N Configuration Variables
# ============================================
variable "enable_blue_environment" {
  description = "Enable Blue environment deployment"
  type        = bool
  default     = false
}

variable "n8n_namespace" {
  description = "Namespace for n8n deployment"
  type        = string
  default     = "n8n"
}

variable "n8n_hostname" {
  description = "Hostname untuk N8N instance"
  type        = string
}

variable "n8n_encryption_key" {
  description = "Encryption key untuk N8N"
  type        = string
  sensitive   = true
}

variable "n8n_db_host" {
  description = "Database host untuk N8N"
  type        = string
  default     = ""
}

variable "n8n_db_name" {
  description = "PostgreSQL database name for n8n"
  type        = string
  default     = "n8n"
}

variable "n8n_db_user" {
  description = "Database user untuk N8N"
  type        = string
}

variable "n8n_db_password" {
  description = "Database password untuk N8N"
  type        = string
  sensitive   = true
}

variable "n8n_storage_size" {
  description = "Storage size for n8n data"
  type        = string
  default     = "1Gi"
}

variable "n8n_replicas" {
  description = "Number of n8n replicas"
  type        = number
  default     = 1
}

variable "n8n_hpa_min_replicas" {
  description = "Minimum replicas for HPA"
  type        = number
  default     = 1
}

variable "n8n_hpa_max_replicas" {
  description = "Maximum replicas for HPA"
  type        = number
  default     = 2
}

# ============================================
# ============================================
# General Configuration Variables
# ============================================
variable "GENERIC_TIMEZONE" {
  description = "Timezone untuk aplikasi"
  type        = string
  default     = "Asia/Jakarta"
}

# ============================================
# VM Configuration Variables (KVM/Libvirt)
# ============================================
variable "vm_hostname" {
  description = "Hostname untuk VM"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.vm_hostname))
    error_message = "Hostname must be a valid DNS name (lowercase alphanumeric and hyphens only)"
  }
}

variable "vm_memory" {
  description = "Memory VM dalam MB"
  type        = number
  default     = 4096
}

variable "vm_vcpu" {
  description = "Jumlah vCPU"
  type        = number
  default     = 2
}

variable "vm_disk_size" {
  description = "Ukuran disk VM dalam bytes"
  type        = number
  default     = 21474836480 # 20GB
}

variable "network_name" {
  description = "Nama network libvirt"
  type        = string
  default     = "default"
}

variable "vm_ip_address" {
  description = "Static IP address untuk VM (format: 192.168.122.10/24)"
  type        = string
  default     = ""

  validation {
    condition = var.vm_ip_address == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2})?$", var.vm_ip_address))
    error_message = "The vm_ip_address must be a valid IP address with optional CIDR notation (e.g., '192.168.122.10' or '192.168.122.10/24'), or empty for DHCP."
  }
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

variable "vm_gateway" {
  description = "Gateway IP address"
  type        = string
  default     = "192.168.122.1"

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.vm_gateway))
    error_message = "The vm_gateway must be a valid IP address."
  }
}

variable "vm_nameservers" {
  description = "DNS nameservers"
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]

  validation {
    condition = alltrue([
      for ns in var.vm_nameservers : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", ns))
    ])
    error_message = "All nameservers must be valid IP addresses."
  }
}

# ============================================================================
# LIBVIRT CONFIGURATION VARIABLES
# ============================================================================
variable "libvirt_pool_name" {
  description = "Name of the libvirt storage pool"
  type        = string
  default     = "k3s_infra_pool"
}

variable "libvirt_pool_path" {
  description = "Path for the libvirt storage pool (only used if pool doesn't exist)"
  type        = string
  default     = "/var/lib/libvirt/images"
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

variable "ubuntu_img_url" {
  description = "URL Ubuntu Cloud Image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "enable_uefi" {
  description = "Enable UEFI firmware (requires OVMF package)"
  type        = bool
  default     = false
}

variable "cpu_mode" {
  description = "CPU mode (host-passthrough, host-model, or custom)"
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

variable "ssh_public_key" {
  description = "SSH Public Key untuk akses VM"
  type        = string
}

variable "ssh_username" {
  description = "Username untuk SSH ke server"
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Path ke SSH private key"
  type        = string
}

variable "open_api_key" {
  description = "Open AI API Key"
  type        = string
  default     = ""
}

variable "whatsapp_access_token" {
  description = "Whatsapp Access Token"
  type        = string
  default     = ""
}

variable "whatsapp_phone_number_id" {
  description = "Whatsapp Phone Number ID"
  type        = string
  default     = ""
}

variable "whatsapp_bussiness_account_id" {
  description = "Whatsapp Business Account ID"
  type        = string
  default     = ""
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
