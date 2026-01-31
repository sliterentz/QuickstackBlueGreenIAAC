# Main Terraform configuration file for Rancher, ArgoCD on RKE2

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.1"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.0"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.7.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
  required_version = ">= 1.0.0"
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "helm" {
  kubernetes {
    config_path = local.kube_config_path
    insecure    = true
  }
}

provider "kubernetes" {
  config_path = local.kube_config_path
  insecure    = true
}

provider "kubectl" {
  config_path      = local.kube_config_path
  load_config_file = true
  insecure         = true
}

# ============================================================================
# SHARED CONFIGURATION
# ============================================================================
# Generate secure K3s token automatically
resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

# Modul untuk membuat VM di KVM
module "kvm_ubuntu" {
  source = "./terraform-kvm-ubuntu"
  providers = {
    libvirt = libvirt
  }

  vm_hostname           = var.vm_hostname
  vm_memory             = var.vm_memory
  vm_vcpu               = var.vm_vcpu
  vm_disk_size          = var.vm_disk_size
  vm_ip_address         = var.vm_ip_address
  vm_gateway            = var.vm_gateway
  vm_nameservers        = var.vm_nameservers
  libvirt_pool_name     = var.libvirt_pool_name
  libvirt_domain_type   = var.libvirt_domain_type
  volume_create_timeout = "var.volume_create_timeout"
  volume_delete_timeout = "var.volume_delete_timeout"
  ubuntu_img_url        = var.ubuntu_img_url
  network_name          = var.network_name
  ssh_public_key        = "${var.ssh_private_key_path}.pub"
  ssh_username          = var.ssh_username
  k3s_version           = var.k3s_version
  k3s_node_role         = var.k3s_node_role
  k3s_server_url        = var.k3s_server_url
  # Use generated token if not provided in vars
  k3s_token           = var.k3s_token != "" ? var.k3s_token : random_password.k3s_token.result
  cpu_mode            = var.cpu_mode
  extra_hosts_entries = local.cluster_hosts_entries
}

# ============================================================================
# N8N WORKER NODES
# ============================================================================
module "n8n_worker" {
  source = "./terraform-kvm-ubuntu"
  count  = var.worker_n8n_count
  providers = {
    libvirt = libvirt
  }

  vm_hostname  = "${var.worker_n8n_hostname}-${count.index + 1}"
  vm_memory    = var.worker_n8n_memory
  vm_vcpu      = var.worker_n8n_vcpu
  vm_disk_size = var.vm_disk_size

  # Static IP Allocation: Increment from start IP
  # Example: 192.168.122.251/24 -> .251, .252, etc.
  vm_ip_address  = "${cidrhost(var.worker_n8n_ip_start, tonumber(split(".", split("/", var.worker_n8n_ip_start)[0])[3]) + count.index)}/24"
  vm_gateway     = var.vm_gateway
  vm_nameservers = var.vm_nameservers

  libvirt_pool_name   = var.libvirt_pool_name
  libvirt_domain_type = var.libvirt_domain_type
  ubuntu_img_url      = var.ubuntu_img_url
  network_name        = var.network_name
  ssh_public_key      = "${var.ssh_private_key_path}.pub"
  ssh_username        = var.ssh_username
  cpu_mode            = var.cpu_mode

  # K3s Agent Configuration
  k3s_version   = var.k3s_version
  k3s_node_role = "agent"
  # Connect to Master Node IP
  k3s_server_url = "https://${split("/", var.vm_ip_address)[0]}:6443"
  k3s_token      = var.k3s_token != "" ? var.k3s_token : random_password.k3s_token.result

  extra_hosts_entries = local.cluster_hosts_entries
  depends_on          = [module.kvm_ubuntu]
}

# Gunakan external data source untuk memastikan kubeconfig ada sebelum provider inisialisasi
data "external" "kubeconfig_init" {
  program = ["bash", "-c", <<-EOT
    if [ ! -f kubeconfig ]; then
      cat <<EOF > kubeconfig
apiVersion: v1
clusters:
- cluster:
    server: https://127.0.0.1:6443
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
    fi
    echo '{"status": "ready"}'
  EOT
  ]
}

# Data source untuk mendeteksi path kubeconfig secara dinamis
data "external" "kubeconfig" {
  program    = ["bash", "${path.module}/scripts/get_kubeconfig.sh"]
  depends_on = [data.external.kubeconfig_init]
}

locals {
  cluster_hosts_entries = concat(
    [format("%s %s", split("/", var.vm_ip_address)[0], var.vm_hostname)],
    [
      for idx in range(var.worker_n8n_count) : format(
        "%s %s-%d",
        cidrhost(var.worker_n8n_ip_start, tonumber(split(".", split("/", var.worker_n8n_ip_start)[0])[3]) + idx),
        var.worker_n8n_hostname,
        idx + 1
      )
    ]
  )

  # Cek apakah kubeconfig sudah berisi IP VM (bukan placeholder dummy)
  kubeconfig_content = fileexists("${path.module}/kubeconfig") ? file("${path.module}/kubeconfig") : ""

  # Hasil deteksi dari script shell
  detected_kube_path = data.external.kubeconfig.result["kube_config_path"]

  # Cluster dianggap siap jika file ada, berisi konfigurasi cluster (server URL), bukan IP local, dan bukan file kosong/dummy
  kubeconfig_ready = local.detected_kube_path != "NOT_FOUND" && length(regexall("server: https://", local.kubeconfig_content)) > 0 && length(regexall("127.0.0.1", local.kubeconfig_content)) == 0

  # Pastikan file kubeconfig ada (meskipun kosong) agar provider tidak error saat init
  # Kita buat file dummy jika tidak ada sama sekali
  kubeconfig_exists = fileexists("${path.module}/kubeconfig")

  # Logika pemilihan path dengan urutan prioritas:
  # 1. Hasil deteksi script (jika bukan NOT_FOUND)
  # 2. Input dari variable kube_config_path (jika diset di terraform.tfvars)
  # 3. Default fallback ke file local 'kubeconfig'
  kube_config_path = local.detected_kube_path != "NOT_FOUND" ? local.detected_kube_path : (
    var.kube_config_path != "" ? var.kube_config_path : "${path.module}/kubeconfig"
  )
}

# Pool management is now handled inside module.kvm_ubuntu using null_resource for idempotency.
# This avoids "already exists" errors when the pool exists in Libvirt but not in Terraform state.
