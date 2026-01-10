#!/bin/bash
set -e

# Warna untuk output
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}[INFO] Memulai setup environment KVM dan Terraform...${NC}"

# 1. Update dan Upgrade System
echo -e "${GREEN}[STEP 1] Update sistem...${NC}"
sudo apt-get update && sudo apt-get upgrade -y

# 2. Install KVM dan dependensinya
echo -e "${GREEN}[STEP 2] Instalasi KVM, Libvirt, dan tools terkait...${NC}"
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst libguestfs-tools genisoimage

# 3. Enable dan Start Libvirt Service
echo -e "${GREEN}[STEP 3] Menjalankan service Libvirt...${NC}"
sudo systemctl enable --now libvirtd
sudo systemctl start libvirtd

# 4. Menambahkan user saat ini ke grup libvirt (agar bisa menjalankan virsh tanpa sudo)
echo -e "${GREEN}[STEP 4] Konfigurasi permissions user...${NC}"
sudo usermod -aG libvirt $USER
sudo usermod -aG kvm $USER

# 5. Install Terraform (jika belum ada)
if ! command -v terraform &> /dev/null; then
    echo -e "${GREEN}[STEP 5] Instalasi Terraform...${NC}"
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update && sudo apt-get install -y terraform
else
    echo -e "${GREEN}[INFO] Terraform sudah terinstall.${NC}"
fi

# 6. Install plugin genisoimage untuk Cloud-Init (sudah termasuk di step 2, tapi memastikan)
# Diperlukan oleh provider libvirt untuk membuat ISO cloud-init

echo -e "${GREEN}[SUCCESS] Setup selesai!${NC}"
echo -e "${GREEN}[NOTE] Silakan LOGOUT dan LOGIN kembali agar perubahan grup user (permissions) berlaku.${NC}"
echo -e "${GREEN}[NOTE] Verifikasi instalasi dengan perintah: virsh list --all${NC}"
