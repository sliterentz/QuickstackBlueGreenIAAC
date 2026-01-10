resource "null_resource" "k3s_install" {
  depends_on = [module.kvm_ubuntu]

  connection {
    type        = "ssh"
    user        = "ubuntu" # User default dari cloud-init
    private_key = file(var.ssh_private_key_path)
    host        = module.kvm_ubuntu.vm_ip_address[0]
    timeout     = "10m" # Tambahkan timeout lebih lama
  }

  # Tunggu K3s selesai diinstall oleh cloud-init
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for k3s to be ready...'",
      "while [ ! -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/kubeconfig",
      "sudo chmod 644 /tmp/kubeconfig",
    ]
  }

  # Copy kubeconfig ke host local
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} ubuntu@${module.kvm_ubuntu.vm_ip_address[0]}:/tmp/kubeconfig ${path.module}/kubeconfig"
  }

  # Update kubeconfig dengan IP VM yang benar (bukan 127.0.0.1)
  provisioner "local-exec" {
    command = "sed -i 's/127.0.0.1/${module.kvm_ubuntu.vm_ip_address[0]}/g' ${path.module}/kubeconfig"
  }
}

# Wait for cluster to be ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [null_resource.k3s_install]

  provisioner "local-exec" {
    command = "sleep 60 && KUBECONFIG=./kubeconfig kubectl wait --for=condition=Ready nodes --all --timeout=600s"
  }
}
