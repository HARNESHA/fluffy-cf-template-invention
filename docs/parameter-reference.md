# Parameter Reference

Complete reference for all parameters for the CloudFormation template.

---

## Template 1 — terraform-pipeline-framework.yaml

### Group 1: Project Identity

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `ProjectName` | String | Yes | — | `^[a-z0-9][a-z0-9\-]{1,28}[a-z0-9]$` | Short lowercase identifier. Used as prefix on all resource names. Example: `payments-infra` |
| `PipelineName` | String | No | `""` (auto) | Any string | Explicit pipeline name. Leave blank to auto-generate as `{project}-{env}-{branch}-tf-pipeline` |
| `Environment` | String | Yes | `dev` | `dev`, `test`, `staging`, `prod`, `shared` | Environment label used in resource naming and all tags |

### Group 2: Source Repository

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `RepositoryName` | String | Yes | — | `^[a-zA-Z0-9._\-]{1,100}$` | CodeCommit repository name. Must already exist in the repository account |
| `RepositoryAccountId` | String | Yes | — | 12-digit number | AWS Account ID where the CodeCommit repository lives |
| `RepositoryRegion` | String | Yes | `us-east-1` | `^[a-z]{2}-[a-z]+-\d$` | AWS Region of the CodeCommit repository |
| `BranchName` | String | Yes | `main` | `^[a-zA-Z0-9/_\-\.]{1,255}$` | Git branch to monitor. Only pushes to this branch trigger the pipeline |

### Group 3: Terraform Configuration

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `TerraformDirectory` | String | Yes | `.` | Any relative path | Path within the repo to the Terraform root module. Use `.` for repo root |
| `TerraformVersion` | String | Yes | `1.10.5` | `^\d+\.\d+\.\d+$` | Pinned Terraform CLI version installed by `buildspec` in every build |
| `BackendBucket` | String | Yes | — | Valid S3 bucket name | S3 bucket for Terraform remote state. Must exist before deployment |
| `BackendKey` | String | Yes | — | S3 key pattern | State file S3 path. Recommended format: `envs/{env}/{project}/terraform.tfstate` |
| `BackendRegion` | String | Yes | `us-east-1` | `^[a-z]{2}-[a-z]+-\d$` | AWS Region of the Terraform state S3 bucket |

### Group 4: Pipeline Behavior

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `EnableApproval` | String | No | `true` | `true`, `false` | Controls whether a Manual Approval stage is inserted between Plan and Apply. `true` = Source → Plan → Approve → Apply (gated). `false` = Source → Plan → Apply (auto-merge) |

### Group 5: IAM Roles (Pre-existing)

All role ARNs must reference **pre-existing** roles. This template does not create IAM roles.

| Parameter | Type | Required | Description |
|---|---|---|---|
| `PipelineRoleArn` | String | Always required | CodePipeline service role. Trust: `codepipeline.amazonaws.com` |
| `CodeBuildRoleArn` | String | Always required | CodeBuild service role for both Plan and Apply projects. Trust: `codebuild.amazonaws.com` |
| `ExecutionRoleArn` | String | Optional | Terraform execution role assumed by CodeBuild at runtime via `sts:AssumeRole`. Leave empty if CodeBuild role has direct infrastructure permissions |

### IAM Roles — Required Trust and Permissions

**`TerraformPipelineServiceRole`**

```json
// Trust policy
{
  "Effect": "Allow",
  "Principal": { "Service": "codepipeline.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

Minimum permissions:
- `s3:GetObject`, `s3:PutObject`, `s3:GetBucketVersioning` on artifact bucket
- `codecommit:GetBranch`, `codecommit:GetCommit`, `codecommit:UploadArchive`,
  `codecommit:GetUploadArchiveStatus`, `codecommit:CancelUploadArchive`
- `codepipeline:StartPipelineExecution` on the pipeline (EventBridge needs this
  to trigger the pipeline from the rule)
- `codebuild:BatchGetBuilds`, `codebuild:StartBuild`, `codebuild:StopBuild`
- `events:PutEvents` on the custom Event Bus
- `sns:Publish` on the SNS topic (for approval notifications)

**`TerraformCodeBuildRole`**

```json
// Trust policy
{
  "Effect": "Allow",
  "Principal": { "Service": "codebuild.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

Minimum permissions:
- `s3:GetObject`, `s3:PutObject`, `s3:GetBucketVersioning` on artifact bucket
- `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` on Terraform state bucket
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- `sts:AssumeRole` on the `ExecutionRoleArn` (if using execution role pattern)
- `sns:Publish` on the SNS topic
- `ssm:GetParameter` on any SSM paths used for Terraform variable injection

**`TerraformExecutionRole-{env}`** (optional)

```json
// Trust policy — trusts the CodeBuild role to assume it
{
  "Effect": "Allow",
  "Principal": {
    "AWS": [
      "arn:aws:iam::444455556666:role/TerraformCodeBuildRole"
    ]
  },
  "Action": "sts:AssumeRole"
}
```

Permissions: Scoped to exactly what Terraform modules need to manage in that
environment. Do not use `AdministratorAccess`. Audit with IAM Access Analyzer.

### Group 6: Artifacts & Storage

| Parameter | Type | Required | Description |
|---|---|---|---|
| `ArtifactBucket` | String | Yes | S3 bucket for CodePipeline artifact storage. Must exist in the pipeline account with versioning enabled |

### Group 7: Build Configuration

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `BuildImage` | String | No | `aws/codebuild/amazonlinux2-x86_64-standard:5.0` | Any valid image URI | CodeBuild build environment. Use AL2 standard or a custom image with common tools pre-installed |
| `BuildComputeType` | String | No | `BUILD_GENERAL1_SMALL` | `BUILD_GENERAL1_SMALL`, `BUILD_GENERAL1_MEDIUM`, `BUILD_GENERAL1_LARGE`, `BUILD_GENERAL1_2XLARGE` | Compute resources for CodeBuild projects |

### Group 8: Notifications & Logging

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `NotificationEmail` | String | Conditional | `""` | Valid email or empty | Email address for SNS subscription. Required when `EnableEmailNotifications=true` |
| `EnableEmailNotifications` | String | No | `true` | `true`, `false` | Create SNS topic and email subscription |
| `CreateCloudWatchLogs` | String | No | `true` | `true`, `false` | Create CloudWatch Log Groups for all CodeBuild projects and pipeline |
| `LogRetentionDays` | Number | No | `90` | 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653 | CloudWatch Logs retention period |

### Group 9: Tagging

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `CostCenter` | String | No | `unassigned` | Cost center code applied to all resource tags |
| `Owner` | String | No | `platform-engineering` | Owning team or individual |
| `TeamName` | String | No | `infrastructure` | Team name for resource grouping |

All resources receive these standard tags in addition to parameter-driven tags:
- `ManagedBy: CloudFormation`
- `Project: <ProjectName>`
- `Environment: <Environment>`

---

## Pipeline Behavior

| EnableApproval | Pipeline Flow | Best For |
|---|---|---|
| `false` | Source → Plan → Apply (auto) | Dev, sandbox — fast automated deployments |
| `true` | Source → Plan → Approve → Apply | Staging, production — gated deployments |

---

## Stack Outputs

| Output Key | Export Name | Description |
|---|---|---|
| `PipelineName` | `{StackName}-PipelineName` | Name of the CodePipeline |
| `PipelineArn` | `{StackName}-PipelineArn` | ARN of the CodePipeline |
| `PipelineUrl` | `{StackName}-PipelineUrl` | AWS Console URL for the pipeline |
| `EventBusArn` | `{StackName}-EventBusArn` | ARN of the custom EventBridge Event Bus — pass this to `setup-event-forwarder.sh` |
| `EventBusName` | `{StackName}-EventBusName` | Name of the custom Event Bus |
| `SnsTopicArn` | `{StackName}-SnsTopicArn` | ARN of the SNS topic (`NOTIFICATIONS_DISABLED` if off) |
| `PlanLogGroupName` | `{StackName}-PlanLogGroup` | CloudWatch Log Group for Plan builds |
| `ApplyLogGroupName` | `{StackName}-ApplyLogGroup` | CloudWatch Log Group for Apply builds |
| `ProjectName` | `{StackName}-ProjectName` | Project identifier |
| `Environment` | `{StackName}-Environment` | Environment label |

---

## CLI Script Reference

CLI scripts under `iam/` automate IAM role creation and cross-account EventBridge forwarding setup.

### setup-event-forwarder.sh

Creates the EventBridge rule, IAM role, and event forwarding for a CodeCommit repository in a repository account.

**Location:** `iam/setup-event-forwarder.sh`

| Flag | Required | Default | Description |
|---|---|---|---|
| `--pipeline-account-id` | Yes | — | 12-digit AWS Account ID of the pipeline account |
| `--event-bus-arn` | Yes | — | ARN of the custom EventBridge Event Bus in the pipeline account. Use the `EventBusArn` stack output |
| `--repo-account-id` | No | Current account | AWS Account ID where the CodeCommit repository lives |
| `--repository-name` | Yes | — | CodeCommit repository name to monitor |
| `--branch-name` | No | `main` | Git branch to forward events for |
| `--region` | No | `us-east-1` | AWS Region of the EventBridge event bus |
| `--role-name` | No | Auto-generated | Name of the cross-account IAM role for PutEvents |
| `--enable-delete-events` | No | `false` | When set, also forwards `referenceDeleted` events (branch deletions) |
| `--dry-run` | No | `false` | Print the IAM policy and resources that would be created without making changes |
| `--profile` | No | `default` | AWS CLI named profile to use |

### grant-artifact-access.sh

Grants the forwarder role access to the CodePipeline artifact bucket in the pipeline account.

**Location:** `iam/grant-artifact-access.sh`

| Flag | Required | Default | Description |
|---|---|---|---|
| `--artifact-bucket` | Yes | — | S3 bucket name for CodePipeline artifact storage |
| `--forwarder-role-arn` | Yes | — | ARN of the cross-account EventBridge forwarder IAM role |
| `--pipeline-account-id` | Yes | — | 12-digit AWS Account ID of the pipeline account |
| `--dry-run` | No | `false` | Print the S3 bucket policy that would be applied without making changes |
| `--profile` | No | `default` | AWS CLI named profile to use |

### create-iam-roles.sh

Creates the pre-existing IAM roles required by the CloudFormation template.

**Location:** `iam/create-iam-roles.sh`

| Flag | Required | Default | Description |
|---|---|---|---|
| `--project-name` | Yes | — | Project name prefix for role names |
| `--artifact-bucket` | Yes | — | S3 bucket name for CodePipeline artifact storage |
| `--event-bus-arn` | No | — | ARN of the custom EventBus (required if you want the pipeline role to have `events:PutEvents` permission) |
| `--dry-run` | No | `false` | Print the IAM policies that would be created without making changes |
| `--profile` | No | `default` | AWS CLI named profile to use |
