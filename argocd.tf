# ArgoCD installation

resource "kubernetes_namespace" "argocd" {
  count      = var.deploy_argocd ? 1 : 0
  depends_on = [null_resource.wait_for_cluster]

  metadata {
    name = var.argocd_namespace

    labels = merge(
      {
        "name"       = var.argocd_namespace
        "managed-by" = "terraform"
      },
      var.argocd_additional_labels
    )

    annotations = var.argocd_additional_annotations
  }

  timeouts {
    delete = "15m"
  }
}

resource "helm_release" "argocd" {
  count      = var.deploy_argocd ? 1 : 0
  depends_on = [kubernetes_namespace.argocd]

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd[0].metadata[0].name
  version    = var.argocd_version
  timeout    = 1800 # 30 menit
  wait       = true

  values = [templatefile("${path.module}/templates/argocd-values.yaml.tpl", {
    server_replicas           = var.argocd_server_replicas
    repo_server_replicas      = var.argocd_repo_server_replicas
    server_cpu_request        = var.argocd_server_resources.requests.cpu
    server_memory_request     = var.argocd_server_resources.requests.memory
    server_cpu_limit          = var.argocd_server_resources.limits.cpu
    server_memory_limit       = var.argocd_server_resources.limits.memory
    repo_cpu_request          = var.argocd_repo_server_resources.requests.cpu
    repo_memory_request       = var.argocd_repo_server_resources.requests.memory
    repo_cpu_limit            = var.argocd_repo_server_resources.limits.cpu
    repo_memory_limit         = var.argocd_repo_server_resources.limits.memory
    redis_cpu_request         = var.argocd_redis_resources.requests.cpu
    redis_memory_request      = var.argocd_redis_resources.requests.memory
    redis_cpu_limit           = var.argocd_redis_resources.limits.cpu
    redis_memory_limit        = var.argocd_redis_resources.limits.memory
    controller_cpu_request    = var.argocd_controller_resources.requests.cpu
    controller_memory_request = var.argocd_controller_resources.requests.memory
    controller_cpu_limit      = var.argocd_controller_resources.limits.cpu
    controller_memory_limit   = var.argocd_controller_resources.limits.memory
    admin_password            = bcrypt(var.argocd_admin_password)
    timeout_reconciliation    = var.argocd_timeout_reconciliation
    exec_timeout              = var.argocd_exec_timeout
    status_processors         = var.argocd_status_processors
    operation_processors      = var.argocd_operation_processors
    insecure_mode             = var.argocd_insecure_mode
    argocd_hostname           = var.argocd_hostname
  })]
}

# HPA for ArgoCD Server
resource "kubectl_manifest" "argocd_server_hpa" {
  count      = var.deploy_argocd && var.argocd_enable_hpa ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = templatefile("${path.module}/templates/argocd-server-hpa.yaml.tpl", {
    namespace        = var.argocd_namespace
    min_replicas     = var.argocd_hpa_min_replicas
    max_replicas     = var.argocd_hpa_max_replicas
    cpu_threshold    = var.argocd_hpa_cpu_threshold
    memory_threshold = var.argocd_hpa_memory_threshold
  })
}

# HPA for ArgoCD Repo Server
resource "kubectl_manifest" "argocd_repo_server_hpa" {
  count      = var.deploy_argocd && var.argocd_enable_hpa ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = templatefile("${path.module}/templates/argocd-repo-server-hpa.yaml.tpl", {
    namespace        = var.argocd_namespace
    min_replicas     = var.argocd_hpa_min_replicas
    max_replicas     = var.argocd_hpa_max_replicas
    cpu_threshold    = var.argocd_hpa_cpu_threshold
    memory_threshold = var.argocd_hpa_memory_threshold
  })
}

# Create self-signed TLS certificate for ArgoCD
resource "tls_private_key" "argocd_key" {
  count     = var.deploy_argocd && var.argocd_enable_tls ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "argocd_cert" {
  count           = var.deploy_argocd && var.argocd_enable_tls ? 1 : 0
  private_key_pem = tls_private_key.argocd_key[0].private_key_pem

  subject {
    common_name  = var.argocd_hostname
    organization = "ArgoCD Local"
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    var.argocd_hostname,
    "*.${var.argocd_hostname}"
  ]
}

resource "kubernetes_secret" "argocd_tls" {
  count      = var.deploy_argocd && var.argocd_enable_tls ? 1 : 0
  depends_on = [kubernetes_namespace.argocd]

  metadata {
    name      = var.argocd_tls_secret_name
    namespace = var.argocd_namespace

    labels = merge(
      {
        "app.kubernetes.io/name"       = "argocd"
        "app.kubernetes.io/component"  = "server"
        "app.kubernetes.io/managed-by" = "terraform"
      },
      var.argocd_additional_labels
    )
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.argocd_cert[0].cert_pem
    "tls.key" = tls_private_key.argocd_key[0].private_key_pem
  }
}

# Create ArgoCD ingress with Traefik
resource "kubernetes_ingress_v1" "argocd_ingress" {
  count      = var.deploy_argocd && var.argocd_enable_ingress ? 1 : 0
  depends_on = [helm_release.argocd, kubernetes_secret.argocd_tls]

  metadata {
    name      = "argocd-server-ingress"
    namespace = var.argocd_namespace

    annotations = merge(
      {
        "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
        "traefik.ingress.kubernetes.io/router.tls"         = var.argocd_enable_tls ? "true" : "false"
      },
      var.argocd_additional_annotations
    )

    labels = merge(
      {
        "app.kubernetes.io/name"       = "argocd"
        "app.kubernetes.io/component"  = "server"
        "app.kubernetes.io/managed-by" = "terraform"
      },
      var.argocd_additional_labels
    )
  }

  spec {
    ingress_class_name = var.argocd_ingress_class

    rule {
      host = var.argocd_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    dynamic "tls" {
      for_each = var.argocd_enable_tls ? [1] : []
      content {
        hosts       = [var.argocd_hostname]
        secret_name = var.argocd_tls_secret_name
      }
    }
  }
}

# Optional: Create middleware for path handling if needed
resource "kubectl_manifest" "argocd_middleware" {
  count      = var.deploy_argocd ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: argocd-strip-prefix
  namespace: ${var.argocd_namespace}
  labels:
    app.kubernetes.io/name: argocd
    app.kubernetes.io/component: middleware
    app.kubernetes.io/managed-by: terraform
spec:
  stripPrefix:
    prefixes:
      - /argocd
YAML
}

# Create ServiceMonitor for Prometheus (if monitoring is enabled)
resource "kubectl_manifest" "argocd_servicemonitor" {
  count      = var.deploy_argocd ? 1 : 0
  depends_on = [helm_release.argocd]

  yaml_body = <<YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: ${var.argocd_namespace}
  labels:
    app.kubernetes.io/name: argocd
    app.kubernetes.io/component: metrics
    app.kubernetes.io/managed-by: terraform
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
YAML
}

# Output ArgoCD information
output "argocd_info" {
  description = "ArgoCD deployment information"
  value = var.deploy_argocd ? {
    deployed        = true
    namespace       = var.argocd_namespace
    version         = var.argocd_version
    hostname        = var.argocd_hostname
    ingress_enabled = var.argocd_enable_ingress
    tls_enabled     = var.argocd_enable_tls
    hpa_enabled     = var.argocd_enable_hpa
    server_replicas = var.argocd_server_replicas
    repo_replicas   = var.argocd_repo_server_replicas
    admin_username  = "admin"
    access_url      = var.argocd_enable_ingress ? "https://${var.argocd_hostname}" : "Use port-forward: kubectl port-forward svc/argocd-server -n ${var.argocd_namespace} 8080:443"
    } : {
    deployed = false
    message  = "ArgoCD deployment is disabled. Set deploy_argocd = true to enable."
  }

  sensitive = false
}

output "argocd_admin_password" {
  description = "ArgoCD admin password (sensitive)"
  value       = var.deploy_argocd ? var.argocd_admin_password : null
  sensitive   = true
}

output "argocd_server_endpoint" {
  description = "ArgoCD server endpoint"
  value       = var.deploy_argocd && var.argocd_enable_ingress ? "https://${var.argocd_hostname}" : null
}