# Terraform configuration to deploy n8n using the YAML manifest

data "kubectl_path_documents" "n8n_manifests" {
  pattern = "${path.module}/n8n-optimized.yaml"
  vars = {
    namespace          = var.n8n_namespace
    n8n_hostname       = var.n8n_hostname
    n8n_encryption_key = var.n8n_encryption_key
    n8n_image_tag      = var.n8n_image_tag
    # Note: DB host/user/pass now point to existing green/blue environment variables
    db_name                 = var.n8n_db_name
    db_user                 = var.postgres_username # Reuse existing username
    db_password             = var.postgres_password # Reuse existing password
    storage_size            = var.n8n_storage_size
    replicas                = var.n8n_replicas
    hpa_min_replicas        = var.n8n_hpa_min_replicas
    hpa_max_replicas        = var.n8n_hpa_max_replicas
    main_requests_cpu       = var.n8n_main_requests_cpu
    main_requests_memory    = var.n8n_main_requests_memory
    main_limits_cpu         = var.n8n_main_limits_cpu
    main_limits_memory      = var.n8n_main_limits_memory
    worker_requests_cpu     = var.n8n_worker_requests_cpu
    worker_requests_memory  = var.n8n_worker_requests_memory
    worker_limits_cpu       = var.n8n_worker_limits_cpu
    worker_limits_memory    = var.n8n_worker_limits_memory
    webhook_requests_cpu    = var.n8n_webhook_requests_cpu
    webhook_requests_memory = var.n8n_webhook_requests_memory
    webhook_limits_cpu      = var.n8n_webhook_limits_cpu
    webhook_limits_memory   = var.n8n_webhook_limits_memory
    timezone                = var.GENERIC_TIMEZONE
    redis_password          = var.redis_password
  }
}

resource "null_resource" "label_n8n_nodes" {
  count = var.worker_n8n_count

  depends_on = [
    null_resource.wait_for_cluster,
    module.n8n_worker
  ]

  provisioner "local-exec" {
    command = "KUBECONFIG=./kubeconfig kubectl label node ${var.worker_n8n_hostname}-${count.index + 1} workload=n8n --overwrite"
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

  depends_on = [
    kubernetes_namespace.n8n,
    null_resource.label_n8n_nodes
  ] # Ensure namespace and node labels exist before applying manifests
}
