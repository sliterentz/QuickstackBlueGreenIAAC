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
    null_resource.wait_for_cluster
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      LOG_FILE="${path.module}/logs/.label_n8n_nodes.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1

      NODE_NAME="${var.worker_n8n_hostname}-${count.index + 1}"
      KUBECONFIG_PATH="${path.module}/kubeconfig"

      echo "=== Labeling n8n node ==="
      echo "Timestamp: $(date)"
      echo "Node: $NODE_NAME"
      echo "KUBECONFIG: $KUBECONFIG_PATH"
      echo ""

      MAX_WAIT_SECONDS=900
      INTERVAL_SECONDS=10
      ELAPSED=0

      while [ $ELAPSED -lt $MAX_WAIT_SECONDS ]; do
        if KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
          echo "✓ Node object exists: $NODE_NAME"
          break
        fi

        if [ $((ELAPSED % 60)) -eq 0 ]; then
          echo "Waiting for node registration... ($ELAPSED/$MAX_WAIT_SECONDS seconds)"
          KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes -o wide 2>/dev/null || true
        fi

        sleep $INTERVAL_SECONDS
        ELAPSED=$((ELAPSED + INTERVAL_SECONDS))
      done

      if ! KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
        echo "✗ ERROR: Node not registered after $MAX_WAIT_SECONDS seconds: $NODE_NAME"
        echo ""
        echo "Current nodes:"
        KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes -o wide || true
        exit 1
      fi

      echo "Waiting for node to become Ready..."
      KUBECONFIG="$KUBECONFIG_PATH" kubectl wait --for=condition=Ready "node/$NODE_NAME" --timeout=600s || true

      echo "Applying label workload=n8n to $NODE_NAME..."
      KUBECONFIG="$KUBECONFIG_PATH" kubectl label node "$NODE_NAME" workload=n8n --overwrite

      echo "✓ Label applied"
    EOT
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

resource "null_resource" "wait_for_traefik_crds" {
  depends_on = [null_resource.wait_for_cluster]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      KUBECONFIG_PATH="${path.module}/kubeconfig"
      MAX_WAIT_SECONDS=600
      INTERVAL_SECONDS=10
      ELAPSED=0

      echo "=== Waiting for Traefik CRDs ==="
      echo "Timestamp: $(date)"
      echo "KUBECONFIG: $KUBECONFIG_PATH"
      echo ""

      while [ $ELAPSED -lt $MAX_WAIT_SECONDS ]; do
        if KUBECONFIG="$KUBECONFIG_PATH" kubectl get crd middlewares.traefik.io >/dev/null 2>&1; then
          echo "✓ CRD found: middlewares.traefik.io"
          exit 0
        fi

        if [ $((ELAPSED % 60)) -eq 0 ]; then
          echo "Waiting for Traefik CRDs... ($ELAPSED/$MAX_WAIT_SECONDS seconds)"
          KUBECONFIG="$KUBECONFIG_PATH" kubectl get pods -n kube-system -o wide 2>/dev/null | grep -E 'traefik|helm-install-traefik' || true
        fi

        sleep $INTERVAL_SECONDS
        ELAPSED=$((ELAPSED + INTERVAL_SECONDS))
      done

      echo "✗ ERROR: Traefik CRD middlewares.traefik.io not found after $MAX_WAIT_SECONDS seconds"
      echo ""
      KUBECONFIG="$KUBECONFIG_PATH" kubectl get crd | grep -i traefik || true
      KUBECONFIG="$KUBECONFIG_PATH" kubectl get pods -n kube-system -o wide || true
      exit 1
    EOT
  }
}

resource "null_resource" "unlabel_master_n8n" {
  depends_on = [
    null_resource.wait_for_cluster
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      LOG_FILE="${path.module}/logs/.unlabel_master_n8n.log"
      mkdir -p "$(dirname "$LOG_FILE")"
      exec > >(tee -a "$LOG_FILE") 2>&1

      NODE_NAME="${var.vm_hostname}"
      KUBECONFIG_PATH="${path.module}/kubeconfig"

      echo "=== Ensuring master is not labeled for n8n workload ==="
      echo "Timestamp: $(date)"
      echo "Node: $NODE_NAME"
      echo "KUBECONFIG: $KUBECONFIG_PATH"
      echo ""

      if ! KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
        echo "Node not found (skipping): $NODE_NAME"
        exit 0
      fi

      label_value="$(KUBECONFIG="$KUBECONFIG_PATH" kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.workload}' 2>/dev/null || true)"
      if [ "$label_value" = "n8n" ]; then
        echo "Removing label workload=n8n from master node: $NODE_NAME"
        KUBECONFIG="$KUBECONFIG_PATH" kubectl label node "$NODE_NAME" workload- --overwrite
        echo "✓ Label removed"
      else
        echo "Master node has no workload=n8n label (ok)"
      fi
    EOT
  }
}

resource "kubectl_manifest" "n8n" {
  for_each  = data.kubectl_path_documents.n8n_manifests.manifests
  yaml_body = each.value

  # Enable server-side apply to fix "context deadline exceeded" and patch errors
  server_side_apply = true
  force_conflicts   = true
  wait              = false # Disable wait for general resources
  wait_for_rollout  = false # Specifically disable rollout wait for deployments
  validate_schema   = false # Disable schema validation for CRDs (Traefik Middleware)

  depends_on = [
    kubernetes_namespace.n8n,
    null_resource.label_n8n_nodes,
    null_resource.wait_for_traefik_crds,
    null_resource.unlabel_master_n8n
  ] # Ensure namespace and node labels exist before applying manifests
}
