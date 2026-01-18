
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: argocd-repo-server
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: argocd
    app.kubernetes.io/component: repo-server
    app.kubernetes.io/managed-by: terraform
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: argocd-repo-server
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
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
      - type: Pods
        value: 1
        periodSeconds: 60
      selectPolicy: Min
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max