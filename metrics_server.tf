resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  wait            = false
  atomic          = false
  cleanup_on_fail = false
  timeout         = 600

  depends_on = [
    null_resource.wait_for_cluster
  ]

  values = [
    <<-YAML
    args:
      - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
      - --kubelet-insecure-tls
    livenessProbe:
      initialDelaySeconds: 60
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 6
    readinessProbe:
      initialDelaySeconds: 60
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 12
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
    YAML
  ]
}
