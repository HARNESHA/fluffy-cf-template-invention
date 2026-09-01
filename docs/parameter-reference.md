# Parameter Reference

Complete reference for all parameters for the CloudFormation template.

---

## terraform-pipeline-framework.yaml

### Group 1: Project Identity

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `ProjectName` | String | Yes | — | Short lowercase identifier. Used as prefix on all resource and role names. Example: `payments-infra` |
| `Environment` | String | Yes | `dev` | Environment label used in resource naming and all tags |

### Group 2: Source Repository

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `RepositoryProvider` | String | Yes | `codecommit` | `codecommit`, `github` | Source provider. `codecommit` clones via the CodeBuild role using `codecommit:GitPull`; `github` clones via a CodeStar Connections (GitHub App) connection |
| `RepositoryName` | String | Yes | — | — | Repository name, or full GitHub slug (`owner/repo`) when provider is `github`. Must exist in this account |
| `RepositoryRegion` | String | Yes | `us-east-1` | — | Region of the repository (CodeCommit) or of the connection (GitHub) |
| `BranchName` | String | Yes | `main` | — | Git branch to monitor. Only pushes to this branch trigger the pipeline/build |
| `CodeStarConnectionArn` | String | Conditional | `""` | — | ARN of a pre-existing CodeStar Connections connection. Required only when `RepositoryProvider=github`, otherwise leave blank |

### Group 3: Terraform Configuration

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `TerraformDirectory` | String | Yes | `.` | Path within the repo to the Terraform root module. Use `.` for repo root |
| `TerraformVersion` | String | Yes | `1.10.5` | Pinned Terraform CLI version installed by every build |
| `BackendBucket` | String | Yes | — | S3 bucket for Terraform remote state |
| `BackendKey` | String | Yes | — | State file S3 path. Recommended: `envs/{env}/{project}/terraform.tfstate` |
| `BackendRegion` | String | Yes | `us-east-1` | Region of the Terraform state S3 bucket |

### Group 4: Deployment Mode

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `EnableApproval` | String | No | `false` | `true`, `false` | `true` = CodePipeline with Source → Plan → Approve → Apply (gated). `false` = single CodeBuild that clones, plans, blocks reduce/destroy, and auto-applies |

### Group 5: IAM

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `CreateIamRoles` | String | No | `true` | `true` = the template creates the Pipeline and CodeBuild IAM roles under `RolePath`. `false` = use the pre-existing `PipelineRoleArn` / `CodeBuildRoleArn` |
| `RolePath` | String | No | `/` | IAM role path (e.g. `/`, `/application_role/`, `/teams/sre/`). Used only when `CreateIamRoles=true` so each team can create roles in its allowed path |
| `PipelineRoleArn` | String | Conditional | `""` | ARN of a pre-existing CodePipeline service role. Used only when `CreateIamRoles=false` |
| `CodeBuildRoleArn` | String | Conditional | `""` | ARN of a pre-existing (clone-capable) CodeBuild service role. Used only when `CreateIamRoles=false` |
| `ExecutionRoleArn` | String | No | `""` | ARN of an optional Terraform Execution Role that CodeBuild assumes at runtime via `sts:AssumeRole`. Leave blank to use the CodeBuild role's own permissions |

> The CodeBuild role must be **clone-capable** (CodeCommit `GitPull` or
> `codestar-connections:UseConnection`) because the auto mode clones the repo from
> within the build. See [security.md](security.md) for the recommended execution
> role trust policy.

### Group 6: Artifact Storage

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `ArtifactBucket` | String | Yes | — | SINGLE shared S3 bucket for plan binaries, logs, build cache, and CodePipeline artifacts for all projects/environments. Must exist with versioning + SSE-KMS. See [artifact-bucket-guide.md](artifact-bucket-guide.md) |
| `ArtifactPrefix` | String | No | `terraform-artifacts` | Top-level key prefix inside `ArtifactBucket` for this framework's artifacts |

### Group 7: Build Configuration

| Parameter | Type | Required | Default | Allowed Values | Description |
|---|---|---|---|---|---|
| `BuildImage` | String | No | `aws/codebuild/amazonlinux2-x86_64-standard:5.0` | Any valid image URI | CodeBuild build environment |
| `BuildComputeType` | String | No | `BUILD_GENERAL1_SMALL` | `BUILD_GENERAL1_SMALL`, `BUILD_GENERAL1_MEDIUM`, `BUILD_GENERAL1_LARGE`, `BUILD_GENERAL1_2XLARGE` | Compute resources |

### Group 8: Notifications & Logging

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `NotificationEmail` | String | Conditional | `""` | Email for SNS subscription. Required when `EnableEmailNotifications=true` |
| `EnableEmailNotifications` | String | No | `true` | Create SNS topic and email subscription |
| `CreateCloudWatchLogs` | String | No | `true` | Create CloudWatch Log Groups for the CodeBuild projects |
| `LogRetentionDays` | Number | No | `90` | CloudWatch Logs retention period |

### Group 9: Tagging

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `CostCenter` | String | No | `unassigned` | Cost center code applied to all resource tags |
| `Owner` | String | No | `platform-engineering` | Owning team or individual |
| `TeamName` | String | No | `infrastructure` | Team name for resource grouping |

All resources receive standard tags + parameter-driven tags
(`ManagedBy: CloudFormation`, `Project`, `Environment`, `CostCenter`, `Owner`, `Team`).

---

## Pipeline Behavior

| EnableApproval | Flow | Best For |
|---|---|---|
| `false` | single CodeBuild: clone → plan → guard (block destroy/replace) → auto-apply | Dev, sandbox — fast automated deployments |
| `true` | CodePipeline: Source → Plan → Approve → Apply | Staging, production — gated deployments |

Both modes share the exact plan binary via S3 (keyed by commit); Apply never
re-plans.

---

## Stack Outputs

| Output Key | Export Name | Description |
|---|---|---|
| `DeploymentMode` | `{StackName}-DeploymentMode` | `pipeline` (approval) or `auto` |
| `PipelineName` | `{StackName}-PipelineName` | Name of the CodePipeline (approval mode) |
| `PipelineArn` | `{StackName}-PipelineArn` | ARN of the CodePipeline (approval mode) |
| `PipelineUrl` | `{StackName}-PipelineUrl` | AWS Console URL for the pipeline (approval mode) |
| `BuildProjectName` | `{StackName}-BuildProjectName` | CodeBuild project name (plan in approval mode, or auto project) |
| `CodeBuildRoleArn` | `{StackName}-CodeBuildRoleArn` | ARN of the CodeBuild role (when template-created) |
| `PipelineRoleArn` | `{StackName}-PipelineRoleArn` | ARN of the Pipeline role (approval mode, when template-created) |
| `ArtifactBucket` | `{StackName}-ArtifactBucket` | Shared artifact bucket |
| `ArtifactPrefix` | `{StackName}-ArtifactPrefix` | Artifact key prefix |
| `SnsTopicArn` | `{StackName}-SnsTopicArn` | ARN of the SNS topic |
| `ProjectName` | `{StackName}-ProjectName` | Project identifier |
| `Environment` | `{StackName}-Environment` | Environment label |
