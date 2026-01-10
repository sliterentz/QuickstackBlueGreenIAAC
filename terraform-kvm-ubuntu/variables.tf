variable "vm_hostname" {
  description = "Hostname untuk virtual machine"
  type        = string
  default     = "ubuntu-lts-vm"
}

variable "vm_memory" {
  description = "Jumlah RAM dalam MB"
  type        = number
  default     = 4096
}

variable "vm_vcpu" {
  description = "Jumlah virtual CPU"
  type        = number
  default     = 2
}

variable "vm_disk_size" {
  description = "Ukuran disk dalam bytes (default 20GB)"
  type        = number
  default     = 21474836480 # 20GB
}

variable "ubuntu_img_url" {
  description = "URL download image Ubuntu Cloud (qcow2)"
  type        = string
  # Ubuntu 24.04 LTS (Noble Numbat) Cloud Image
  default     = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  description = "Public key SSH untuk akses ke VM"
  type        = string
  # Ganti dengan path ke public key Anda yang sebenarnya, misal ~/.ssh/id_rsa.pub
  default     = "~/.ssh/id_rsa.pub"
}

variable "network_name" {
  description = "Nama network bridge libvirt (default biasanya 'default')"
  type        = string
  default     = "default"
}
