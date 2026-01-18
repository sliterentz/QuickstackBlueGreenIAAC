
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: argocd-server
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: argocd
    app.kubernetes.io/component: server
    app.kubernetes.io/managed-by: terraform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: argocd-server
  minReplicas: ${min_replicas}
  maxReplicas: ${max_replicas}
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: ${cpu_threshold}
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: ${memory_threshold}
  behavior: