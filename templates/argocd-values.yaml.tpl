
server:
  replicas: ${server_replicas}
  resources:
    requests:
      cpu: "${server_cpu_request}"
      memory: "${server_memory_request}"
    limits:
      cpu: "${server_cpu_limit}"
      memory: "${server_memory_limit}"
  extraArgs:
    %{ if insecure_mode }- --insecure%{ endif }
  ingress:
    enabled: false
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

repoServer:
  replicas: ${repo_server_replicas}
  resources:
    requests:
      cpu: "${repo_cpu_request}"
      memory: "${repo_memory_request}"
    limits:
      cpu: "${repo_cpu_limit}"
      memory: "${repo_memory_limit}"
  env:
    - name: ARGOCD_EXEC_TIMEOUT
      value: "${exec_timeout}"
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

redis:
  resources:
    requests:
      cpu: "${redis_cpu_request}"
      memory: "${redis_memory_request}"
    limits:
      cpu: "${redis_cpu_limit}"
      memory: "${redis_memory_limit}"
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

controller:
  resources:
    requests:
      cpu: "${controller_cpu_request}"
      memory: "${controller_memory_request}"
    limits:
      cpu: "${controller_cpu_limit}"
      memory: "${controller_memory_limit}"
  args:
    statusProcessors: "${status_processors}"
    operationProcessors: "${operation_processors}"
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

configs:
  secret:
    argocdServerAdminPassword: ${admin_password}
  cm:
    timeout.reconciliation: "${timeout_reconciliation}"
    timeout.hard.reconciliation: "0s"
    resource.customizations.ignoreDifferences.all: |
      jsonPointers:
      - /status
    resource.customizations.health.argoproj.io_Application: |
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs

applicationSet:
  enabled: true
  replicas: 1

notifications:
  enabled: true
  argocdUrl: https://${argocd_hostname}

dex:
  enabled: false