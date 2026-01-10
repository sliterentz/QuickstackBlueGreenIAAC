# ArgoCD installation

resource "kubernetes_namespace" "argocd" {
  depends_on = [null_resource.wait_for_cluster]
  
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = var.argocd_version
  timeout    = 1200 # Naikkan timeout jadi 20 menit
  
  values = [<<EOF
server:
  extraArgs:
    - --insecure
  ingress:
    enabled: false
configs:
  secret:
    argocdServerAdminPassword: ${bcrypt(var.argocd_admin_password)}
EOF
  ]
}

# Create self-signed TLS certificate for ArgoCD
resource "tls_private_key" "argocd_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "argocd_cert" {
  private_key_pem = tls_private_key.argocd_key.private_key_pem

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
}

resource "kubernetes_secret" "argocd_tls" {
  metadata {
    name      = var.argocd_tls_secret_name
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.argocd_cert.cert_pem
    "tls.key" = tls_private_key.argocd_key.private_key_pem
  }
}

# Create ArgoCD ingress with Traefik
resource "kubernetes_ingress_v1" "argocd_ingress" {
  depends_on = [helm_release.argocd, kubernetes_secret.argocd_tls]
  
  metadata {
    name      = "argocd-server-ingress"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
  }
  
  spec {
    ingress_class_name = "traefik"
    
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
    
    tls {
      hosts       = [var.argocd_hostname]
      secret_name = var.argocd_tls_secret_name
    }
  }
}

# Optional: Create middleware for path handling if needed
resource "kubectl_manifest" "argocd_middleware" {
  depends_on = [helm_release.argocd]

  yaml_body = <<YAML
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: argocd-strip-prefix
  namespace: kube-system
spec:
  stripPrefix:
    prefixes:
      - /argocd
YAML
}