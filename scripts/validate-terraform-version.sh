#!/bin/bash
set -euo pipefail

MIN_VERSION="1.10"

echo "==> Checking Terraform installation..."
if ! command -v terraform &> /dev/null; then
    echo "ERROR: terraform not found. Install terraform first."
    exit 1
fi

INSTALLED_VERSION=$(terraform version -json | jq -r '.terraform_version')
echo "==> Installed Terraform version: ${INSTALLED_VERSION}"
echo "==> Minimum required version: ${MIN_VERSION}"

if [ "$(printf '%s\n' "${MIN_VERSION}" "${INSTALLED_VERSION}" | sort -V | head -n1)" != "${MIN_VERSION}" ]; then
    echo "ERROR: Terraform version ${INSTALLED_VERSION} is less than required minimum ${MIN_VERSION}"
    exit 1
fi

echo "==> Terraform version ${INSTALLED_VERSION} validated successfully"
