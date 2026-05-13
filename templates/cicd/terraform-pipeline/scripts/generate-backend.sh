#!/bin/bash
set -euo pipefail

ENV="${1:-${ENV}}"
BACKEND_BUCKET="${BACKEND_BUCKET:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
AWS_REGION="${AWS_REGION:-}"

if [ -z "${ENV}" ] || [ -z "${BACKEND_BUCKET}" ] || [ -z "${PROJECT_NAME}" ] || [ -z "${AWS_REGION}" ]; then
    echo "Usage: ENV=<env> BACKEND_BUCKET=<bucket> PROJECT_NAME=<project> AWS_REGION=<region> $0"
    echo "  or:  $0 <env>"
    echo ""
    echo "Required environment variables:"
    echo "  ENV              Deployment environment (dev, qa, uat, prod)"
    echo "  BACKEND_BUCKET   S3 bucket name for Terraform state"
    echo "  PROJECT_NAME     Project identifier"
    echo "  AWS_REGION       AWS region"
    exit 1
fi

echo "==> Generating backend configuration for environment: ${ENV}"
echo "==> Bucket: ${BACKEND_BUCKET}"
echo "==> State key: ${PROJECT_NAME}/${ENV}/terraform.tfstate"

cat > "backend-${ENV}.hcl" <<EOF
bucket         = "${BACKEND_BUCKET}"
key            = "${PROJECT_NAME}/${ENV}/terraform.tfstate"
region         = "${AWS_REGION}"
encrypt        = true
use_lockfile   = true
EOF

echo "==> Backend configuration written to backend-${ENV}.hcl"
echo ""
echo "Contents:"
cat "backend-${ENV}.hcl"
