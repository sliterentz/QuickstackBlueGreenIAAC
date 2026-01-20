resource "null_resource" "k3s_install" {
  depends_on = [module.kvm_ubuntu]

  connection {
    type        = "ssh"
    user        = var.ssh_username
    private_key = file(var.ssh_private_key_path)
    host        = var.server_ips[0]
    timeout     = "10m" # Meningkatkan timeout threshold untuk koneksi awal
  }

  # Ensure SSH is ready before attempting remote-exec
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait_for_ssh.sh ${var.server_ips[0]} 22 600"
  }

  # Tunggu Cloud-init dan K3s selesai diinstall dengan retry mechanism
  provisioner "remote-exec" {
    inline = [
      "echo 'Verifying network connectivity...'",
      "ip a",
      "echo 'Waiting for cloud-init to finish (this might take a few minutes)...'",
      "i=0; FINISHED=false; while [ $i -lt 120 ]; do",
      "  if [ -f /var/lib/cloud/instance/boot-finished-k3s ]; then",
      "    echo 'Cloud-init finished successfully.';",
      "    FINISHED=true; break;",
      "  fi;",
      "  i=$((i+1));",
      "  echo \"Still waiting for cloud-init ($((i*10))s)...\";",
      "  if [ $((i % 6)) -eq 0 ]; then echo '--- Recent cloud-init logs ---'; tail -n 5 /var/log/cloud-init-output.log 2>/dev/null || echo 'Log not available yet'; echo '----------------------------'; fi;",
      "  sleep 10;",
      "done",
      "if [ \"$FINISHED\" != \"true\" ]; then",
      "  echo 'ERROR: Cloud-init timed out after 20 minutes!';",
      "  echo '--- Final system status for debugging ---';",
      "  uptime;",
      "  free -m;",
      "  df -h /;",
      "  echo '--- Final cloud-init logs ---';",
      "  tail -n 50 /var/log/cloud-init-output.log;",
      "  exit 1;",
      "fi",
      "echo 'Checking K3s configuration...'",
      "if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then",
      "  echo 'ERROR: K3s config (/etc/rancher/k3s/k3s.yaml) not found!';",
      "  systemctl status k3s --no-pager || echo 'K3s service not found';",
      "  journalctl -u k3s -n 20 --no-pager;",
      "  exit 1;",
      "fi",
      "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/kubeconfig",
      "sudo chmod 644 /tmp/kubeconfig",
      "echo 'K3s is ready and kubeconfig is prepared.'"
    ]
  }

  # Copy kubeconfig ke host local
  provisioner "local-exec" {
    command = <<EOT
      echo 'Attempting to fetch kubeconfig from remote VM...'
      MAX_RETRIES=5
      RETRY_COUNT=0
      until scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.ssh_private_key_path} ${var.ssh_username}@${var.server_ips[0]}:/tmp/kubeconfig ${path.module}/kubeconfig || [ $RETRY_COUNT -eq $MAX_RETRIES ]; do
        echo "SCP failed, retrying in 5 seconds... ($((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep 5
        RETRY_COUNT=$((RETRY_COUNT+1))
      done
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo 'ERROR: Failed to fetch kubeconfig after multiple attempts!'
        exit 1
      fi
      echo 'Kubeconfig successfully fetched.'
    EOT
  }

  # Update kubeconfig dengan IP VM yang benar (bukan 127.0.0.1)
  provisioner "local-exec" {
    command = "sed -i 's/127.0.0.1/${var.server_ips[0]}/g' ${path.module}/kubeconfig"
  }
}

# Wait for cluster to be ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [null_resource.k3s_install]

  provisioner "local-exec" {
    command = "sleep 120 && KUBECONFIG=./kubeconfig kubectl wait --for=condition=Ready nodes --all --timeout=600s"
  }
}
