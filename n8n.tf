# Terraform configuration to deploy n8n using the YAML manifest

data "kubectl_path_documents" "n8n_manifests" {
  pattern = "${path.module}/n8n-optimized.yaml"
  vars = {
    namespace          = var.n8n_namespace
    n8n_hostname       = var.n8n_hostname
    n8n_encryption_key = var.n8n_encryption_key
    # Note: DB host/user/pass now point to existing green/blue environment variables
    db_name                  = var.n8n_db_name
    db_user                  = var.postgres_username # Reuse existing username
    db_password              = var.postgres_password # Reuse existing password
    storage_size             = var.n8n_storage_size
    replicas                 = var.n8n_replicas
    hpa_min_replicas         = var.n8n_hpa_min_replicas
    hpa_max_replicas         = var.n8n_hpa_max_replicas
    resource_requests_cpu    = "50m"
    resource_requests_memory = "256Mi"
    resource_limits_cpu      = "500m"
    resource_limits_memory   = "512Mi"
    timezone                 = var.GENERIC_TIMEZONE
    redis_password           = var.redis_password
  }
}

resource "kubernetes_namespace" "n8n" {
  metadata {
    name = var.n8n_namespace
  }
  depends_on = [null_resource.wait_for_cluster]

  timeouts {
    delete = "20m" # n8n often has many resources and PVCs
  }
}

resource "kubectl_manifest" "n8n" {
  for_each  = data.kubectl_path_documents.n8n_manifests.manifests
  yaml_body = each.value

  # Enable server-side apply to fix "context deadline exceeded" and patch errors
  server_side_apply = true
  wait              = false # Disable wait for general resources
  wait_for_rollout  = false # Specifically disable rollout wait for deployments
  validate_schema   = false # Disable schema validation for CRDs (Traefik Middleware)

  depends_on = [kubernetes_namespace.n8n] # Ensure namespace exists before applying manifests
}
