# Terraform CI/CD Pipeline Platform

Enterprise-grade Terraform deployment pipeline using AWS CodePipeline, CodeBuild, S3 backend, and native Terraform lockfile support.

## Architecture

```
Terraform CodeCommit Repo
         |
    CodePipeline
         |
    +----+----+
    |         |
  Source   Validate + Plan
    |         |
    |    Manual Approval
    |         |
    |    Terraform Apply
    |         |
    +----+----+
         |
    AWS Infrastructure
         |
    S3 Backend (Lockfile)
```

**Pipeline Stages:**
1. **Source** - Pull Terraform code from CodeCommit
2. **Validate + Plan** - Install Terraform, validate, format check, plan, export tfplan artifact
3. **Manual Approval** - Approve/reject with optional SNS email notification
4. **Apply** - Apply approved immutable tfplan

**Key Design Decisions:**
- Single CloudFormation stack, single pipeline
- One reusable buildspec controlled by `TF_ACTION` environment variable
- Native S3 lockfile (no DynamoDB)
- Immutable tfplan artifact between plan and apply
- Cross-account deployment support via optional STS assume role

## Repository Structure

```
platform-repo/
├── cloudformation/
│   └── terraform-pipeline.yaml    # Main CFN template
├── buildspec/
│   └── buildspec.yml             # Reusable buildspec
├── scripts/
│   ├── install-terraform.sh       # Terraform installation
│   ├── generate-backend.sh        # Backend HCL generation
│   ├── validate-terraform-version.sh  # Version validation
│   └── assume-role.sh             # Cross-account STS
└── README.md
```

## Terraform Repository Structure

```
terraform-repo/
├── environments/
│   ├── dev.tfvars
│   ├── qa.tfvars
│   ├── uat.tfvars
│   └── prod.tfvars
├── modules/
├── main.tf
├── variables.tf
├── outputs.tf
├── providers.tf
├── versions.tf
└── backend.tf              # Declared but NOT fully configured
                            # Backend config is injected at pipeline runtime
```

## Deployment

### Prerequisites

1. AWS CLI installed and configured
2. CodeCommit repository with Terraform code
3. S3 bucket names (globally unique)

### Deploy Pipeline

```bash
aws cloudformation deploy \
    --template-file cloudformation/terraform-pipeline.yaml \
    --stack-name myproject-dev-tf-pipeline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ProjectName=myproject \
        EnvironmentName=dev \
        TerraformRepoName=my-terraform-repo \
        TerraformRepoBranch=main \
        TerraformVersion=1.10.5 \
        ArtifactBucketName=myproject-dev-tf-artifacts \
        BackendBucketName=myproject-dev-tf-state \
        EnableManualApproval=Yes \
        NotificationEmail=team@example.com \
        CodeBuildComputeType=BUILD_GENERAL1_SMALL \
        BuildImage=aws/codebuild/amazonlinux2-x86_64-standard:5.0 \
        TargetAccountId= \
        TargetRoleArn= \
        TerraformRootPath=.
```

### Cross-Account Deployment

```bash
aws cloudformation deploy \
    --template-file cloudformation/terraform-pipeline.yaml \
    --stack-name myproject-prod-tf-pipeline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ProjectName=myproject \
        EnvironmentName=prod \
        TerraformRepoName=my-terraform-repo \
        TargetAccountId=123456789012 \
        TargetRoleArn=arn:aws:iam::123456789012:role/terraform-deployment-role
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| ProjectName | - | Project identifier for resource naming |
| EnvironmentName | dev | Environment: dev, qa, uat, prod |
| TerraformRepoName | - | CodeCommit repository name |
| TerraformRepoBranch | main | Branch to deploy from |
| TerraformVersion | 1.10.5 | Terraform version to install |
| ArtifactBucketName | - | Pipeline artifacts bucket |
| BackendBucketName | - | Terraform state bucket |
| EnableManualApproval | Yes | Enable approval stage |
| NotificationEmail | - | SNS email (empty = disabled) |
| CodeBuildComputeType | BUILD_GENERAL1_SMALL | Build compute size |
| BuildImage | amazonlinux2-x86_64-standard:5.0 | CodeBuild image |
| TargetAccountId | - | Cross-account target (empty = same account) |
| TargetRoleArn | - | Cross-account role ARN |
| TerraformRootPath | . | Path to Terraform root in repo |

## Security

- **Least privilege IAM** - No AdministratorAccess, scoped per-service policies
- **Immutable artifacts** - Plan generates tfplan, apply uses same approved plan
- **Encrypted state** - SSE-S3 encryption on backend bucket
- **TLS enforcement** - Deny non-HTTPS requests to S3 buckets
- **Public access blocked** - All S3 buckets have public access blocks
- **Versioned state** - Backend bucket has versioning enabled
- **Audit trail** - CloudWatch Logs for all build and pipeline activity
- **Optional approval** - Manual gate between plan and apply

## Native Lockfile (.tflock)

Terraform 1.10+ supports native S3 locking using `.tflock` files instead of DynamoDB.

### How it works

1. When `terraform apply` runs, it creates a `.tflock` file in the S3 backend path
2. The lock file contains the lock ID, operation info, and timestamp
3. Other operations check for the lock file before proceeding
4. When the operation completes, the lock file is deleted

### Lock Acquisition

```
terraform plan / apply
  -> S3 HeadObject check for .tflock
  -> If no lock: write .tflock with lock metadata
  -> If locked: retry with backoff
  -> Execute operation
  -> Delete .tflock on completion
```

### Concurrent Execution Prevention

- Terraform checks for existing lock before acquiring
- Lock file contains caller identity for accountability
- Backoff retry prevents thundering herd
- Pipeline stages run sequentially (Plan -> Approval -> Apply)
- Single pipeline ensures only one execution at a time per environment

### Force Unlock

If a lock is stale (e.g., from a failed build that didn't clean up):

```bash
terraform force-unlock -force LOCK_ID
```

Find the lock ID from the error message or S3:

```bash
aws s3 ls s3://myproject-dev-tf-state/env:/dev/.tflock
```

### Lock File Location

```
s3://<backend-bucket>/<state-key>.tflock

Example:
s3://myproject-dev-tf-state/myproject/dev/terraform.tfstate.tflock
```

## Pipeline Walkthrough

1. **Developer commits code** to the `main` branch of the Terraform CodeCommit repo
2. **EventBridge triggers** the CodePipeline automatically
3. **Source stage** downloads the Terraform code to an artifact
4. **Plan stage** (CodeBuild): installs Terraform, validates version, runs `fmt`, `validate`, `init`, `plan`, exports `tfplan`
5. **Approval stage** pauses and sends SNS notification (if configured)
6. **Approver reviews** the plan output and approves
7. **Apply stage** (CodeBuild): downloads the same `tfplan`, runs `init`, `apply` with the approved plan
8. **Infrastructure is deployed** exactly as planned

## Troubleshooting

### Pipeline Fails at Plan Stage

```
Check CloudWatch Logs: /aws/codebuild/<project>-<env>-tf
```

Common issues:
- Terraform syntax errors in the repo
- Missing `environments/<env>.tfvars` file
- S3 backend bucket inaccessible
- Terraform version < 1.10

### Pipeline Fails at Apply Stage

```
Check CloudWatch Logs: /aws/codebuild/<project>-<env>-tf
```

Common issues:
- `tfplan` not found (PlanArtifact issue)
- State lock from previous failed run (`terraform force-unlock`)
- IAM permissions insufficient for the target account

### Stale State Lock

```bash
# List lock files
aws s3 ls s3://<backend-bucket>/<prefix>/

# Force unlock
terraform force-unlock -force <lock-id>
```

## Best Practices

- Use separate pipeline stacks per environment (dev, qa, uat, prod)
- Use separate CodeCommit branches mapped to environments
- Review plan output in CodeBuild logs before approving
- Enable SNS notifications for production approvals
- Store sensitive variables in AWS Systems Manager Parameter Store
- Tag all infrastructure for cost allocation
- Keep Terraform modules small and focused
- Use remote state for all workspaces

## License

Copyright 2024. All rights reserved.
# fluffy-cf-template-invention
