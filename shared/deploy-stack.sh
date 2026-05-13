#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: $0 <template-path> <stack-name> <parameters-file> [additional-args...]"
    echo ""
    echo "Deploys a CloudFormation template from the templates directory."
    echo ""
    echo "Arguments:"
    echo "  template-path     Relative path to template directory (e.g., cicd/terraform-pipeline)"
    echo "  stack-name        CloudFormation stack name"
    echo "  parameters-file   Path to JSON parameters file"
    echo "  additional-args   Extra arguments passed to aws cloudformation deploy"
    echo ""
    echo "Examples:"
    echo "  $0 cicd/terraform-pipeline myproject-dev-tf-pipeline \\"
    echo "       templates/cicd/terraform-pipeline/parameters/dev.json"
    echo ""
    echo "  $0 networking/vpc-baseline myproject-dev-vpc \\"
    echo "       templates/networking/vpc-baseline/parameters/dev.json \\"
    echo "       --tags Project=myproject Environment=dev"
    exit 1
}

if [ "$#" -lt 3 ]; then
    usage
fi

TEMPLATE_PATH="$1"
STACK_NAME="$2"
PARAMS_FILE="$3"
shift 3

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${ROOT_DIR}/templates/${TEMPLATE_PATH}/template.yaml"

if [ ! -f "${TEMPLATE_FILE}" ]; then
    echo "ERROR: Template not found: ${TEMPLATE_FILE}"
    exit 1
fi

if [ ! -f "${PARAMS_FILE}" ]; then
    echo "ERROR: Parameters file not found: ${PARAMS_FILE}"
    exit 1
fi

echo "==> Deploying CloudFormation stack: ${STACK_NAME}"
echo "==> Template: ${TEMPLATE_FILE}"
echo "==> Parameters: ${PARAMS_FILE}"
echo ""

aws cloudformation deploy \
    --template-file "${TEMPLATE_FILE}" \
    --stack-name "${STACK_NAME}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides file://"${PARAMS_FILE}" \
    "$@"
