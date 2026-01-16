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

echo "✅ All permissions fixed!"