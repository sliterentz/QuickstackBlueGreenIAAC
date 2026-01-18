# Example variable values - rename to terraform.tfvars and update with your values
# ============================================
# Server Configuration
# ============================================
server_ips           = ["192.168.1.2"]
ssh_username         = "changeme_username"
ssh_private_key_path = "~/.ssh/id_rsa"
kube_config_path     = "kubeconfig"

# ============================================
# K3s Configuration
# ============================================
k3s_default_namespace = "kube-system"
k3s_version           = "v1.31.0+k3s1"
k3s_node_role         = "server"
k3s_server_url        = "" # Required for agent nodes: https://server-ip:6443
k3s_token             = "" # Required for agent nodes

# Uncomment untuk agent nodes:
# k3s_server_url = "https://192.168.1.2:6443"
# k3s_token      = "your-k3s-token-here"

# ============================================
# ArgoCD Configuration
# ============================================
deploy_argocd          = false
argocd_namespace       = "argocd"
argocd_hostname        = "argocd.localhost.local"
argocd_admin_password  = "strong_password"
argocd_tls_secret_name = "argocd-tls-secret"

# ============================================
# PostgreSQL Configuration
# ============================================
postgres_database      = "your_db_name"
postgres_root_password = "strong_db_password"
postgres_username      = "changeme_username"
postgres_password      = "strong_db_password"

# ============================================
# MariaDB Configuration
# ============================================
mariadb_database      = "your_db_name"
mariadb_username      = "changeme_username"
mariadb_password      = "strong_db_password"
mariadb_root_password = "strong_db_password"

# ============================================
# MongoDB Configuration
# ============================================
mongo_username = "changeme_username"
mongo_password = "strong_db_password"

# ============================================
# Redis Configuration
# ============================================
redis_password = "strong_db_password"

# ============================================
# N8N Configuration
# ============================================
n8n_hostname       = "your_n8n_domain.com"
n8n_encryption_key = "strong_encription_key"
n8n_db_host        = ""
n8n_db_user        = "changeme_username"
n8n_db_password    = "strong_db_password"

# ============================================
# General Configuration
# ============================================
GENERIC_TIMEZONE = "Asia/Jakarta"

# ============================================
# VM Configuration (KVM/Libvirt)
# ============================================
vm_hostname  = "k3s-master-01"
vm_memory    = 4096
vm_vcpu      = 2
vm_disk_size = 21474836480 # 20GB

# ============================================
# Network Configuration
# ============================================
network_name   = "default"
vm_ip_address  = "192.168.1.2/24"
vm_mac_address = "" # Leave empty for auto-generation
vm_gateway     = "192.168.1.1"
vm_nameservers = ["8.8.8.8", "8.8.4.4"]

# ============================================
# Ubuntu Image Configuration
# ============================================
libvirt_pool_name = "default_pool"
ubuntu_img_url    = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
enable_uefi       = false # Set to true if OVMF is installed
cpu_mode          = "host-passthrough"
enable_qemu_agent = true
autostart         = false
video_type        = "virtio"
wait_for_ssh      = true
ssh_timeout       = 300

# SSH Public Key (opsional, jika menggunakan KVM module)
# ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... your-key-here"

# Integration Credentials (will be used inside n8n UI, but good to have ready)
open_api_key                    = "changeme_key"
whatsapp_access_token           = "access_token"
whatsapp_phone_number_id        = "phone_number"
whatsapp_bussiness_account_id   = "bussiness_id"