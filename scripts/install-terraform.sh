#!/bin/bash
set -euo pipefail

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.10.5}"
TERRAFORM_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"

echo "==> Downloading Terraform v${TERRAFORM_VERSION}..."
curl -fsSL "${TERRAFORM_URL}" -o /tmp/terraform.zip

echo "==> Extracting Terraform..."
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin/

echo "==> Verifying installation..."
terraform --version

echo "==> Terraform v${TERRAFORM_VERSION} installed successfully"
