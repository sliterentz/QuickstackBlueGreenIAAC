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
  }
  required_version = ">= 1.0.0"
}

provider "libvirt" {
  uri = "qemu:///system"
}

provider "helm" {
  kubernetes {
    config_path = local.kube_config_path
  }
}

provider "kubernetes" {
  config_path = local.kubeconfig_ready ? local.kube_config_path : null
  # Jika kubeconfig belum siap, gunakan dummy host agar tidak error saat refresh
  host = local.kubeconfig_ready ? null : "https://localhost:0"
}

provider "kubectl" {
  config_path      = local.kubeconfig_ready ? local.kube_config_path : null
  load_config_file = local.kubeconfig_ready
  host             = local.kubeconfig_ready ? null : "https://localhost:0"
}

# Modul untuk membuat VM di KVM
module "kvm_ubuntu" {
  source = "./terraform-kvm-ubuntu"

  vm_hostname    = var.vm_hostname
  vm_memory      = var.vm_memory
  vm_vcpu        = var.vm_vcpu
  vm_disk_size   = var.vm_disk_size
  vm_ip_address  = var.vm_ip_address
  vm_gateway     = var.vm_gateway
  vm_nameservers = var.vm_nameservers
  ubuntu_img_url = var.ubuntu_img_url
  network_name   = var.network_name
  ssh_public_key = file("${var.ssh_private_key_path}.pub")
  ssh_username   = var.ssh_username
  libvirt_domain_type = var.libvirt_domain_type
  cpu_mode       = var.cpu_mode
}

# Gunakan external data source untuk memastikan kubeconfig ada sebelum provider inisialisasi
data "external" "kubeconfig_init" {
  program = ["bash", "-c", <<-EOT
    if [ ! -f kubeconfig ]; then
      cat <<EOF > kubeconfig
apiVersion: v1
clusters: []
contexts: []
current-context: ""
kind: Config
preferences: {}
users: []
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