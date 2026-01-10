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

### 1. Prepare Host Environment

Pastikan host machine Anda (Ubuntu/Debian) sudah terkonfigurasi untuk menjalankan KVM. Gunakan script yang tersedia di modul `terraform-kvm-ubuntu`:

```bash
cd terraform-kvm-ubuntu
chmod +x setup_kvm.sh
./setup_kvm.sh
```

### 2. Configure Variables

Edit `terraform.tfvars`. Perhatikan bahwa sekarang Anda tidak perlu memasukkan `server_ips` secara manual karena VM akan dibuat secara otomatis di KVM lokal.

```bash
cp example.tfvars terraform.tfvars
```

### 3. Deploy Infrastructure

```bash
terraform init
terraform apply -auto-approve
```

Terraform akan:
1. Membuat VM di KVM (Ubuntu 22.04, 2 CPU, 4GB RAM, 20GB Disk).
2. Menginstall K3s secara otomatis di dalam VM via Cloud-Init.
3. Mengambil file `kubeconfig` dari VM ke host local secara otomatis.
4. Menginstall Metrics Server dan komponen Kubernetes lainnya.

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