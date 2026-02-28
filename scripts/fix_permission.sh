#!/bin/bash

set -euo pipefail

echo "🔧 Fixing file permissions..."

# Make scripts executable
chmod +x scripts/*.sh 2>/dev/null || true

# Fix SSH key permissions if exists
if [ -f "$HOME/.ssh/id_rsa" ]; then
    chmod 600 "$HOME/.ssh/id_rsa"
    echo "✓ Fixed SSH private key permissions"
fi

if [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    chmod 644 "$HOME/.ssh/id_rsa.pub"
    echo "✓ Fixed SSH public key permissions"
fi

# Fix terraform files permissions
find . -name "*.tf" -type f -exec chmod 644 {} \;
echo "✓ Fixed Terraform configuration file permissions"

# Fix terraform state permissions if exists
if [ -f "terraform.tfstate" ]; then
    chmod 600 terraform.tfstate
    echo "✓ Fixed Terraform state file permissions"
fi

POOL_PATH="/var/lib/libvirt/images/k3s_infra_pool"

# 1. Fix directory ownership
echo "📁 Fixing directory ownership..."
sudo chown -R libvirt-qemu:kvm "$POOL_PATH" 2>/dev/null || \
sudo chown -R qemu:kvm "$POOL_PATH" 2>/dev/null || {
    echo "⚠️  Gagal set ownership, mencoba dengan user alternatif..."
    sudo chown -R $(id -u):$(id -g) "$POOL_PATH"
}

sudo chmod 755 "$POOL_PATH"

# 2. Fix file permissions
echo "📄 Fixing file permissions..."
sudo find "$POOL_PATH" -type f \( -name "*.qcow2" -o -name "*.iso" \) -exec chmod 644 {} \;
sudo find "$POOL_PATH" -type f \( -name "*.qcow2" -o -name "*.iso" \) -exec chown libvirt-qemu:kvm {} \; 2>/dev/null || \
sudo find "$POOL_PATH" -type f \( -name "*.qcow2" -o -name "*.iso" \) -exec chown qemu:kvm {} \; 2>/dev/null || true

# 3. SELinux context (jika ada)
if command -v getenforce >/dev/null 2>&1; then
    if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        echo "🔒 Fixing SELinux context..."
        sudo semanage fcontext -a -t virt_image_t "$POOL_PATH(/.*)?" 2>/dev/null || true
        sudo restorecon -Rv "$POOL_PATH"
    fi
fi

# 4. AppArmor (jika ada)
if command -v aa-status >/dev/null 2>&1; then
    echo "🛡️  Checking AppArmor..."
    APPARMOR_LOCAL="/etc/apparmor.d/local/abstractions/libvirt-qemu"
    if [[ -f "$APPARMOR_LOCAL" ]]; then
        if ! sudo grep -q "$POOL_PATH" "$APPARMOR_LOCAL" 2>/dev/null; then
            echo "  \"$POOL_PATH/**\" rwk," | sudo tee -a "$APPARMOR_LOCAL"
            sudo systemctl reload apparmor 2>/dev/null || true
        fi
    fi
fi

# 5. Restart libvirt services
echo "🔄 Restarting libvirt services..."
sudo systemctl restart libvirtd 2>/dev/null || \
sudo systemctl restart virtqemud 2>/dev/null || true

sleep 2

# 6. Verify
echo "✅ Verification:"
ls -lah "$POOL_PATH" | head -n 10


echo "✅ All permissions fixed!"