# Architecture

## Overview

The framework is a single CloudFormation template
(`templates/terraform-pipeline-framework.yaml`) deployed once per
project/environment within **one AWS account**. Repositories, pipeline
infrastructure, IAM roles, and the shared S3 artifact bucket all live in the
same account. There is **no cross-account** event forwarding, no forwarder
roles, and no custom EventBridge bus — the template triggers on CodeCommit
push events on the account's **default** EventBridge bus.

---

## Account Topology

```
┌────────────────────────────────────────────────────────────┐
│                    SINGLE AWS ACCOUNT                        │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              terraform-pipeline-framework.yaml          │ │
│  │              (deployed per project/environment)         │ │
│  │                                                          │ │
│  │  ┌─────────────┐   ┌───────────────────────────────┐   │ │
│  │  │ CodeCommit  │   │ Approval mode:                 │   │ │
│  │  │ (or GitHub  │   │  CodePipeline                 │   │ │
│  │  │ via CodeStar│   │  Plan → Approve → Apply       │   │ │
│  │  │ connection) │   │                               │   │ │
│  │  └──────┬──────┘   │ Auto mode:                    │   │ │
│  │         │          │  CodeBuild clone+plan+apply   │   │ │
│  │         │ default  └───────────────────────────────┘   │ │
│  │         │ bus       │                                  │ │
│  │  ┌──────▼──────┐    │  EventBridge trigger rule       │ │
│  │  │ EventBridge │    │  IAM roles (CreateIamRoles)     │ │
│  │  │ (default)   │    │  SNS topic + subscription       │ │
│  │  └─────────────┘    │  CloudWatch log groups          │ │
│  │                      └────────────────────────────────┘ │
│  │                                                          │
│  │  Shared S3 artifact bucket (tf-artifacts-<acct>)         │
│  └────────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────┘
```

---

## Event Flow

```
1. Developer pushes a commit to the monitored branch
           │
           ▼
2. CodeCommit emits a "Repository State Change" event
   to the DEFAULT EventBridge bus (same account)
           │
           ▼
3. EventBridge Rule (template-created, PipelineTriggerRule or
   AutoBuildTriggerRule) matches:
     source         = aws.codecommit
     referenceType  = branch      ← excludes tags
     event          = referenceCreated | referenceUpdated
           │
           ▼
4a. Approval mode:  rule starts CodePipeline (passing commitId as
     source revision) → Source → Plan → Approve → Apply
4b. Auto mode:      rule starts the CodeBuild auto project (clone +
     plan + guard + apply)
           │
           ▼
5. SNS notification delivered to subscribed email address
```

---

## Resource Breakdown

### terraform-pipeline-framework.yaml

**Deployed to:** single account (per project/environment)

#### IAM Roles (created only when `CreateIamRoles=true`)

| Logical ID | AWS Type | Trust | Purpose |
|---|---|---|---|
| `PipelineRole` | `AWS::IAM::Role` | `codepipeline.amazonaws.com` | CodePipeline service role |
| `PipelineRolePolicy` | `AWS::IAM::Policy` | — | S3, CodeCommit/CodeStar, CodePipeline, CodeBuild, SNS, Logs |
| `CodeBuildRole` | `AWS::IAM::Role` | `codebuild.amazonaws.com` | Clone-capable CodeBuild role |
| `CodeBuildRolePolicy` | `AWS::IAM::Policy` | — | S3 (artifact+state), CodeCommit GitPull/CodeStar, Logs, STS execution role, SNS, SSM |

`RolePath` places roles under a team/org IAM path. When `CreateIamRoles=false`,
the template uses the pre-existing `PipelineRoleArn` / `CodeBuildRoleArn`.

#### Base resources

| Logical ID | AWS Type | Condition | Purpose |
|---|---|---|---|
| `PlanBuildLogGroup` | `AWS::Logs::LogGroup` | `CreateCloudWatchLogs` | Logs for Plan/auto CodeBuild |
| `ApplyBuildLogGroup` | `AWS::Logs::LogGroup` | `CreateCloudWatchLogs` | Logs for Apply CodeBuild |
| `AutoBuildLogGroup` | `AWS::Logs::LogGroup` | `CreateCloudWatchLogs` | Logs for auto CodeBuild |
| `PipelineNotificationTopic` | `AWS::SNS::Topic` | `EnableEmailNotifications` | Notifications |
| `PipelineNotificationSubscription` | `AWS::SNS::Subscription` | `EnableEmailNotifications` | Email subscription |
| `PipelineNotificationTopicPolicy` | `AWS::SNS::TopicPolicy` | `EnableEmailNotifications` | Allows publish from CodeBuild/EventBridge |

#### Approval-mode resources (`EnableApproval=true`)

| Logical ID | AWS Type | Purpose |
|---|---|---|
| `TerraformPlanProject` | `AWS::CodeBuild::Project` | Plan stage (CODEPIPELINE source, `buildspec-plan.yml`) |
| `TerraformApplyProject` | `AWS::CodeBuild::Project` | Apply stage (CODEPIPELINE source, `buildspec-apply.yml`) |
| `TerraformPipeline` | `AWS::CodePipeline::Pipeline` | Source → Plan → Approve → Apply |
| `PipelineTriggerRule` | `AWS::Events::Rule` | Default bus → starts pipeline on push |
| `PipelineFailureNotificationRule` | `AWS::Events::Rule` | Failure alerts |

#### Auto-mode resources (`EnableApproval=false`)

| Logical ID | AWS Type | Purpose |
|---|---|---|
| `TerraformAutoProject` | `AWS::CodeBuild::Project` | NO_SOURCE, inline buildspec = `buildspec-auto.yml` |
| `AutoBuildTriggerRule` | `AWS::Events::Rule` | Default bus → starts the auto build on push |

---

## Conditions Reference

| Condition | Expression | Controls |
|---|---|---|
| `CreateApprovalStage` | `EnableApproval == "true"` | Pipeline, Plan/Apply projects, PipelineTriggerRule |
| `AutoDeployMode` | `EnableApproval == "false"` | Auto CodeBuild + AutoBuildTriggerRule |
| `CreateIamRoles` | `CreateIamRoles == "true"` | Role creation |
| `EnableEmailNotifications` | `EnableEmailNotifications == "true"` | SNS topic, subscription, failure alerts |
| `EnableCloudWatch` | `CreateCloudWatchLogs == "true"` | CloudWatch log groups |
| `HasExecutionRole` | `ExecutionRoleArn != ""` | STS AssumeRole in buildspec + role policy |
| `IsGithub` | `RepositoryProvider == "github"` | CodeStar connection usage |
| `IsCodeCommit` | `RepositoryProvider == "codecommit"` | CodeCommit source/clone |

---

## Artifact Flow (shared bucket)

```
Shared S3 bucket (ArtifactBucket, e.g. tf-artifacts-<acct>)
│
├── terraform-artifacts/                     ← ArtifactPrefix
│   └── <repository>/<environment>/<branch>/
│       ├── plans/<commit-id>/
│       │   ├── tfplan.binary               ← plan binary (Plan uploads, Apply downloads)
│       │   └── plan.txt                    ← human-readable plan
│       └── logs/<codebuild-build-id>/
│           └── apply.txt                   ← apply log
├── build-cache/<project>-<env>-<plan|apply|auto>/   ← CodeBuild provider cache
└── <pipeline-name>/                        ← CodePipeline managed artifact store
```

The plan binary is shared between Plan and Apply via the deterministic S3 key
`{ArtifactPrefix}/{RepositoryName}/{Environment}/{BranchName}/plans/{CommitId}/tfplan.binary`,
guaranteeing Apply uses the exact reviewed binary. See
[artifact-bucket-guide.md](artifact-bucket-guide.md) for bucket setup and
retention.

---

## Scalability Model

Each Terraform repo/environment gets its own isolated stack inside the same
account:

```
  payments-infra-prod-tf-pipeline
    ├── Pipeline/CB: payments-infra-prod...
    ├── IAM roles:   /payments-infra-prod-pipeline-role, -codebuild-role
    ├── SNS:         payments-infra-prod-tf-notification
    └── Logs:        /codebuild/payments-infra-prod-tf-plan
```

All stacks share one governed artifact bucket (`tf-artifacts-<acct>`), with
key prefixes (`<repo>/<env>/<branch>/`) isolating each pipeline's artifacts.
No cross-project interference.
