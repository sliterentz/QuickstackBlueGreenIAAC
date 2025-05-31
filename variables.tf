# Variables for the Terraform configuration

variable "kube_config_path" {
  description = "Path to the kubeconfig file"
  type        = string
}

variable "server_ips" {
  description = "List of server IPs for K3S cluster"
  type        = list(string)
}

variable "k3s_default_namespace" {
  description = "Name of the K3S default namespace"
  type        = string
  sensitive   = true
}

variable "ssh_username" {
  description = "SSH username for server access"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key"
  type        = string
}

variable "argocd_version" {
  description = "Version of ArgoCD to install"
  type        = string
  default     = "5.34.6"
}

variable "argocd_hostname" {
  description = "Hostname for ArgoCD"
  type        = string
}

variable "argocd_admin_password" {
  description = "Admin password for ArgoCD"
  type        = string
  sensitive   = true
}

variable "argocd_tls_secret_name" {
  description = "Name of the TLS secret for ArgoCD ingress"
  type        = string
}

variable "postgres_database" {
  description = "PostgreSQL database name"
  type        = string
}

variable "postgres_username" {
  description = "PostgreSQL username"
  type        = string
  sensitive   = true
}

variable "postgres_root_password" {
  description = "PostgreSQL root password"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "mariadb_database" {
  description = "Mariadb database name"
  type        = string
}

variable "mariadb_username" {
  description = "Mariadb username"
  type        = string
  sensitive   = true
}

variable "mariadb_root_password" {
  description = "Mariadb root password"
  type        = string
  sensitive   = true
}

variable "mariadb_password" {
  description = "Mariadb password"
  type        = string
  sensitive   = true
}


variable "mongo_username" {
  description = "MongoDB Admin username"
  type        = string
  sensitive   = true
}

variable "mongo_password" {
  description = "MongoDB root password"
  type        = string
  sensitive   = true
}

variable "redis_password" {
  description = "Redis password"
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Environment (dev or prod)"
  type        = string
  default     = "prod"
}