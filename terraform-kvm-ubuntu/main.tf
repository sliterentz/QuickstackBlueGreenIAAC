# Resource 0: Mendefinisikan Storage Pool
# Pastikan pool 'default' ada. Jika sudah ada di sistem, Terraform akan mencoba mengelolanya.
resource "libvirt_pool" "default" {
  name = "default"
  type = "dir"
  path = "/var/lib/libvirt/images"
}

# Resource 1: Mendefinisikan Volume Storage
resource "libvirt_volume" "ubuntu_base_img" {
  name   = "ubuntu-base-img.qcow2"
  pool   = libvirt_pool.default.name
  source = var.ubuntu_img_url
  format = "qcow2"
}

resource "libvirt_volume" "ubuntu_base" {
  name           = "ubuntu-base-${var.vm_hostname}.qcow2"
  pool           = libvirt_pool.default.name
  base_volume_id = libvirt_volume.ubuntu_base_img.id
  format         = "qcow2"
  size           = 21474836480 # 20GB
}

# (Opsional) Jika ingin mengubah ukuran disk, kita buat volume baru berbasis base image
# Namun untuk kesederhanaan, kita bisa menggunakan volume di atas atau resize on boot via cloud-init.
# Di sini kita gunakan pendekatan cloud-init resize otomatis yang sudah built-in di image Ubuntu.

# Resource 2: Konfigurasi Cloud-Init Disk
# Ini membuat file ISO kecil yang akan dimount ke VM untuk konfigurasi awal (user, ssh, dll)
data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    hostname = var.vm_hostname
    ssh_key  = var.ssh_public_key
  }
}

resource "libvirt_cloudinit_disk" "commoninit" {
  name      = "commoninit-${var.vm_hostname}.iso"
  user_data = data.template_file.user_data.rendered
  pool      = libvirt_pool.default.name
}

# Resource 3: Virtual Machine (Domain)
resource "libvirt_domain" "ubuntu_vm" {
  name   = var.vm_hostname
  memory = var.vm_memory
  vcpu   = var.vm_vcpu
  arch     = "x86_64"
  type     = "qemu"
  qemu_agent = true # Diaktifkan agar Terraform bisa mengambil IP langsung dari guest OS

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  # Konfigurasi Network Interface
  network_interface {
    network_name   = var.network_name
    wait_for_lease = true
  }

  # Konfigurasi Boot Disk
  disk {
    volume_id = libvirt_volume.ubuntu_base.id
  }

  # Konfigurasi Konsol (Penting untuk debugging via 'virsh console')
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  video {
    type = "vga"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }
}
