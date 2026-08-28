#!/usr/bin/env bash
# =============================================================================
# create-iam-roles.sh
# Creates IAM roles required for the Terraform Pipeline Framework.
#
# Usage:
#   ./iam/create-iam-roles.sh --account-id 444455556666 --region us-east-1
#
# This script creates:
#   1. TerraformPipelineServiceRole  — CodePipeline service role
#   2. TerraformCodeBuildRole        — CodeBuild service role (Plan + Apply)
#
# Roles are created at the IAM root path by default. Use --role-path to place
# them under a team/org path (e.g. --role-path /xyz/). The resulting ARNs then
# include the path: arn:aws:iam::<acct>:role/xyz/<role-name>
#
# The Execution Role is NOT created here — it lives in the target account
# and trusts the CodeBuild role. See trust-execution-role.json for the
# trust policy template.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ACCOUNT_ID=""
REPO_ACCOUNT_ID=""
REGION="us-east-1"
PIPELINE_ROLE_NAME="TerraformPipelineServiceRole"
CODEBUILD_ROLE_NAME="TerraformCodeBuildRole"
ARTIFACT_BUCKET=""
STATE_BUCKET=""
PROJECT_NAME="*"
REPOSITORY_NAME="*"
ROLE_PATH=""
DRY_RUN=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --account-id)    ACCOUNT_ID="$2";    shift 2 ;;
    --repo-account-id) REPO_ACCOUNT_ID="$2"; shift 2 ;;
    --region)        REGION="$2";        shift 2 ;;
    --pipeline-role) PIPELINE_ROLE_NAME="$2"; shift 2 ;;
    --codebuild-role) CODEBUILD_ROLE_NAME="$2"; shift 2 ;;
    --artifact-bucket) ARTIFACT_BUCKET="$2"; shift 2 ;;
    --state-bucket)  STATE_BUCKET="$2";  shift 2 ;;
    --project)       PROJECT_NAME="$2";  shift 2 ;;
    --repo)          REPOSITORY_NAME="$2"; shift 2 ;;
    --role-path)     ROLE_PATH="$2";     shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    --help)
      echo "Usage: $0 --account-id <id> --region <region> [options]"
      echo ""
      echo "Required:"
      echo "  --account-id       AWS Account ID of the Pipeline Account (12 digits)"
      echo ""
      echo "Optional:"
      echo "  --repo-account-id  AWS Account ID of the CodeCommit repo (default: same as --account-id)"
      echo "  --region           AWS region (default: us-east-1)"
      echo "  --pipeline-role    Pipeline role name (default: TerraformPipelineServiceRole)"
      echo "  --codebuild-role   CodeBuild role name (default: TerraformCodeBuildRole)"
      echo "  --artifact-bucket  S3 bucket for CodePipeline artifacts"
      echo "  --state-bucket     S3 bucket for Terraform state"
      echo "  --project          Project name filter (default: *)"
      echo "  --repo             Repository name filter (default: *)"
      echo "  --role-path        IAM role path for team/org segregation, e.g. --role-path /xyz/ (default: root)"
      echo "  --dry-run          Print commands without executing"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: --account-id is required"
  exit 1
fi

if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: --account-id must be a 12-digit number"
  exit 1
fi

# Repo account defaults to the pipeline account for same-account repos
if [[ -z "$REPO_ACCOUNT_ID" ]]; then
  REPO_ACCOUNT_ID="$ACCOUNT_ID"
fi

# IAM path: empty (root) or must start AND end with "/", no spaces,
# no duplicate slashes, max 512 chars (AWS IAM limit).
if [[ -n "$ROLE_PATH" ]]; then
  if [[ "$ROLE_PATH" == "/" ]]; then
    # A single slash is the root path — treat as empty to avoid "role//Name"
    ROLE_PATH=""
  elif [[ ! "$ROLE_PATH" =~ ^/[a-zA-Z0-9._=,@+-]+(/[a-zA-Z0-9._=,@+-]+)*/$ ]]; then
    echo "ERROR: --role-path must start and end with '/' and contain only [a-zA-Z0-9._=,@+-]"
    echo "Example: --role-path /xyz/ or --role-path /teams/sre/"
    exit 1
  fi
fi

echo "============================================"
echo "  Creating IAM Roles for Terraform Pipeline"
echo "============================================"
echo "Account ID       : $ACCOUNT_ID"
echo "Repo Account ID  : $REPO_ACCOUNT_ID"
echo "Region          : $REGION"
echo "Role Path       : ${ROLE_PATH:-/ (root)}"
echo "Pipeline Role   : $PIPELINE_ROLE_NAME"
echo "CodeBuild Role  : $CODEBUILD_ROLE_NAME"
echo "Artifact Bucket : ${ARTIFACT_BUCKET:-<not set>}"
echo "State Bucket    : ${STATE_BUCKET:-<not set>}"
echo "Project Filter  : $PROJECT_NAME"
echo "Repo Filter     : $REPOSITORY_NAME"
echo "Dry Run         : $DRY_RUN"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Helper function
# ---------------------------------------------------------------------------
run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $*"
  else
    echo "Running: $*"
    eval "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Create Pipeline Role
# ---------------------------------------------------------------------------
echo "--- Creating Pipeline Role: $PIPELINE_ROLE_NAME ---"

# Create the role with trust policy
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCodePipelineAssume",
      "Effect": "Allow",
      "Principal": { "Service": "codepipeline.amazonaws.com" },
      "Action": "sts:AssumeRole"
    },
    {
      "Sid": "AllowEventBridgeAssume",
      "Effect": "Allow",
      "Principal": { "Service": "events.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

if [[ -n "$ROLE_PATH" ]]; then
  PIPELINE_ROLE_PATH="--path '$ROLE_PATH'"
else
  PIPELINE_ROLE_PATH=""
fi

run_cmd "aws iam create-role \\
  $PIPELINE_ROLE_PATH \\
  --role-name '$PIPELINE_ROLE_NAME' \\
  --assume-role-policy-document '$TRUST_POLICY' \\
  --description 'Service role for Terraform CodePipeline' \\
  --tags Key=ManagedBy,Value=CloudFormation Key=Project,Value=TerraformPipeline"

# Build permissions policy with actual values
PIPELINE_PERMISSIONS=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ArtifactAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:GetBucketVersioning",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${ARTIFACT_BUCKET:-*}",
        "arn:aws:s3:::${ARTIFACT_BUCKET:-*}/*"
      ]
    },
    {
      "Sid": "CodeCommitAccess",
      "Effect": "Allow",
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive",
        "codecommit:CancelUploadArchive",
        "codecommit:GitPull"
      ],
      "Resource": "arn:aws:codecommit:${REGION}:${REPO_ACCOUNT_ID}:${REPOSITORY_NAME}"
    },
    {
      "Sid": "CodePipelineStartExecution",
      "Effect": "Allow",
      "Action": "codepipeline:StartPipelineExecution",
      "Resource": "arn:aws:codepipeline:${REGION}:${ACCOUNT_ID}:${PROJECT_NAME}-*"
    },
    {
      "Sid": "CodeBuildAccess",
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "codebuild:StopBuild"
      ],
      "Resource": "arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:project/${PROJECT_NAME}-*"
    },
    {
      "Sid": "EventBridgeAccess",
      "Effect": "Allow",
      "Action": "events:PutEvents",
      "Resource": "arn:aws:events:${REGION}:${ACCOUNT_ID}:event-bus/${PROJECT_NAME}-*"
    },
    {
      "Sid": "SNSAccess",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT_NAME}-*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/codepipeline/${PROJECT_NAME}-*:*"
    }
  ]
}
EOF
)

run_cmd "aws iam put-role-policy \\
  --role-name '$PIPELINE_ROLE_NAME' \\
  --policy-name 'TerraformPipelinePolicy' \\
  --policy-document '$PIPELINE_PERMISSIONS'"

echo "Pipeline role created."
echo ""

# ---------------------------------------------------------------------------
# 2. Create CodeBuild Role
# ---------------------------------------------------------------------------
echo "--- Creating CodeBuild Role: $CODEBUILD_ROLE_NAME ---"

CODEBUILD_TRUST=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCodeBuildAssume",
      "Effect": "Allow",
      "Principal": { "Service": "codebuild.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)

run_cmd "aws iam create-role \\
  $PIPELINE_ROLE_PATH \\
  --role-name '$CODEBUILD_ROLE_NAME' \\
  --assume-role-policy-document '$CODEBUILD_TRUST' \\
  --description 'Service role for Terraform CodeBuild (Plan + Apply)' \\
  --tags Key=ManagedBy,Value=CloudFormation Key=Project,Value=TerraformPipeline"

CODEBUILD_PERMISSIONS=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ArtifactAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:GetBucketVersioning",
        "s3:ListBucket",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${ARTIFACT_BUCKET:-*}",
        "arn:aws:s3:::${ARTIFACT_BUCKET:-*}/*"
      ]
    },
    {
      "Sid": "S3TerraformStateAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET:-*}",
        "arn:aws:s3:::${STATE_BUCKET:-*}/*"
      ]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/codebuild/${PROJECT_NAME}-*:*"
    },
    {
      "Sid": "STSAssumeRole",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/TerraformExecutionRole-*"
    },
    {
      "Sid": "SNSPublish",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${PROJECT_NAME}-*"
    },
    {
      "Sid": "SSMParameterAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters"
      ],
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/${PROJECT_NAME}/*"
    }
  ]
}
EOF
)

run_cmd "aws iam put-role-policy \\
  --role-name '$CODEBUILD_ROLE_NAME' \\
  --policy-name 'TerraformCodeBuildPolicy' \\
  --policy-document '$CODEBUILD_PERMISSIONS'"

echo "CodeBuild role created."
echo ""

# ---------------------------------------------------------------------------
# 3. Create Execution Role (optional - template only)
# ---------------------------------------------------------------------------
echo "--- Execution Role ---"
echo "The Execution Role is NOT created by this script."
echo "It should be created in the target account with the trust policy from:"
echo "  iam/trust-execution-role.json"
echo ""
echo "Replace ACCOUNT_ID with: $ACCOUNT_ID"
echo "Replace PROJECT_NAME with your project name."
if [[ -n "$ROLE_PATH" ]]; then
  echo "If roles live under a path, include it in ARNs (e.g. arn:aws:iam::${ACCOUNT_ID}:role${ROLE_PATH}PROJECT_NAME)."
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ROLE_ARN_PREFIX="arn:aws:iam::${ACCOUNT_ID}:role${ROLE_PATH}"
echo "============================================"
echo "  IAM Roles Created Successfully"
echo "============================================"
echo ""
echo "Roles created:"
echo "  1. $PIPELINE_ROLE_NAME"
echo "     ARN: ${ROLE_ARN_PREFIX}${PIPELINE_ROLE_NAME}"
echo ""
echo "  2. $CODEBUILD_ROLE_NAME"
echo "     ARN: ${ROLE_ARN_PREFIX}${CODEBUILD_ROLE_NAME}"
echo ""
echo "Next steps:"
echo "  1. Apply the CodeCommit repository policy for cross-account Source"
echo "     access (see docs/deployment-guide.md Step 3.2 - put-repository-policy)."
echo "  2. Create Execution Roles in target accounts (optional)."
echo "  3. Deploy Template 1 with these role ARNs (path included):"
echo "     ARN format: arn:aws:iam::<acct>:role${ROLE_PATH}<role-name>"
echo "============================================"
