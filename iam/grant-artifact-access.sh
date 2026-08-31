#!/usr/bin/env bash
# =============================================================================
# grant-artifact-access.sh
# Grants the EventBridge forwarder role cross-account access to the
# CodePipeline artifact bucket in the Pipeline Account.
#
# This applies an S3 bucket policy that allows the forwarder role
# (in the Repository Account) to read and write artifacts.
#
# Prerequisites:
#   - Pipeline stack (Template 1) already deployed
#   - setup-event-forwarder.sh already run (forwarder role exists)
#   - Artifact bucket exists in the Pipeline Account
#
# Usage:
#   ./iam/grant-artifact-access.sh \
#     --artifact-bucket my-org-codepipeline-artifacts-444455556666 \
#     --forwarder-role-arn "arn:aws:iam::111122223333:role/my-repo-main-event-forwarder-role" \
#     --pipeline-account-id 444455556666 \
#     --profile pipeline-account
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ARTIFACT_BUCKET=""
FORWARDER_ROLE_ARN=""
PIPELINE_ACCOUNT_ID=""
DRY_RUN=false
PROFILE=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --artifact-bucket)     ARTIFACT_BUCKET="$2";     shift 2 ;;
    --forwarder-role-arn)  FORWARDER_ROLE_ARN="$2";  shift 2 ;;
    --pipeline-account-id) PIPELINE_ACCOUNT_ID="$2"; shift 2 ;;
    --dry-run)             DRY_RUN=true;             shift ;;
    --profile)             PROFILE="$2";             shift 2 ;;
    --help)
      echo "Usage: $0 --artifact-bucket <bucket> --forwarder-role-arn <arn> --pipeline-account-id <id> [options]"
      echo ""
      echo "Required:"
      echo "  --artifact-bucket       S3 bucket name for CodePipeline artifacts"
      echo "  --forwarder-role-arn    Full ARN of the forwarder role in the repo account"
      echo "  --pipeline-account-id   AWS Account ID of the Pipeline Account"
      echo ""
      echo "Optional:"
      echo "  --dry-run               Print commands without executing"
      echo "  --profile               AWS CLI profile for pipeline account"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ -z "$ARTIFACT_BUCKET" ]]; then
  echo "ERROR: --artifact-bucket is required"
  exit 1
fi

if [[ -z "$FORWARDER_ROLE_ARN" ]]; then
  echo "ERROR: --forwarder-role-arn is required"
  exit 1
fi
if [[ ! "$FORWARDER_ROLE_ARN" =~ ^arn:aws:iam:: ]]; then
  echo "ERROR: --forwarder-role-arn must be a valid IAM Role ARN"
  exit 1
fi

if [[ -z "$PIPELINE_ACCOUNT_ID" ]]; then
  echo "ERROR: --pipeline-account-id is required"
  exit 1
fi
if [[ ! "$PIPELINE_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: --pipeline-account-id must be a 12-digit number"
  exit 1
fi

# ---------------------------------------------------------------------------
# Display configuration
# ---------------------------------------------------------------------------
echo "============================================"
echo "  Grant Artifact Bucket Access"
echo "============================================"
echo "Artifact Bucket    : $ARTIFACT_BUCKET"
echo "Forwarder Role ARN : $FORWARDER_ROLE_ARN"
echo "Pipeline Account   : $PIPELINE_ACCOUNT_ID"
echo "Dry Run            : $DRY_RUN"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Helper function
# ---------------------------------------------------------------------------
PROFILE_FLAG=""
if [[ -n "$PROFILE" ]]; then
  PROFILE_FLAG="--profile $PROFILE"
fi

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $*"
  else
    echo "Running: $*"
    eval "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Get existing bucket policy (if any)
# ---------------------------------------------------------------------------
echo "--- Checking existing bucket policy ---"

EXISTING_POLICY=$(aws s3api get-bucket-policy \
  --bucket "${ARTIFACT_BUCKET}" \
  --region us-east-1 \
  ${PROFILE_FLAG} \
  --query 'Policy' --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_POLICY" ]]; then
  echo "Existing policy found. Merging with new statements."
else
  echo "No existing policy. Creating new policy."
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Build bucket policy
# ---------------------------------------------------------------------------
echo "--- Building bucket policy ---"

BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowForwarderRoleReadWrite",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${FORWARDER_ROLE_ARN}"
      },
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::${ARTIFACT_BUCKET}/*"
    },
    {
      "Sid": "AllowForwarderRoleListBucket",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${FORWARDER_ROLE_ARN}"
      },
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${ARTIFACT_BUCKET}"
    }
  ]
}
EOF
)

echo "Policy built."
echo ""

# ---------------------------------------------------------------------------
# 3. Apply bucket policy
# ---------------------------------------------------------------------------
echo "--- Applying bucket policy ---"

# Write policy to temp file for AWS CLI
TEMP_POLICY_FILE=$(mktemp /tmp/bucket-policy-XXXXXX.json)
echo "${BUCKET_POLICY}" > "${TEMP_POLICY_FILE}"

run_cmd "aws s3api put-bucket-policy \\
  --bucket '${ARTIFACT_BUCKET}' \\
  --policy file://${TEMP_POLICY_FILE} \\
  --region us-east-1 ${PROFILE_FLAG}"

rm -f "${TEMP_POLICY_FILE}"

echo "Bucket policy applied."
echo ""

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
echo "--- Verification ---"
echo "Run this command to verify:"
echo ""
echo "aws s3api get-bucket-policy --bucket '${ARTIFACT_BUCKET}' --region us-east-1 ${PROFILE_FLAG} --query 'Policy' --output json"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "  Artifact Bucket Access Granted"
echo "============================================"
echo ""
echo "Bucket: ${ARTIFACT_BUCKET}"
echo "Granted to: ${FORWARDER_ROLE_ARN}"
echo ""
echo "Permissions:"
echo "  - s3:GetObject on arn:aws:s3:::${ARTIFACT_BUCKET}/*"
echo "  - s3:PutObject on arn:aws:s3:::${ARTIFACT_BUCKET}/*"
echo "  - s3:ListBucket on arn:aws:s3:::${ARTIFACT_BUCKET}"
echo ""
echo "The forwarder role can now read/write artifacts in this bucket."
echo "============================================"
