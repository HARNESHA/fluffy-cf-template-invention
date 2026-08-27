# Deployment Guide

Step-by-step guide for deploying the Terraform Pipeline Framework across
your AWS Organization.

---

## Prerequisites

### AWS Account Setup

| Requirement | Details |
|---|---|
| AWS Organization | Management account with Organizations enabled |
| Pipeline Account | Dedicated account for running pipelines (e.g., `444455556666`) |
| Repository Account(s) | Account(s) hosting CodeCommit repositories (e.g., `111122223333`) |

### Tooling

- AWS CLI v2 configured with appropriate profiles
- `jq` for JSON processing (optional but recommended)
- CloudFormation deployment capabilities (`CAPABILITY_NAMED_IAM`)

---

## Step 1: Create Buckets and IAM Roles

All infrastructure must exist before deploying CloudFormation templates.

### 1.1 Create S3 Buckets

#### Artifact Bucket (Pipeline Account)

Used by CodePipeline for storing source code, plan binaries, and build logs.

```bash
aws s3api create-bucket \
  --bucket my-org-codepipeline-artifacts-444455556666 \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket my-org-codepipeline-artifacts-444455556666 \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket my-org-codepipeline-artifacts-444455556666 \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

#### Terraform State Bucket (Target Account)

Stores Terraform remote state files.

```bash
aws s3api create-bucket \
  --bucket my-org-terraform-state-prod \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket my-org-terraform-state-prod \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket my-org-terraform-state-prod \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
```

### 1.2 Create IAM Roles

Two roles required in the **Pipeline Account**.

#### Option A: Use the Provided Script

```bash
cd org-stackset-template

# Create roles with bucket scoping
./iam/create-iam-roles.sh \
  --account-id 444455556666 \
  --region us-east-1 \
  --artifact-bucket my-org-codepipeline-artifacts-444455556666 \
  --state-bucket my-org-terraform-state-prod \
  --project '*' \
  --repo '*'

# Dry run first to review
./iam/create-iam-roles.sh \
  --account-id 444455556666 \
  --region us-east-1 \
  --dry-run
```

#### Option B: Manual Creation

```bash
# 1. Create Pipeline Role
aws iam create-role \
  --role-name TerraformPipelineServiceRole \
  --assume-role-policy-document file://iam/trust-pipeline-role.json \
  --tags Key=ManagedBy,Value=CloudFormation Key=Project,Value=TerraformPipeline

aws iam put-role-policy \
  --role-name TerraformPipelineServiceRole \
  --policy-name TerraformPipelinePolicy \
  --policy-document file://iam/permissions-pipeline-role.json

# 2. Create CodeBuild Role
aws iam create-role \
  --role-name TerraformCodeBuildRole \
  --assume-role-policy-document file://iam/trust-codebuild-role.json \
  --tags Key=ManagedBy,Value=CloudFormation Key=Project,Value=TerraformPipeline

aws iam put-role-policy \
  --role-name TerraformCodeBuildRole \
  --policy-name TerraformCodeBuildPolicy \
  --policy-document file://iam/permissions-codebuild-role.json
```

**Important:** Edit the permissions JSON files to replace placeholder values:
- `ARTIFACT_BUCKET` → your artifact bucket name
- `STATE_BUCKET` → your Terraform state bucket name
- `REGION` → your deployment region
- `ACCOUNT_ID` → your 12-digit account ID
- `PROJECT_NAME` → your project name (or `*` for all)
- `REPOSITORY_NAME` → your repo name (or `*` for all)

### 1.3 Resources Created

| Resource | Type | Account |
|---|---|---|
| `my-org-codepipeline-artifacts-*` | S3 Bucket | Pipeline |
| `my-org-terraform-state-*` | S3 Bucket | Target |
| `TerraformPipelineServiceRole` | IAM Role | Pipeline |
| `TerraformCodeBuildRole` | IAM Role | Pipeline |

Save the role ARNs — you'll need them in Step 2.

---

## Step 2: Deploy Template 1 — Pipeline Account

### 2.1 Prepare Parameter File

```bash
cp parameters/pipeline-prod.json parameters/pipeline-mypipeline.json
```

Edit `parameters/pipeline-mypipeline.json` with your values:

```json
[
  {"ParameterKey": "ProjectName", "ParameterValue": "my-project"},
  {"ParameterKey": "Environment", "ParameterValue": "prod"},
  {"ParameterKey": "RepositoryName", "ParameterValue": "my-terraform-repo"},
  {"ParameterKey": "RepositoryAccountId", "ParameterValue": "111122223333"},
  {"ParameterKey": "BranchName", "ParameterValue": "main"},
  {"ParameterKey": "TerraformDirectory", "ParameterValue": "."},
  {"ParameterKey": "BackendBucket", "ParameterValue": "my-org-terraform-state-prod"},
  {"ParameterKey": "BackendKey", "ParameterValue": "envs/prod/my-project/terraform.tfstate"},
  {"ParameterKey": "EnableApproval", "ParameterValue": "true"},
  {"ParameterKey": "PipelineRoleArn", "ParameterValue": "arn:aws:iam::444455556666:role/TerraformPipelineServiceRole"},
  {"ParameterKey": "CodeBuildRoleArn", "ParameterValue": "arn:aws:iam::444455556666:role/TerraformCodeBuildRole"},
  {"ParameterKey": "ArtifactBucket", "ParameterValue": "my-org-codepipeline-artifacts-444455556666"},
  {"ParameterKey": "NotificationEmail", "ParameterValue": "team@myorg.com"}
]
```

### 2.2 Deploy

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name my-project-prod-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-mypipeline.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --profile pipeline-account
```

### 2.3 Verify Deployment

```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].StackStatus" \
  --output text

# List all outputs
aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].Outputs" \
  --output table
```

### 2.4 Capture Event Bus ARN

```bash
EVENT_BUS_ARN=$(aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].Outputs[?OutputKey=='EventBusArn'].OutputValue" \
  --output text)

echo "Event Bus ARN: $EVENT_BUS_ARN"
```

Save this ARN — you'll need it for Step 3.

---

## Step 3: Deploy Template 2 — Repository Account

### 3.1 Prepare Forwarder Parameter File

```bash
cp parameters/forwarder.json parameters/forwarder-mypipeline.json
```

Edit `parameters/forwarder-mypipeline.json`:

```json
[
  {"ParameterKey": "RepositoryName", "ParameterValue": "my-terraform-repo"},
  {"ParameterKey": "BranchName", "ParameterValue": "main"},
  {"ParameterKey": "PipelineAccountId", "ParameterValue": "444455556666"},
  {"ParameterKey": "PipelineEventBusArn", "ParameterValue": "EVENT_BUS_ARN_FROM_STEP_2"},
  {"ParameterKey": "EnableForwarding", "ParameterValue": "true"},
  {"ParameterKey": "ForwardDeleteEvents", "ParameterValue": "false"},
  {"ParameterKey": "ProjectName", "ParameterValue": "my-project"},
  {"ParameterKey": "Environment", "ParameterValue": "prod"},
  {"ParameterKey": "Owner", "ParameterValue": "platform-engineering"},
  {"ParameterKey": "CostCenter", "ParameterValue": "CC-1042"}
]
```

### 3.2 Grant Pipeline Source Access (Repo Account)

The pipeline in the Pipeline Account must be able to pull this repository
cross-account. CodeCommit repository policies can't be created with
CloudFormation, so apply it once with the CLI in the repo account. This is the
**missing piece that causes the pipeline to fail at Source — no CodeBuild ever
runs**.

```bash
cat > /tmp/repo-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPipelineRolePullSource",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::444455556666:role/TerraformPipelineServiceRole"},
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive",
        "codecommit:CancelUploadArchive",
        "codecommit:GitPull"
      ]
    }
  ]
}
EOF

aws codecommit put-repository-policy \
  --repository-name my-terraform-repo \
  --policy-content file:///tmp/repo-policy.json \
  --region us-east-1 \
  --profile repo-account
```

Also make sure the pipeline role's `codecommit` policy targets the **repo
account**, not the pipeline account (see `iam/permissions-pipeline-role.json`,
`REPO_ACCOUNT_ID`). If your role was created with the pipeline account in that
ARN, re-run:

```bash
./iam/create-iam-roles.sh \
  --account-id 444455556666 \
  --repo-account-id 111122223333 \
  --region us-east-1 \
  --artifact-bucket my-org-codepipeline-artifacts-444455556666 \
  --state-bucket my-org-terraform-state-prod
```

### 3.3 Deploy

```bash
aws cloudformation deploy \
  --template-file templates/codecommit-event-forwarder.yaml \
  --stack-name my-repo-main-event-forwarder \
  --parameter-overrides file://parameters/forwarder-mypipeline.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --profile repo-account
```

### 3.4 Verify

```bash
aws cloudformation describe-stacks \
  --stack-name my-repo-main-event-forwarder \
  --query "Stacks[0].Outputs" \
  --output table
```

---

## Step 4: Configure the Terraform Repository

### 4.1 Copy Buildspec Files

Copy both buildspec files to the **root** of your Terraform repository:

```bash
cp buildspec/buildspec-plan.yml /path/to/your-terraform-repo/
cp buildspec/buildspec-apply.yml /path/to/your-terraform-repo/
```

### 4.2 Commit and Push

```bash
cd /path/to/your-terraform-repo
git add buildspec-plan.yml buildspec-apply.yml
git commit -m "Add CI/CD buildspecs for pipeline"
git push origin main
```

The pipeline triggers automatically on push.

---

## Step 5: Verify the Pipeline

### 5.1 Check Pipeline Execution

```bash
PIPELINE_NAME=$(aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].Outputs[?OutputKey=='PipelineName'].OutputValue" \
  --output text)

aws codepipeline list-executions \
  --pipeline-name "$PIPELINE_NAME" \
  --max-results 5 \
  --query "executions[].{id:executionId,status:status,started:startDate}" \
  --output table
```

### 5.2 Open Pipeline Console

```
https://us-east-1.console.aws.amazon.com/codesuite/codepipeline/pipelines/${PIPELINE_NAME}/view
```

### 5.3 Check Build Logs (if issues)

```bash
aws codebuild list-builds-for-project \
  --project-name "my-project-prod-tf-plan" \
  --query "ids[:5]" \
  --output text
```

---

## Day-2 Operations

### Updating Terraform Version

Update `TerraformVersion` in your parameter file and redeploy:

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name my-project-prod-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-mypipeline.json \
  --capabilities CAPABILITY_NAMED_IAM
```

### Toggling Approval Gate

Change `EnableApproval` in your parameter file:

```json
{"ParameterKey": "EnableApproval", "ParameterValue": "false"}
```

Then redeploy the stack.

### Adding a New Repository

1. Apply the CodeCommit repository policy for the new repo (Step 3.2)
2. Deploy Template 2 in the repository account with the new repo details
3. Copy buildspec files to the new repository
4. Push to trigger the pipeline

### Pausing Event Forwarding

Set `EnableForwarding` to `false` and redeploy Template 2.

---

## Troubleshooting

| Issue | Check |
|---|---|
| Pipeline fails, CodeBuild never runs | **Cross-account Source stage**: repo account must have a CodeCommit repository policy (`put-repository-policy`) granting the pipeline role, and the pipeline role's codecommit policy must target the repo account's ARN |
| Rule invoked but pipeline not triggered | **Missing `codepipeline:StartPipelineExecution`** on the pipeline role. Rule runs handshake with this role, but `StartPipelineExecution` fails with AccessDenied |
| Pipeline not triggering at all | EventBridge rule is ENABLED, IAM role has `events:PutEvents`, bus policy allows repo account |
| Plan fails | CodeBuild logs, S3 state bucket access, Terraform version validity |
| Apply fails | Plan binary in artifacts, execution role trust policy, execution role permissions |
| SNS not received | Topic ARN correct, email subscription confirmed, EventBridge rule logging |

### Fix: Rule invoked but pipeline not triggered

The pipeline role needs `codepipeline:StartPipelineExecution` for EventBridge to start the pipeline:

```bash
cat > /tmp/codepipeline-start.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodePipelineStartExecution",
      "Effect": "Allow",
      "Action": "codepipeline:StartPipelineExecution",
      "Resource": "arn:aws:codepipeline:us-east-1:444455556666:my-project-prod-*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name TerraformPipelineServiceRole \
  --policy-name CodePipelineStartExecution \
  --policy-document file:///tmp/codepipeline-start.json
```

Verify the rule sees the fix:

```bash
# Confirm the event reached the rule and the invocation result
aws events list-rule-names-by-target \
  --target-arn "arn:aws:codepipeline:us-east-1:444455556666:my-project-prod-main-tf-pipeline"

# Watch the rule's invocations in CloudWatch (Metrics → events → InvokedInvocations)
```

### Fix: Pipeline fails at Source, CodeBuild never runs

This is a **cross-account authorization gap**. The pipeline (account 444455556666)
cannot pull the CodeCommit repo (account 111122223333) because neither side grants
access. Fix both sides:

**Side 1 — Repo account: CodeCommit repository policy**

Apply the repository policy with the CLI (CloudFormation has no CodeCommit
repository-policy resource):

```bash
cat > /tmp/repo-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPipelineRolePullSource",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::444455556666:role/TerraformPipelineServiceRole"},
      "Action": [
        "codecommit:GetBranch",
        "codecommit:GetCommit",
        "codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus",
        "codecommit:UploadArchive",
        "codecommit:CancelUploadArchive",
        "codecommit:GitPull"
      ]
    }
  ]
}
EOF

aws codecommit put-repository-policy \
  --repository-name my-terraform-repo \
  --policy-content file:///tmp/repo-policy.json \
  --region us-east-1 \
  --profile repo-account
```

**Side 2 — Pipeline account: role policy targets the repo account**

The pipeline role's `codecommit` Resource ARN must reference the **repo account**,
not the pipeline account:

```json
"Resource": "arn:aws:codecommit:us-east-1:111122223333:my-terraform-repo"
```

If your role still scopes it to `444455556666` (or uses `REPO_ACCOUNT_ID` with
the pipeline account filled in), fix it by adding `codecommit:GetRepository` and
`codecommit:GitPull` too:

```bash
aws iam put-role-policy \
  --role-name TerraformPipelineServiceRole \
  --policy-name CodeCommitCrossAccountSource \
  --policy-document file:///tmp/codecommit-cross-account.json
```

Alternatively, re-run `./iam/create-iam-roles.sh` with `--repo-account-id 111122223333`.

---

## Deployment Order Summary

```
Step 1: Create Buckets + IAM Roles
         ├── Artifact Bucket (Pipeline Account)
         ├── State Bucket (Target Account)
         ├── TerraformPipelineServiceRole
         └── TerraformCodeBuildRole
              │
              ▼
Step 2: Deploy Template 1 (Pipeline Account)
         └── Capture Event Bus ARN
              │
              ▼
Step 3: Deploy Template 2 (Repository Account)
         └── Uses Event Bus ARN from Step 2
              │
              ▼
Step 4: Copy Buildspecs to Terraform Repo
         └── Push triggers pipeline
              │
              ▼
Step 5: Verify Pipeline Execution
```
