#!/bin/bash
set -e

echo "========================================================"
echo "Verifikasi Perbaikan Terraform Storage Pool"
echo "========================================================"

# 1. Validasi Konfigurasi Terraform
echo "[1] Memeriksa sintaks Terraform..."
if terraform validate; then
    echo "✓ Konfigurasi valid."
else
    echo "✗ Konfigurasi tidak valid. Silakan periksa error di atas."
    exit 1
fi

echo ""
echo "========================================================"
echo "Panduan Pengujian (Jalankan perintah ini manual)"
echo "========================================================"

echo "Skenario 1: Pool SUDAH ADA (Kondisi saat ini)"
echo "--------------------------------------------------------"
echo "Jalankan: terraform apply --auto-approve"
echo "Harapan : Tidak ada error 'already exists'. Script akan mendeteksi pool dan menggunakannya."
echo ""

echo "Skenario 2: Pool BELUM ADA (Simulasi clean install)"
echo "--------------------------------------------------------"
echo "Langkah:"
echo "1. Hapus pool manual: virsh pool-destroy k3s_infra_pool && virsh pool-undefine k3s_infra_pool"
echo "2. Hapus state null_resource (jika ada): terraform state rm module.kvm_ubuntu.null_resource.pool_management"
echo "3. Jalankan: terraform apply --auto-approve"
echo "Harapan : Terraform membuat pool baru via script."
echo ""

echo "Skenario 3: Idempotency (Jalankan ulang)"
echo "--------------------------------------------------------"
echo "Jalankan: terraform apply --auto-approve"
echo "Harapan : Terraform tidak melakukan perubahan apa pun (0 added, 0 changed)."
echo ""

echo "========================================================"
echo "Script check selesai. Silakan lanjutkan dengan 'terraform apply'."
