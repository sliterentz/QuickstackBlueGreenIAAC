
# ============================================================================
# ArgoCD Deployment Control Variables
# ============================================================================

variable "deploy_argocd" {
  description = "Enable or disable ArgoCD deployment"
  type        = bool
  default     = false

  validation {
    condition     = can(tobool(var.deploy_argocd))
    error_message = "deploy_argocd must be a boolean value (true or false)."
  }
}

variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.3.4"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.argocd_version))
    error_message = "argocd_version must be in semantic versioning format (e.g., 7.3.4)."
  }
}

variable "argocd_namespace" {
  description = "Kubernetes namespace for ArgoCD"
  type        = string
  default     = "argocd"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.argocd_namespace))
    error_message = "argocd_namespace must be a valid Kubernetes namespace name."
  }
}

variable "argocd_hostname" {
  description = "Hostname for ArgoCD ingress"
  type        = string
  default     = "argocd.local"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", var.argocd_hostname))
    error_message = "argocd_hostname must be a valid hostname."
  }
}

variable "argocd_admin_password" {
  description = "Admin password for ArgoCD (will be bcrypt hashed)"
  type        = string
  sensitive   = true
  default     = "admin123"

  validation {
    condition     = length(var.argocd_admin_password) >= 8
    error_message = "argocd_admin_password must be at least 8 characters long."
  }
}

variable "argocd_tls_secret_name" {
  description = "Name of the TLS secret for ArgoCD ingress"
  type        = string
  default     = "argocd-server-tls"
}

variable "argocd_server_replicas" {
  description = "Number of ArgoCD server replicas"
  type        = number
  default     = 1

  validation {
    condition     = var.argocd_server_replicas >= 1 && var.argocd_server_replicas <= 10
    error_message = "argocd_server_replicas must be between 1 and 10."
  }
}

variable "argocd_repo_server_replicas" {
  description = "Number of ArgoCD repo server replicas"
  type        = number
  default     = 1

  validation {
    condition     = var.argocd_repo_server_replicas >= 1 && var.argocd_repo_server_replicas <= 10
    error_message = "argocd_repo_server_replicas must be between 1 and 10."
  }
}

variable "argocd_server_resources" {
  description = "Resource limits and requests for ArgoCD server"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })

  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }

  validation {
    condition = (
      can(regex("^[0-9]+(m|[0-9]*\\.?[0-9]+)$", var.argocd_server_resources.requests.cpu)) &&
      can(regex("^[0-9]+(Mi|Gi|M|G)$", var.argocd_server_resources.requests.memory)) &&
      can(regex("^[0-9]+(m|[0-9]*\\.?[0-9]+)$", var.argocd_server_resources.limits.cpu)) &&
      can(regex("^[0-9]+(Mi|Gi|M|G)$", var.argocd_server_resources.limits.memory))
    )
    error_message = "Resource values must be in valid Kubernetes format (e.g., 100m, 512Mi)."
  }
}

variable "argocd_repo_server_resources" {
  description = "Resource limits and requests for ArgoCD repo server"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })

  default = {
    requests = {
      cpu    = "100m"
      memory = "256Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "1024Mi"
    }
  }
}

variable "argocd_redis_resources" {
  description = "Resource limits and requests for ArgoCD Redis"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })

  default = {
    requests = {
      cpu    = "50m"
      memory = "64Mi"
    }
    limits = {
      cpu    = "200m"
      memory = "128Mi"
    }
  }
}

variable "argocd_controller_resources" {
  description = "Resource limits and requests for ArgoCD controller"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })

  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}

variable "argocd_enable_ingress" {
  description = "Enable ingress for ArgoCD"
  type        = bool
  default     = true
}

variable "argocd_enable_tls" {
  description = "Enable TLS for ArgoCD ingress"
  type        = bool
  default     = true
}

variable "argocd_ingress_class" {
  description = "Ingress class name for ArgoCD"
  type        = string
  default     = "traefik"

  validation {
    condition     = contains(["traefik", "nginx", "haproxy"], var.argocd_ingress_class)
    error_message = "argocd_ingress_class must be one of: traefik, nginx, haproxy."
  }
}

variable "argocd_enable_hpa" {
  description = "Enable Horizontal Pod Autoscaler for ArgoCD components"
  type        = bool
  default     = true
}

variable "argocd_hpa_min_replicas" {
  description = "Minimum replicas for HPA"
  type        = number
  default     = 1

  validation {
    condition     = var.argocd_hpa_min_replicas >= 1 && var.argocd_hpa_min_replicas <= 10
    error_message = "argocd_hpa_min_replicas must be between 1 and 10."
  }
}

variable "argocd_hpa_max_replicas" {
  description = "Maximum replicas for HPA"
  type        = number
  default     = 3

  validation {
    condition     = var.argocd_hpa_max_replicas >= 1 && var.argocd_hpa_max_replicas <= 20
    error_message = "argocd_hpa_max_replicas must be between 1 and 20."
  }
}

variable "argocd_hpa_cpu_threshold" {
  description = "CPU utilization threshold for HPA (percentage)"
  type        = number
  default     = 70

  validation {
    condition     = var.argocd_hpa_cpu_threshold >= 10 && var.argocd_hpa_cpu_threshold <= 100
    error_message = "argocd_hpa_cpu_threshold must be between 10 and 100."
  }
}

variable "argocd_hpa_memory_threshold" {
  description = "Memory utilization threshold for HPA (percentage)"
  type        = number
  default     = 80

  validation {
    condition     = var.argocd_hpa_memory_threshold >= 10 && var.argocd_hpa_memory_threshold <= 100
    error_message = "argocd_hpa_memory_threshold must be between 10 and 100."
  }
}

variable "argocd_timeout_reconciliation" {
  description = "Timeout for reconciliation operations"
  type        = string
  default     = "180s"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.argocd_timeout_reconciliation))
    error_message = "argocd_timeout_reconciliation must be in duration format (e.g., 180s, 3m, 1h)."
  }
}

variable "argocd_exec_timeout" {
  description = "Timeout for exec operations"
  type        = string
  default     = "180s"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.argocd_exec_timeout))
    error_message = "argocd_exec_timeout must be in duration format (e.g., 180s, 3m, 1h)."
  }
}

variable "argocd_status_processors" {
  description = "Number of status processors for ArgoCD controller"
  type        = number
  default     = 20

  validation {
    condition     = var.argocd_status_processors >= 1 && var.argocd_status_processors <= 100
    error_message = "argocd_status_processors must be between 1 and 100."
  }
}

variable "argocd_operation_processors" {
  description = "Number of operation processors for ArgoCD controller"
  type        = number
  default     = 10

  validation {
    condition     = var.argocd_operation_processors >= 1 && var.argocd_operation_processors <= 50
    error_message = "argocd_operation_processors must be between 1 and 50."
  }
}

variable "argocd_insecure_mode" {
  description = "Run ArgoCD server in insecure mode (disable TLS)"
  type        = bool
  default     = true
}

variable "argocd_additional_labels" {
  description = "Additional labels to apply to ArgoCD resources"
  type        = map(string)
  default     = {}
}

variable "argocd_additional_annotations" {
  description = "Additional annotations to apply to ArgoCD resources"
  type        = map(string)
  default     = {}
}