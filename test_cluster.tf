/* 
# Resource untuk menginstall Metrics Server via Helm (K3s sudah punya default)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  # Konfigurasi agar metrics-server bisa jalan di K3s (allow insecure TLS untuk self-signed certs)
  set {
    name  = "args"
    value = "{--kubelet-insecure-tls}"
  }

  depends_on = [null_resource.wait_for_cluster]
}
*/

# Test Deployment sederhana untuk verifikasi
resource "kubernetes_deployment" "test_app" {
  wait_for_rollout = false
  metadata {
    name = "test-connectivity"
    labels = {
      app = "test-connectivity"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "test-connectivity"
      }
    }

    template {
      metadata {
        labels = {
          app = "test-connectivity"
        }
      }

      spec {
        container {
          image = "nginx:alpine"
          name  = "nginx"

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.wait_for_cluster]
}
