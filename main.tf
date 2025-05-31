# Main Terraform configuration file for Rancher, ArgoCD on RKE2

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "3.0.0-pre2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37.1"
    }
  }
  required_version = ">= 1.0.0"
}

provider "helm" {
  kubernetes = {
    config_path = local.kube_config_path
  }
}

provider "kubernetes" {
  config_path = local.kube_config_path
}

locals {
  kube_config_path = "${path.module}/kubeconfig"
}