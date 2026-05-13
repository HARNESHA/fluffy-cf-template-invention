#!/bin/bash
set -euo pipefail

TARGET_ROLE_ARN="${TARGET_ROLE_ARN:-}"
ROLE_SESSION_NAME="${ROLE_SESSION_NAME:-terraform-deployment}"
DURATION_SECONDS="${DURATION_SECONDS:-3600}"

if [ -z "${TARGET_ROLE_ARN}" ]; then
    echo "==> TARGET_ROLE_ARN not set. Skipping role assumption."
    exit 0
fi

echo "==> Assuming role: ${TARGET_ROLE_ARN}"
echo "==> Session name: ${ROLE_SESSION_NAME}"
echo "==> Duration: ${DURATION_SECONDS}s"

CREDENTIALS=$(aws sts assume-role \
    --role-arn "${TARGET_ROLE_ARN}" \
    --role-session-name "${ROLE_SESSION_NAME}" \
    --duration-seconds "${DURATION_SECONDS}")

export AWS_ACCESS_KEY_ID=$(echo "${CREDENTIALS}" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "${CREDENTIALS}" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "${CREDENTIALS}" | jq -r '.Credentials.SessionToken')

echo "==> Successfully assumed role: ${TARGET_ROLE_ARN}"
echo "==> Credentials will expire in ${DURATION_SECONDS}s"
echo ""
echo "Exported environment variables:"
echo "  AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
echo "  AWS_SECRET_ACCESS_KEY=<redacted>"
echo "  AWS_SESSION_TOKEN=<redacted>"
