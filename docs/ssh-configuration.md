# Dokumentasi Konfigurasi SSH untuk Cluster KVM

Dokumen ini menjelaskan konfigurasi SSH yang digunakan untuk memastikan akses yang aman dan stabil ke node cluster KVM.

## 1. Arsitektur Koneksi

Koneksi SSH ke VM dalam cluster ini menggunakan beberapa lapisan optimasi:

1.  **Host-Level Optimization**: Konfigurasi pada mesin host (deployment machine).
2.  **VM-Level Optimization**: Konfigurasi pada sisi server (VM) melalui Cloud-Init.
3.  **Discovery Mechanism**: Script otomatis untuk mendeteksi IP address VM.

## 2. Persyaratan Host

Mesin yang menjalankan script deployment harus memiliki konfigurasi SSH client berikut untuk performa maksimal.

### Rekomendasi `~/.ssh/config`

Tambahkan konfigurasi berikut ke file `~/.ssh/config` Anda untuk mempercepat koneksi dan menghindari timeout:

```ssh
Host cluster-*
    User ubuntu
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_rsa
    # Keepalive untuk mencegah putus koneksi
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
    # Timeout settings
    ConnectTimeout 10
    # Auto accept new host keys (Hati-hati di production public network)
    StrictHostKeyChecking accept-new
    # Multiplexing untuk mempercepat koneksi berulang
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 300
```

## 3. Konfigurasi VM (Server Side)

VM dikonfigurasi secara otomatis menggunakan Cloud-Init saat boot pertama. Konfigurasi ini menerapkan hardening sesuai standar CIS (Center for Internet Security).

### File Konfigurasi: `/etc/ssh/sshd_config.d/99-hardening.conf`

Berikut adalah parameter yang diterapkan:

| Parameter | Value | Penjelasan |
|-----------|-------|------------|
| `PubkeyAuthentication` | `yes` | Mewajibkan autentikasi menggunakan SSH Key. |
| `PasswordAuthentication` | `no` | Menonaktifkan login password untuk keamanan. |
| `PermitRootLogin` | `prohibit-password` | Root hanya boleh login via key (jika dikonfigurasi). |
| `UseDNS` | `no` | Mempercepat login dengan menonaktifkan reverse DNS lookup. |
| `ClientAliveInterval` | `30` | Mengirim paket keepalive ke client setiap 30 detik. |
| `ClientAliveCountMax` | `4` | Memutuskan koneksi jika client tidak merespon 4x (2 menit). |
| `MaxAuthTries` | `3` | Membatasi percobaan login gagal maksimal 3 kali. |
| `LogLevel` | `VERBOSE` | Logging lebih detail untuk troubleshooting. |
| `AllowUsers` | `ubuntu` | Hanya user `ubuntu` yang diizinkan login via SSH. |

## 4. Troubleshooting Akses SSH

Jika deployment gagal karena masalah SSH, ikuti langkah-langkah berikut:

### Langkah 1: Cek IP Address
Gunakan perintah `virsh` untuk melihat apakah VM mendapatkan IP:
```bash
virsh domifaddr <vm-name> --source agent
# atau
virsh domifaddr <vm-name> --source lease
```

### Langkah 2: Cek Console
Jika IP tidak muncul, masuk ke console VM untuk diagnosa jaringan:
```bash
virsh console <vm-name>
# Login dengan user/pass default jika ada, atau cek boot log
```

### Langkah 3: Verifikasi Cloud-Init
Pastikan cloud-init selesai berjalan. Di dalam VM (jika bisa akses console):
```bash
tail -f /var/log/cloud-init-output.log
```

### Langkah 4: Cek Status Service
Pastikan QEMU Guest Agent berjalan (penting untuk IP discovery):
```bash
systemctl status qemu-guest-agent
```

## 5. Script Health Check

Sistem deployment dilengkapi dengan `scripts/health_check.sh` yang otomatis berjalan setelah pembuatan VM. Script ini melakukan:
1.  Pengecekan koneksi Libvirt.
2.  Verifikasi status VM (Running).
3.  Discovery IP Address (via Agent, Lease, atau ARP).
4.  Tes konektivitas jaringan (Ping).
5.  Tes konektivitas SSH.
6.  Verifikasi status Cloud-Init.

Script ini memiliki mekanisme retry otomatis hingga 5 menit untuk menunggu proses boot selesai.
