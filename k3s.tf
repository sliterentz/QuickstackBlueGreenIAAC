resource "null_resource" "k3s_install" {
  connection {
    type        = "ssh"
    user        = var.ssh_username
    private_key = file(var.ssh_private_key_path)
    host        = var.server_ips[0]
  }

  # Copy kubeconfig from existing k3s installation
  provisioner "remote-exec" {
    inline = [
      "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/kubeconfig",
      "sudo chmod 644 /tmp/kubeconfig",
    ]
  }

  # Copy kubeconfig
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -i ${var.ssh_private_key_path} ${var.ssh_username}@${var.server_ips[0]}:/tmp/kubeconfig ${path.module}/kubeconfig"
  }

  # Update kubeconfig with correct server address
  provisioner "local-exec" {
    command = "sed -i 's/127.0.0.1/${var.server_ips[0]}/g' ${path.module}/kubeconfig"
  }
}

# Wait for cluster to be ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [null_resource.k3s_install]

  provisioner "local-exec" {
    command = "sleep 10 && KUBECONFIG=${path.module}/kubeconfig kubectl wait --for=condition=Ready nodes --all --timeout=300s"
  }
}
