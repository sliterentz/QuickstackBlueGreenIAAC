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
  }
  required_version = ">= 1.0.0"
}

provider "helm" {
  kubernetes {
    config_path = local.kube_config_path
  }
}

provider "kubernetes" {
  config_path = local.kubeconfig_ready ? local.kube_config_path : null
  # Jika kubeconfig belum siap, jangan gunakan default localhost:80
  # Gunakan dummy host agar tidak timeout ke 127.0.0.1
  host = local.kubeconfig_ready ? null : "http://cluster-not-ready-yet"
}

provider "kubectl" {
  config_path = local.kubeconfig_ready ? local.kube_config_path : null
  load_config_file = local.kubeconfig_ready
  host = local.kubeconfig_ready ? null : "http://cluster-not-ready-yet"
}

# Modul untuk membuat VM di KVM
module "kvm_ubuntu" {
  source = "./terraform-kvm-ubuntu"

  vm_hostname    = "k3s-master-vm"
  vm_memory      = 8192
  vm_vcpu        = 4
  ssh_public_key = file("~/.ssh/id_rsa.pub")
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
  kubeconfig_ready   = length(regexall("clusters:", local.kubeconfig_content)) > 0 && length(regexall("127.0.0.1", local.kubeconfig_content)) == 0

  # Hasil deteksi dari script shell
  detected_kube_path = data.external.kubeconfig.result["kube_config_path"]

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