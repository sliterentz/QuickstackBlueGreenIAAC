output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = "${path.module}/kubeconfig"
}

output "argocd_url" {
  description = "URL for ArgoCD"
  value       = "https://${var.argocd_hostname}"
}

output "vm_ip" {
  description = "IP address of the KVM VM"
  value       = var.server_ips[0]
}

output "kubeconfig_ready" {
  description = "Whether the kubeconfig is ready to be used by providers"
  value       = local.kubeconfig_ready
}
