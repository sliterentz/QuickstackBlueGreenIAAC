output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = "${path.module}/kubeconfig"
}

output "argocd_url" {
  description = "URL for ArgoCD"
  value       = "https://${var.argocd_hostname}"
}
