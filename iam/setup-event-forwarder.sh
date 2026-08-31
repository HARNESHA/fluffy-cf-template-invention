#!/usr/bin/env bash
# =============================================================================
# setup-event-forwarder.sh
# Creates EventBridge forwarding infrastructure in the REPOSITORY ACCOUNT.
#
# This script replaces the former codecommit-event-forwarder.yaml template.
# It creates exactly 2 resources:
#   1. IAM Role  — allows EventBridge to PutEvents to the pipeline account
#   2. EventBridge Rule — captures CodeCommit pushes and forwards them
#
# The role is GENERIC: events:PutEvents on arn:aws:events:*:<pipeline-acct>:event-bus/*
# One role per repo account serves all pipelines. Only the rule is per-repo/branch.
#
# Prerequisites:
#   - Pipeline stack (Template 1) already deployed
#   - EventBusArn captured from stack output
#   - AWS CLI configured with appropriate profile/credentials
#
# Usage:
#   ./iam/setup-event-forwarder.sh \
#     --pipeline-account-id 444455556666 \
#     --event-bus-arn "arn:aws:events:us-east-1:444455556666:event-bus/my-project-dev-terraform-pipeline-bus" \
#     --repository-name my-terraform-repo \
#     --branch-name main \
#     --region us-east-1 \
#     --profile repo-account
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PIPELINE_ACCOUNT_ID=""
EVENT_BUS_ARN=""
REPO_ACCOUNT_ID=""
REPOSITORY_NAME=""
BRANCH_NAME="main"
REGION="us-east-1"
ROLE_NAME=""
ENABLE_DELETE_EVENTS=false
DRY_RUN=false
PROFILE=""

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --pipeline-account-id) PIPELINE_ACCOUNT_ID="$2"; shift 2 ;;
    --event-bus-arn)       EVENT_BUS_ARN="$2";       shift 2 ;;
    --repo-account-id)     REPO_ACCOUNT_ID="$2";     shift 2 ;;
    --repository-name)     REPOSITORY_NAME="$2";     shift 2 ;;
    --branch-name)         BRANCH_NAME="$2";         shift 2 ;;
    --region)              REGION="$2";              shift 2 ;;
    --role-name)           ROLE_NAME="$2";           shift 2 ;;
    --enable-delete-events) ENABLE_DELETE_EVENTS=true; shift ;;
    --dry-run)             DRY_RUN=true;             shift ;;
    --profile)             PROFILE="$2";             shift 2 ;;
    --help)
      echo "Usage: $0 --pipeline-account-id <id> --event-bus-arn <arn> --repository-name <name> [options]"
      echo ""
      echo "Required:"
      echo "  --pipeline-account-id   AWS Account ID of the Pipeline Account (12 digits)"
      echo "  --event-bus-arn         Full ARN of the target EventBridge bus (from stack output)"
      echo "  --repository-name       CodeCommit repository name"
      echo ""
      echo "Optional:"
      echo "  --repo-account-id       Repository account ID (default: current account)"
      echo "  --branch-name           Branch to monitor (default: main)"
      echo "  --region                AWS region (default: us-east-1)"
      echo "  --role-name             Forwarder role name (default: <repo>-event-forwarder-role)"
      echo "  --enable-delete-events  Also forward referenceDeleted events"
      echo "  --dry-run               Print commands without executing"
      echo "  --profile               AWS CLI profile for repo account"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ -z "$PIPELINE_ACCOUNT_ID" ]]; then
  echo "ERROR: --pipeline-account-id is required"
  exit 1
fi
if [[ ! "$PIPELINE_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: --pipeline-account-id must be a 12-digit number"
  exit 1
fi

if [[ -z "$EVENT_BUS_ARN" ]]; then
  echo "ERROR: --event-bus-arn is required"
  exit 1
fi
if [[ ! "$EVENT_BUS_ARN" =~ ^arn:aws:events:.+: ]]; then
  echo "ERROR: --event-bus-arn must be a valid EventBridge Event Bus ARN"
  exit 1
fi

if [[ -z "$REPOSITORY_NAME" ]]; then
  echo "ERROR: --repository-name is required"
  exit 1
fi

# Default role name
if [[ -z "$ROLE_NAME" ]]; then
  ROLE_NAME="${REPOSITORY_NAME}-${BRANCH_NAME}-event-forwarder-role"
fi

# Get repo account ID from current identity if not provided
if [[ -z "$REPO_ACCOUNT_ID" ]]; then
  PROFILE_FLAG=""
  if [[ -n "$PROFILE" ]]; then
    PROFILE_FLAG="--profile $PROFILE"
  fi
  REPO_ACCOUNT_ID=$(aws sts get-caller-identity $PROFILE_FLAG --query 'Account' --output text 2>/dev/null || echo "")
  if [[ -z "$REPO_ACCOUNT_ID" ]]; then
    echo "ERROR: --repo-account-id is required (could not detect from current identity)"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Display configuration
# ---------------------------------------------------------------------------
echo "============================================"
echo "  Setup Event Forwarder (Repository Account)"
echo "============================================"
echo "Pipeline Account  : $PIPELINE_ACCOUNT_ID"
echo "Repo Account      : $REPO_ACCOUNT_ID"
echo "Region            : $REGION"
echo "Repository        : $REPOSITORY_NAME"
echo "Branch            : $BRANCH_NAME"
echo "Role Name         : $ROLE_NAME"
echo "Target Bus ARN    : $EVENT_BUS_ARN"
echo "Delete Events     : $ENABLE_DELETE_EVENTS"
echo "Dry Run           : $DRY_RUN"
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
# 1. Create IAM Role — EventBridge Cross-Account PutEvents
# ---------------------------------------------------------------------------
echo "--- Creating IAM Role: $ROLE_NAME ---"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEventBridgeAssume",
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${REPO_ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF
)

run_cmd "aws iam create-role \\
  --role-name '${ROLE_NAME}' \\
  --assume-role-policy-document '${TRUST_POLICY}' \\
  --description 'Allows EventBridge to forward CodeCommit events to pipeline account Event Bus' \\
  --tags Key=ManagedBy,Value=CLI Key=Project,Value=TerraformPipeline Key=Repository,Value='${REPOSITORY_NAME}' Key=Branch,Value='${BRANCH_NAME}' \\
  --region '${REGION}' ${PROFILE_FLAG}"

# Generic permissions: events:PutEvents on ALL buses in the pipeline account
PUT_EVENTS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PutEventsToPipelineAccountBuses",
      "Effect": "Allow",
      "Action": [
        "events:PutEvents"
      ],
      "Resource": "arn:aws:events:*:${PIPELINE_ACCOUNT_ID}:event-bus/*"
    }
  ]
}
EOF
)

run_cmd "aws iam put-role-policy \\
  --role-name '${ROLE_NAME}' \\
  --policy-name 'PutEventsToPipelineBuses' \\
  --policy-document '${PUT_EVENTS_POLICY}' \\
  --region '${REGION}' ${PROFILE_FLAG}"

echo "IAM Role created."
echo ""

# ---------------------------------------------------------------------------
# 2. Create EventBridge Rule — Forward CodeCommit Events
# ---------------------------------------------------------------------------
echo "--- Creating EventBridge Rule ---"

RULE_NAME="${REPOSITORY_NAME}-${BRANCH_NAME}-codecommit-forwarder"

# Build event pattern based on delete events flag
if [[ "$ENABLE_DELETE_EVENTS" == "true" ]]; then
  EVENT_PATTERN=$(cat <<EOF
{
  "source": ["aws.codecommit"],
  "detail-type": ["CodeCommit Repository State Change"],
  "resources": ["arn:aws:codecommit:${REGION}:${REPO_ACCOUNT_ID}:${REPOSITORY_NAME}"],
  "detail": {
    "repositoryName": ["${REPOSITORY_NAME}"],
    "referenceType": ["branch"],
    "referenceName": ["${BRANCH_NAME}"],
    "event": ["referenceCreated", "referenceUpdated", "referenceDeleted"]
  }
}
EOF
)
else
  EVENT_PATTERN=$(cat <<EOF
{
  "source": ["aws.codecommit"],
  "detail-type": ["CodeCommit Repository State Change"],
  "resources": ["arn:aws:codecommit:${REGION}:${REPO_ACCOUNT_ID}:${REPOSITORY_NAME}"],
  "detail": {
    "repositoryName": ["${REPOSITORY_NAME}"],
    "referenceType": ["branch"],
    "referenceName": ["${BRANCH_NAME}"],
    "event": ["referenceCreated", "referenceUpdated"]
  }
}
EOF
)
fi

# Get the role ARN for the target
ROLE_ARN="arn:aws:iam::${REPO_ACCOUNT_ID}:role/${ROLE_NAME}"

run_cmd "aws events put-rule \\
  --name '${RULE_NAME}' \\
  --description 'Forwards CodeCommit push events from ${REPOSITORY_NAME}/${BRANCH_NAME} to pipeline account' \\
  --event-pattern '${EVENT_PATTERN}' \\
  --state ENABLED \\
  --region '${REGION}' ${PROFILE_FLAG}"

# Add the target — forwards to the pipeline account bus via the role
run_cmd "aws events put-targets \\
  --rule '${RULE_NAME}' \\
  --region '${REGION}' ${PROFILE_FLAG} \\
  --targets '[{\"Id\":\"PipelineAccountEventBus\",\"Arn\":\"${EVENT_BUS_ARN}\",\"RoleArn\":\"${ROLE_ARN}\"}]'"

echo "EventBridge Rule created."
echo ""

# ---------------------------------------------------------------------------
# 3. Verify
# ---------------------------------------------------------------------------
echo "--- Verification ---"
echo "Run these commands to verify the setup:"
echo ""
echo "# Check IAM role exists:"
echo "aws iam get-role --role-name '${ROLE_NAME}' --region '${REGION}' ${PROFILE_FLAG}"
echo ""
echo "# Check role policy:"
echo "aws iam get-role-policy --role-name '${ROLE_NAME}' --policy-name 'PutEventsToPipelineBuses' --region '${REGION}' ${PROFILE_FLAG}"
echo ""
echo "# Check EventBridge rule:"
echo "aws events describe-rule --name '${RULE_NAME}' --region '${REGION}' ${PROFILE_FLAG}"
echo ""
echo "# Check rule targets:"
echo "aws events list-targets-by-rule --rule '${RULE_NAME}' --region '${REGION}' ${PROFILE_FLAG}"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ROLE_ARN_OUT="arn:aws:iam::${REPO_ACCOUNT_ID}:role/${ROLE_NAME}"
RULE_ARN_OUT="arn:aws:events:${REGION}:${REPO_ACCOUNT_ID}:rule/${RULE_NAME}"

echo "============================================"
echo "  Event Forwarder Setup Complete"
echo "============================================"
echo ""
echo "Resources created:"
echo "  1. IAM Role: ${ROLE_NAME}"
echo "     ARN: ${ROLE_ARN_OUT}"
echo "     Permissions: events:PutEvents on arn:aws:events:*:${PIPELINE_ACCOUNT_ID}:event-bus/*"
echo ""
echo "  2. EventBridge Rule: ${RULE_NAME}"
echo "     ARN: ${RULE_ARN_OUT}"
echo "     Source: ${REPOSITORY_NAME}/${BRANCH_NAME}"
echo "     Target: ${EVENT_BUS_ARN}"
echo ""
echo "Next steps:"
echo "  1. Grant the forwarder role access to the artifact bucket:"
echo "     ./iam/grant-artifact-access.sh \\"
echo "       --artifact-bucket <ARTIFACT_BUCKET> \\"
echo "       --forwarder-role-arn '${ROLE_ARN_OUT}' \\"
echo "       --pipeline-account-id '${PIPELINE_ACCOUNT_ID}'"
echo ""
echo "  2. Grant the pipeline role cross-account CodeCommit access:"
echo "     (see docs/deployment-guide.md Step 4)"
echo ""
echo "  3. Copy buildspecs to the Terraform repository:"
echo "     cp buildspec/buildspec-plan.yml /path/to/repo/"
echo "     cp buildspec/buildspec-apply.yml /path/to/repo/"
echo "============================================"
