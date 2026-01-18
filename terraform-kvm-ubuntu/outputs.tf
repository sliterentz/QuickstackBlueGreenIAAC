# ============================================================================
# OUTPUTS
# ============================================================================

output "vm_id" {
  description = "ID of the created VM"
  value       = libvirt_domain.ubuntu_vm.id
}

output "vm_name" {
  description = "Nama VM yang dibuat"
  value       = libvirt_domain.ubuntu_vm.name
}

output "vm_hostname" {
  description = "Hostname of the VM"
  value       = var.vm_hostname
}

output "domain_type" {
  description = "Virtualization type used (kvm or qemu)"
  value       = local.domain_type
}

output "vm_ip_address" {
  description = "IP Address dari VM (didapat dari DHCP lease)"
  value       = libvirt_domain.ubuntu_vm.network_interface[0].addresses
}

output "connection_command" {
  description = "Perintah SSH untuk connect ke VM"
  value       = "ssh ubuntu@${length(libvirt_domain.ubuntu_vm.network_interface[0].addresses) > 0 ? libvirt_domain.ubuntu_vm.network_interface[0].addresses[0] : "IP_UNKNOWN"}"
}

output "vm_ip_configured" {
  description = "IP address yang dikonfigurasi (static atau akan dapat dari DHCP)"
  value       = var.vm_ip_address != "" ? local.node_ip : "DHCP - Check with: virsh domifaddr ${var.vm_hostname}"
}

output "k3s_node_role" {
  description = "Role K3s node"
  value       = var.k3s_node_role
}

output "k3s_version" {
  description = "Versi K3s yang diinstall"
  value       = var.k3s_version
}

output "ssh_command" {
  description = "Command untuk SSH ke VM"
  value       = var.vm_ip_address != "" ? "ssh ubuntu@${local.node_ip}" : "ssh ubuntu@<check-ip-with-virsh>"
}

output "kubeconfig_location" {
  description = "Lokasi kubeconfig di server node"
  value       = var.k3s_node_role == "server" ? "/etc/rancher/k3s/k3s.yaml" : "N/A (agent node)"
}

output "deployment_timestamp" {
  description = "Timestamp of deployment"
  value       = local.deployment_timestamp
}

# ============================================================================
# TROUBLESHOOTING & LOGS
# ============================================================================
output "troubleshooting_info" {
  description = "Troubleshooting information and log locations"
  value = {
    health_check_log           = "${path.module}/logs/.health_check.log"
    virt_detection_log         = "${path.module}/logs/.virt_detection.log"
    cloudinit_cleanup_log      = "${path.module}/logs/.cloudinit_cleanup.log"
    cloudinit_verification_log = "${path.module}/logs/.cloudinit_verification.log"
    pre_deployment_check_log   = "${path.module}/logs/.pre_deployment_check.log"
    view_logs_command          = "tail -f ${path.module}/logs/.health_check.log"
  }
}