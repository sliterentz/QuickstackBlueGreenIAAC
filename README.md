# QuickStack K3s Kubernetes Cluster with Terraform

This repository contains Terraform configurations to quickly deploy a K3s Kubernetes cluster with essential components including ArgoCD and various database services (PostgreSQL, MariaDB, MongoDB, and Redis).

## Prerequisites

- quickstack installed (root access)
- Terraform v1.0.0 or newer
- SSH access to a target server
- SSH key pair
- Domain name (for ArgoCD access)
- Basic understanding of Kubernetes and Terraform

## Components Deployed

- K3s lightweight Kubernetes cluster
- ArgoCD for GitOps-based deployments
- Blue/Green deployment namespaces
- Database services:
  - PostgreSQL
  - MariaDB
  - MongoDB
  - Redis

## Quick Start

### 1. Prepare Your Environment

Ensure you have a server with SSH access where you want to deploy K3s. This server should have:
- At least 2 CPU cores
- 4GB RAM minimum (8GB recommended)
- 20GB available disk space
- Public IP address
- SSH access with key-based authentication

### 2. Clone the Repository

```bash
git clone https://github.com/yourusername/myterra.git
cd myterra
```

### 3. Configure Variables
```bash
cp example.tfvars terraform.tfvars
```

Edit terraform.tfvars with your specific configuration:
```
server_ips            = ["YOUR_SERVER_IP"]  # Public IP of your server
ssh_username          = "YOUR_USERNAME"     # SSH username
ssh_private_key_path  = "~/.ssh/id_rsa"     # Path to your SSH private key
k3s_default_namespace = "kube-system"       # Default namespace
argocd_hostname       = "argocd.yourdomain.com"  # ArgoCD hostname
argocd_admin_password = "YOUR_SECURE_PASSWORD"   # ArgoCD admin password
argocd_tls_secret_name = "argocd-tls"       # TLS secret name
# Database configurations
postgres_database = "app_db"
postgres_root_password = "secure_postgres_root_password"
postgres_username = "app_user"
postgres_password = "secure_postgres_password"
mariadb_database = "app_db"
mariadb_username = "app_user"
mariadb_password = "secure_mariadb_password"
mariadb_root_password = "secure_mariadb_root_password"
mongo_username = "admin"
mongo_password = "secure_mongo_password"
redis_password = "secure_redis_password"
```

### 4. Initialize Terraform
```bash
terraform init
```

### 5. Validate the Terraform Files
```bash
terraform validate
```

### 6. Deploy the Infrastructure
```bash
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### 7. Access Your Cluster (Root Access)
```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get namespaces -A
sudo k3s kubectl get pods -A
```

### 6. Access ArgoCD
ArgoCD will be available at the hostname you specified in the variables:
```
https://argocd.yourdomain.com
```
Login with:
Username: admin
Password: The value you set for argocd_admin_password

#### Blue/Green Deployment
This setup includes blue/green deployment namespaces for zero-downtime deployments:
<namespace>-blue: Blue environment
<namespace>-green: Green environment
You can deploy your applications to these namespaces and switch between them using ArgoCD.

#### Database Services
The following database services are deployed and can be used by your applications:
PostgreSQL
Port: 5432
Database: Value of postgres_database
Username: Value of postgres_username
Password: Value of postgres_password
MariaDB
Port: 3306
Database: Value of mariadb_database
Username: Value of mariadb_username
Password: Value of mariadb_password
MongoDB
Port: 27017
Username: Value of mongo_username
Password: Value of mongo_password
Redis
Port: 6379
Password: Value of redis_password

### Cleanup
To destroy the infrastructure when no longer needed:
```bash
terraform destroy -var-file=terraform.tfvars
```

### Troubleshooting
Common Issues
1. SSH Connection Failures:
Verify your SSH key path and permissions
Ensure the server is reachable and SSH service is running
2. Kubernetes API Unreachable:
Check if K3s is properly installed and running
Verify the kubeconfig file has the correct server IP
3. ArgoCD Not Accessible:
Ensure DNS is properly configured for your ArgoCD hostname
Check if the Ingress controller is properly configured

### Logs and Debugging
To check K3s logs on the server:
```bash
ssh <username>@<server_ip> "sudo journalctl -u k3s"
```
To check pod status:
```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Security Considerations
Change all default passwords in the terraform.tfvars file
Consider using Terraform's encrypted state storage
Restrict access to your kubeconfig file
Use proper network security groups to limit access to your server