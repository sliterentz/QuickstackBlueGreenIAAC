# Terraform KVM Provider Integration for Ubuntu LTS

Proyek ini menyediakan solusi Infrastructure as Code (IaC) lengkap untuk men-deploy Virtual Machine (VM) berbasis Ubuntu LTS terbaru di atas hypervisor KVM menggunakan Terraform.

Solusi ini dirancang untuk kompatibilitas tinggi, kemudahan penggunaan, dan siap diintegrasikan ke dalam pipeline CI/CD.

## 📋 Fitur Utama

- **Otomatisasi Penuh**: Script setup untuk menyiapkan host environment.
- **Ubuntu LTS Terbaru**: Menggunakan Ubuntu 24.04 LTS (Noble Numbat) via Cloud Images.
- **Production-Ready K8s Prep**:
    - Optimasi kernel (overlay, br_netfilter, sysctl tuning).
    - Pre-installed Containerd (CRI), Kubeadm, Kubelet, dan Kubectl.
    - Otomatis menonaktifkan Swap (persyaratan K8s).
- **Hardening Keamanan**:
    - Implementasi dasar CIS Benchmark.
    - Konfigurasi SSH yang aman.
    - Firewall (UFW) yang sudah terkonfigurasi untuk traffic Kubernetes.
- **Monitoring Terintegrasi**: Pre-installed Prometheus Node Exporter (port 9100).
- **Cloud-Init Integration**: Konfigurasi otomatis user, SSH keys, dan paket saat boot.
- **Networking**: DHCP lease management otomatis via Libvirt.
- **Modular**: Parameter CPU, RAM, dan Disk dapat dikonfigurasi via variabel.

## 🛠 Prasyarat Sistem

Sebelum memulai, pastikan sistem host Anda memenuhi kriteria berikut:
- **OS**: Ubuntu 20.04/22.04/24.04 atau Debian 11/12 (Bare Metal atau VM dengan Nested Virtualization enabled).
- **CPU**: Support Virtualization (Intel VT-x atau AMD-V).
- **RAM**: Minimal 4GB free.
- **Storage Pool**: Storage pool libvirt harus terdefinisi dan aktif (default: `k3s_infra_pool` di `/var/lib/libvirt/images/k3s_infra_pool`).
- **User**: Akses sudo dan masuk ke grup `libvirt` serta `kvm`.
- **ISO Tooling**: `mkisofs` (atau `genisoimage` + symlink `mkisofs`) untuk membuat Cloud-Init ISO.

## 📀 Dependency Cloud-Init ISO (mkisofs)

Resource `libvirt_cloudinit_disk` membutuhkan executable `mkisofs` untuk membangun ISO seed Cloud-Init.

### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install -y genisoimage
command -v mkisofs >/dev/null 2>&1 || sudo ln -sf /usr/bin/genisoimage /usr/local/bin/mkisofs
mkisofs --version
```

### RHEL/CentOS/Rocky/Fedora
```bash
sudo dnf install -y genisoimage || sudo yum install -y genisoimage
command -v mkisofs >/dev/null 2>&1 || sudo ln -sf "$(command -v genisoimage)" /usr/local/bin/mkisofs
mkisofs --version
```

### Alpine
```bash
sudo apk add --no-cache cdrkit
command -v mkisofs >/dev/null 2>&1 || sudo ln -sf "$(command -v genisoimage)" /usr/local/bin/mkisofs
mkisofs --version
```

## 🔐 Permission & AppArmor (Disk Image)

Jika `qemu-system-x86_64` gagal membuka file qcow2 dengan `Permission denied` saat membuat `libvirt_domain`, penyebab paling umum di Ubuntu adalah mismatch AppArmor rule generator (`virt-aa-helper`) dengan template profile libvirt yang memakai include `*.files`.

### Validasi cepat
```bash
namei -l /var/lib/libvirt/images/k3s_infra_pool/ubuntu-base-img-k3s-master-01.qcow2
ls -ld /var/lib/libvirt/images /var/lib/libvirt/images/k3s_infra_pool
aa-status | head -n 60
```

### Perbaikan AppArmor (best practice)
Gunakan local override (aman untuk update package):
```bash
sudo mkdir -p /etc/apparmor.d/local
echo '/etc/apparmor.d/libvirt/libvirt-*.files rw,' | sudo tee -a /etc/apparmor.d/local/usr.lib.libvirt.virt-aa-helper
sudo apparmor_parser -r /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper
```

### Permission hardening untuk pool
Pastikan file image dimiliki user QEMU libvirt dan tidak world-writable:
```bash
sudo chown -R libvirt-qemu:kvm /var/lib/libvirt/images/k3s_infra_pool
sudo find /var/lib/libvirt/images/k3s_infra_pool -type d -exec chmod 0755 {} \;
sudo find /var/lib/libvirt/images/k3s_infra_pool -type f -name '*.qcow2' -exec chmod 0640 {} \;
sudo find /var/lib/libvirt/images/k3s_infra_pool -type f -name '*.iso' -exec chmod 0640 {} \;
```

## 🚀 Panduan Instalasi Cepat

### 1. Persiapan Environment Host
Jalankan script otomatisasi yang telah disediakan untuk menginstall KVM, Libvirt, dan Terraform.

```bash
chmod +x setup_kvm.sh
./setup_kvm.sh
```

> **PENTING**: Setelah script selesai, Anda **wajib logout dan login kembali** agar user Anda masuk ke grup `libvirt` dan `kvm`.

### 2. Verifikasi Instalasi
Pastikan KVM berjalan dengan baik:
```bash
virsh list --all
# Output harusnya kosong (tanpa error permission denied)
```

### 3. Konfigurasi Terraform
Sebelum menjalankan, pastikan Anda memiliki SSH Public Key. Jika belum ada:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

File `variables.tf` secara default akan mencari key di `~/.ssh/id_rsa.pub`.

## 📦 Deployment VM

### Inisialisasi Terraform
Download provider dan setup environment kerja:
```bash
terraform init
```

### Review Rencana (Plan)
Lihat apa yang akan dibuat oleh Terraform:
```bash
terraform plan
```

### Terapkan (Apply)
Mulai proses pembuatan VM. Terraform akan mendownload image Ubuntu (pertama kali akan memakan waktu) dan membuat VM.
```bash
terraform apply -auto-approve
```

## 🔍 Verifikasi & Pengujian

Setelah proses `apply` selesai, Terraform akan mengeluarkan output IP address.

### 1. Cek Konektivitas
```bash
# Ganti dengan IP dari output terraform
ping -c 3 <IP_ADDRESS>
```

### 2. Akses SSH
Gunakan perintah yang disediakan di output:
```bash
ssh ubuntu@<IP_ADDRESS>
```
Atau gunakan output command otomatis:
```bash
$(terraform output -raw connection_command)
```

### 3. Hapus Resource (Cleanup)
Untuk menghapus VM dan semua resource terkait:
```bash
terraform destroy -auto-approve
```

## 🔄 Integrasi CI/CD (DevOps)

Modul ini siap diintegrasikan dengan Jenkins, GitLab CI, atau GitHub Actions (Self-Hosted Runner).

**Strategi Pipeline:**

1.  **Runner**: Gunakan Self-Hosted Runner yang memiliki akses ke socket Libvirt (`/var/run/libvirt/libvirt-sock`).
2.  **State Management**: Simpan `terraform.tfstate` di backend remote (S3, GCS, atau Terraform Cloud) jangan di local runner.
3.  **Variables**: Inject variable sensitive (seperti SSH keys) melalui Environment Variables CI/CD (`TF_VAR_ssh_public_key`).

**Contoh Snippet GitLab CI (.gitlab-ci.yml):**

```yaml
stages:
  - deploy
  - destroy

deploy_vm:
  stage: deploy
  script:
    - terraform init
    - terraform apply -auto-approve
  tags:
    - kvm-runner

destroy_vm:
  stage: destroy
  script:
    - terraform destroy -auto-approve
  when: manual
  tags:
    - kvm-runner
```

## 📝 Struktur File

- `main.tf`: Definisi resource utama (VM, Disk, CloudInit).
- `variables.tf`: Definisi variabel input.
- `versions.tf`: Versi provider dan terraform.
- `cloud_init.cfg`: Template konfigurasi cloud-init.
- `setup_kvm.sh`: Helper script untuk bootstrap host.

---
*Dibuat dengan ❤️ oleh Tim Infrastruktur.*
