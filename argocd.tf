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
  chart      = "kube-system"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = var.argocd_version
  
  values = [<<EOF
server:
  extraArgs:
    - --insecure
  ingress:
    enabled: true
    ingressClassName: "traefik"
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/router.tls: "true"
    hosts:
      - ${var.argocd_hostname}
    tls:
      - secretName: ${var.argocd_tls_secret_name}
        hosts:
          - ${var.argocd_hostname}
configs:
  secret:
    argocdServerAdminPassword: ${bcrypt(var.argocd_admin_password)}
EOF
  ]
}

# Create ArgoCD ingress with Traefik
resource "kubernetes_ingress_v1" "argocd_ingress" {
  depends_on = [helm_release.argocd]
  
  metadata {
    name      = "argocd-server-ingress"
    namespace = "kube-system"
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
      "traefik.ingress.kubernetes.io/router.middlewares" = "argocd-strip-prefix@kubernetescrd"
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
                name = "https"
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
resource "kubernetes_manifest" "argocd_middleware" {
  depends_on = [helm_release.argocd]

  manifest = {
    apiVersion = "traefik.containo.us/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "argocd-strip-prefix"
      namespace = "kube-system"
    }
    spec = {
      stripPrefix = {
        prefixes = ["/argocd"]
      }
    }
  }
}