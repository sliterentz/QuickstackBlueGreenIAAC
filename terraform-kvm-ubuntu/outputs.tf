output "vm_name" {
  description = "Nama VM yang dibuat"
  value       = libvirt_domain.ubuntu_vm.name
}

output "vm_ip_address" {
  description = "IP Address dari VM (didapat dari DHCP lease)"
  value       = libvirt_domain.ubuntu_vm.network_interface[0].addresses
}

output "connection_command" {
  description = "Perintah SSH untuk connect ke VM"
  value       = "ssh ubuntu@${length(libvirt_domain.ubuntu_vm.network_interface[0].addresses) > 0 ? libvirt_domain.ubuntu_vm.network_interface[0].addresses[0] : "IP_UNKNOWN"}"
}
