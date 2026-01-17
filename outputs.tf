output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = "${path.module}/kubeconfig"
}

output "argocd_url" {
  description = "URL for ArgoCD"
  value       = "https://${var.argocd_hostname}"
}

output "vm_ip" {
  description = "IP address of the KVM VM"
  value       = var.server_ips[0]
}

output "kubeconfig_ready" {
  description = "Whether the kubeconfig is ready to be used by providers"
  value       = local.kubeconfig_ready
}

# ============================================================================
# ENHANCED OUTPUTS WITH SSH CONNECTION INFO
# ============================================================================
output "vm_connection_info" {
  description = "Complete connection information for the VM"
  value = {
    hostname    = var.vm_hostname
    ip_address  = local.node_ip != "" ? local.node_ip : "DHCP (check with: virsh domifaddr ${local.sanitized_hostname})"
    ssh_command = local.node_ip != "" ? "ssh ${var.ssh_username}@${local.node_ip}" : "Get IP first: virsh domifaddr ${local.sanitized_hostname}"
    ssh_user    = var.ssh_username
    vm_name     = local.sanitized_hostname
  }
}

output "vm_management_commands" {
  description = "Useful commands for managing the VM"
  value = {
    console_access  = "virsh console ${local.sanitized_hostname}"
    vm_info        = "virsh dominfo ${local.sanitized_hostname}"
    vm_status      = "virsh domstate ${local.sanitized_hostname}"
    get_ip         = "virsh domifaddr ${local.sanitized_hostname}"
    restart_vm     = "virsh reboot ${local.sanitized_hostname}"
    shutdown_vm    = "virsh shutdown ${local.sanitized_hostname}"
    force_stop     = "virsh destroy ${local.sanitized_hostname}"
  }
}

output "troubleshooting_info" {
  description = "Troubleshooting information and log locations"
  value = {
    health_check_log       = "${path.module}/.health_check.log"
    virt_detection_log     = "${path.module}/.virt_detection.log"
    cloudinit_cleanup_log  = "${path.module}/.cloudinit_cleanup.log"
    cloudinit_verification_log = "${path.module}/.cloudinit_verification.log"
    view_logs_command      = "tail -f ${path.module}/.health_check.log"
  }
}

# ============================================================================
# VIRSH MANAGEMENT COMMANDS
# ============================================================================
output "virsh_commands" {
  description = "Useful virsh commands for managing the VM"
  value = {
    console        = "virsh console ${local.sanitized_hostname}"
    console_exit   = "Press Ctrl+] to exit console"
    start          = "virsh start ${local.sanitized_hostname}"
    stop           = "virsh shutdown ${local.sanitized_hostname}"
    force_stop     = "virsh destroy ${local.sanitized_hostname}"
    reboot         = "virsh reboot ${local.sanitized_hostname}"
    status         = "virsh domstate ${local.sanitized_hostname}"
    info           = "virsh dominfo ${local.sanitized_hostname}"
    get_ip_agent   = "virsh domifaddr ${local.sanitized_hostname} --source agent"
    get_ip_lease   = "virsh domifaddr ${local.sanitized_hostname} --source lease"
    list_interface = "virsh domiflist ${local.sanitized_hostname}"
    vnc_display    = "virsh vncdisplay ${local.sanitized_hostname}"
    edit           = "virsh edit ${local.sanitized_hostname}"
    dumpxml        = "virsh dumpxml ${local.sanitized_hostname}"
  }
}

# ============================================================================
# K3S CONFIGURATION OUTPUTS
# ============================================================================
output "k3s_config" {
  description = "K3s configuration details"
  value = {
    version    = var.k3s_version
    role       = var.k3s_node_role
    server_url = var.k3s_server_url != "" ? var.k3s_server_url : "Not configured (standalone server)"
  }
  sensitive = false
}

# ============================================================================
# STORAGE OUTPUTS
# ============================================================================
output "storage_pool" {
  description = "Storage pool information"
  value = {
    name = var.libvirt_pool_name
    path = var.libvirt_pool_path
  }
}

output "volume_id" {
  description = "The ID of the VM's root volume"
  value       = libvirt_volume.ubuntu_base.id
}

output "cloudinit_id" {
  description = "The ID of the cloud-init disk"
  value       = libvirt_cloudinit_disk.commoninit.id
}

# ============================================================================
# DEPLOYMENT STATUS OUTPUTS
# ============================================================================
output "deployment_status" {
  description = "Deployment status and next steps"
  value = {
    vm_created     = true
    vm_name        = local.sanitized_hostname
    ip_configured  = var.vm_ip_address != "" ? true : false
    ip_address     = local.node_ip != "" ? local.node_ip : "DHCP - check with: virsh domifaddr ${local.sanitized_hostname}"
    ssh_ready      = "Check with: ssh -o ConnectTimeout=5 ${var.ssh_username}@${local.node_ip != "" ? local.node_ip : "<IP>"} 'echo OK'"
    next_steps     = [
      "1. Wait 2-5 minutes for cloud-init to complete",
      "2. Check VM IP: virsh domifaddr ${local.sanitized_hostname}",
      "3. Connect via SSH: ssh ${var.ssh_username}@${local.node_ip != "" ? local.node_ip : "<IP>"}",
      "4. Check cloud-init status: cloud-init status --wait",
      "5. Check K3s status: sudo kubectl get nodes"
    ]
  }
}

# ============================================================================
# TROUBLESHOOTING OUTPUTS
# ============================================================================
output "troubleshooting" {
  description = "Troubleshooting commands and information"
  value = {
    check_vm_status     = "virsh domstate ${local.sanitized_hostname}"
    check_vm_info       = "virsh dominfo ${local.sanitized_hostname}"
    access_console      = "virsh console ${local.sanitized_hostname}"
    check_ip_address    = "virsh domifaddr ${local.sanitized_hostname}"
    check_network       = "virsh net-list --all && virsh net-info ${var.network_name}"
    check_libvirt_logs  = "sudo journalctl -u libvirtd -n 100 --no-pager"
    restart_vm          = "virsh reboot ${local.sanitized_hostname}"
    force_restart       = "virsh destroy ${local.sanitized_hostname} && virsh start ${local.sanitized_hostname}"
    health_check_log    = "${path.module}/.health_check.log"
    cloud_init_log      = "ssh ${var.ssh_username}@${local.node_ip != "" ? local.node_ip : "<IP>"} 'sudo tail -f /var/log/cloud-init-output.log'"
  }
}

# ============================================================================
# QUICK REFERENCE OUTPUT
# ============================================================================
output "quick_reference" {
  description = "Quick reference for common operations"
  value = <<-EOT
    ╔════════════════════════════════════════════════════════════════════════╗
    ║                    VM DEPLOYMENT SUCCESSFUL                            ║
    ╚════════════════════════════════════════════════════════════════════════╝
    
    VM Details:
    -----------
    Name:        ${local.sanitized_hostname}
    Hostname:    ${var.vm_hostname}
    IP Address:  ${local.node_ip != "" ? local.node_ip : "DHCP (check with: virsh domifaddr ${local.sanitized_hostname})"}
    Memory:      ${var.vm_memory} MB
    vCPUs:       ${var.vm_vcpu}
    Disk:        ${var.vm_disk_size / 1073741824} GB
    
    Virtualization:
    ---------------
    Type:        ${local.domain_type}
    Emulator:    ${local.detected_emulator}
    CPU Mode:    ${local.effective_cpu_mode}
    UEFI:        ${local.use_uefi ? "Yes" : "No"}
    
    SSH Connection:
    ---------------
    ${local.node_ip != "" ? "ssh ${var.ssh_username}@${local.node_ip}" : "Wait for IP assignment, then: ssh ${var.ssh_username}@<IP>"}
    
    Common Commands:
    ----------------
    Check VM status:     virsh domstate ${local.sanitized_hostname}
    Access console:      virsh console ${local.sanitized_hostname}
    Get IP address:      virsh domifaddr ${local.sanitized_hostname}
    Reboot VM:           virsh reboot ${local.sanitized_hostname}
    
    Next Steps:
    -----------
    1. Wait 2-5 minutes for cloud-init to complete
    2. Connect via SSH and check status:
       ${local.node_ip != "" ? "ssh ${var.ssh_username}@${local.node_ip} 'cloud-init status --wait'" : "ssh ${var.ssh_username}@<IP> 'cloud-init status --wait'"}
    3. Check K3s cluster status:
       ${local.node_ip != "" ? "ssh ${var.ssh_username}@${local.node_ip} 'sudo kubectl get nodes'" : "ssh ${var.ssh_username}@<IP> 'sudo kubectl get nodes'"}
    
    Troubleshooting:
    ----------------
    Health check log:    ${path.module}/.health_check.log
    VM console:          virsh console ${local.sanitized_hostname}
    Libvirt logs:        sudo journalctl -u libvirtd -n 100
    
    ╚════════════════════════════════════════════════════════════════════════╝
  EOT
}