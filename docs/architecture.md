# Architecture

## Overview

The framework consists of a single CloudFormation template (`terraform-pipeline-framework.yaml`) deployed to a central **Pipeline Account**. Cross-account event forwarding is handled by a CLI-created IAM Role and EventBridge Rule in each repository account. Together they form an event-driven, cross-account Terraform CI/CD pipeline where repositories and the pipeline infrastructure live in separate AWS accounts.

---

## Account Topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          AWS ORGANIZATIONS                                │
│                        Management Account                                 │
│                        (000000000000)                                     │
│                                                                           │
│   StackSet deploys 1 template to Pipeline Account                         │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
           ┌─────────────────┴──────────────────┐
           │                                    │
           ▼                                    ▼
┌──────────────────────┐           ┌────────────────────────────────────┐
│  REPOSITORY ACCOUNT  │           │         PIPELINE ACCOUNT           │
│  (111122223333)      │           │         (444455556666)              │
│                      │           │                                    │
│  No CloudFormation   │           │  terraform-pipeline-framework      │
│                      │           │  (1 template, 12+ resources)       │
│  CLI-Created:        │           │                                    │
│  ┌────────────────┐  │           │  ┌──────────────────────────────┐  │
│  │  IAM Role      │  │           │  │  Custom EventBridge Bus      │  │
│  │  (forwarder)   │  │           │  │  EventBridge Trigger Rule    │  │
│  ├────────────────┤  │           │  │  CodePipeline                │  │
│  │  EventBridge   │  │ events    │  │  CodeBuild (Plan)            │  │
│  │  Rule          ├──┼──────────►│  │  CodeBuild (Apply)           │  │
│  │  (default bus) │  │ PutEvents │  │  SNS Topic + Subscription    │  │
│  ├────────────────┤  │           │  │  CloudWatch Log Groups       │  │
│  │  CodeCommit    │  │           │  │  EventBridge Failure Rule    │  │
│  │  Repository    │  │           │  └──────────────────────────────┘  │
│  └────────────────┘  │           │                                    │
└──────────────────────┘           └────────────────────────────────────┘
```

---

## Event Flow

Every pipeline execution follows this exact sequence:

```
1. Developer pushes a commit to the monitored branch
           │
           ▼
2. CodeCommit emits a "Repository State Change" event
   to the DEFAULT EventBridge bus in the repository account
           │
           ▼
3. EventBridge Rule (CLI-created by setup-event-forwarder.sh)
   on the default bus matches the event:
     source          = aws.codecommit
     referenceType   = branch   ← explicitly excludes tags
     event           = referenceCreated | referenceUpdated
           │
           │  cross-account PutEvents via generic IAM Role
           │  (events:PutEvents on arn:aws:events:*:<pipeline-acct>:event-bus/*)
           ▼
4. Custom Event Bus in Pipeline Account receives the event
   (TerraformPipelineEventBus)
           │
           ▼
5. EventBridge Rule on the custom bus triggers CodePipeline
   (PipelineTriggerRule)
   Passes commitId as a source revision override
           │
           ▼
6. CodePipeline executes stages:

   EnableApproval=false         EnableApproval=true
   ─────────────────────        ────────────────────
   Source                       Source
     │                            │
   Plan                         Plan
     │                            │
   Apply                        [SNS email]
     │                            │
   [SNS result]                 Approve
     │                            │
   END                          Apply
                                  │
                                [SNS result]
                                  │
                                 END
           │
           ▼
7. SNS notification delivered to subscribed email address
```

---

## Resource Breakdown

### Template 1 — terraform-pipeline-framework.yaml

**Deployed to: Pipeline Account**
**Resources per stack: 12 (always) + 2 (conditional) = 14 total**

#### Always Created (12 resources)

| # | Resource Logical ID | AWS Type | Purpose |
|---|---|---|---|
| 1 | `PlanBuildLogGroup` | `AWS::Logs::LogGroup` | CloudWatch logs for Plan CodeBuild |
| 2 | `ApplyBuildLogGroup` | `AWS::Logs::LogGroup` | CloudWatch logs for Apply CodeBuild |
| 3 | `PipelineEventLogGroup` | `AWS::Logs::LogGroup` | CloudWatch logs for pipeline events |
| 4 | `TerraformPipelineEventBus` | `AWS::Events::EventBus` | Custom bus — receives cross-account CodeCommit events |
| 5 | `TerraformPipelineEventBusPolicy` | `AWS::Events::EventBusPolicy` | Grants repository account `events:PutEvents` on the bus |
| 6 | `PipelineTriggerRule` | `AWS::Events::Rule` | Filters events on the custom bus and starts CodePipeline |
| 7 | `TerraformPlanProject` | `AWS::CodeBuild::Project` | Runs `init`, `validate`, `plan` |
| 8 | `TerraformApplyProject` | `AWS::CodeBuild::Project` | Runs `apply` on saved plan binary |
| 9 | `TerraformPipeline` | `AWS::CodePipeline::Pipeline` | Orchestrates Source → Plan → [Approve] → Apply |
| 10 | `PipelineNotificationTopic` | `AWS::SNS::Topic` | Sends plan summaries, approvals, and failure alerts |
| 11 | `PipelineNotificationSubscription` | `AWS::SNS::Subscription` | Email subscription to the SNS topic |
| 12 | `PipelineNotificationTopicPolicy` | `AWS::SNS::TopicPolicy` | Allows CodeBuild and EventBridge to publish |

#### Conditionally Created (2 resources)

| # | Resource Logical ID | AWS Type | Condition | When Created |
|---|---|---|---|---|
| 13 | `PipelineFailureNotificationRule` | `AWS::Events::Rule` | `EnableEmailNotifications=true` | Always when notifications enabled |
| 14 | `PipelineNotificationSubscription` | `AWS::SNS::Subscription` | `EnableEmailNotifications=true` | Always when notifications enabled |

**Note:** CloudWatch Log Groups have no `DeletionPolicy`. They are destroyed when the stack is deleted.

### Template 1 — Conditions Reference

| Condition | Expression | Controls |
|---|---|---|
| `CreateApprovalStage` | `EnableApproval == "true"` | Manual Approval stage in pipeline |
| `EnableEmailNotifications` | `EnableEmailNotifications == "true"` | SNS topic, subscription, failure alerts |
| `EnableCloudWatch` | `CreateCloudWatchLogs == "true"` | CloudWatch Log Groups |
| `UseCustomPipelineName` | `PipelineName != ""` | Pipeline naming (auto vs explicit) |
| `HasExecutionRole` | `ExecutionRoleArn != ""` | STS AssumeRole in buildspecs |
| `IsCrossAccountRepo` | `RepositoryAccountId != AWS::AccountId` | Cross-account source role |

### Template 1 — IAM Roles Required

| Role | Used By | Trust | Minimum Permissions |
|---|---|---|---|
| `PipelineRoleArn` | CodePipeline + EventBridge trigger | `codepipeline.amazonaws.com`, `events.amazonaws.com` | S3, CodeCommit, CodePipeline, CodeBuild, EventBridge, SNS |
| `CodeBuildRoleArn` | Plan + Apply CodeBuild | `codebuild.amazonaws.com` | S3, Logs, STS, SNS, SSM |
| `ExecutionRoleArn` (optional) | Runtime via STS AssumeRole | CodeBuild roles | Infrastructure permissions for Terraform |

---

### CLI-Created Resources — Repository Account

Created by `iam/setup-event-forwarder.sh` in each repository account.

| # | Resource | AWS Type | Purpose |
|---|---|---|---|
| 1 | Event Forwarder IAM Role | `aws iam create-role` | Generic role for EventBridge to `PutEvents` to any pipeline bus |
| 2 | EventBridge Forwarder Rule | `aws events put-rule` | Captures CodeCommit pushes on the default bus and forwards them |

#### IAM Role Details

| Property | Value |
|---|---|
| Trust Principal | `events.amazonaws.com` |
| Trust Condition | `aws:SourceAccount` = repo account ID |
| Policy Statement | `events:PutEvents` on `arn:aws:events:*:<pipeline-account-id>:event-bus/*` |
| Created by | `iam/setup-event-forwarder.sh` |

The role is **generic** — it allows putting events to any event bus in the pipeline account. This means a single role can target multiple pipeline stacks.

#### EventBridge Rule Details

| Property | Value |
|---|---|
| Bus | Default bus in the repo account |
| Event Source | `aws.codecommit` |
| Event Pattern | `referenceType = branch`, events = `referenceCreated`, `referenceUpdated` |
| Target | Custom event bus ARN passed via `--event-bus-arn` |
| Created by | `iam/setup-event-forwarder.sh` |

#### Bucket Policy

Created by `iam/grant-artifact-access.sh` in the **Pipeline Account**.
Grants the CodeBuild roles in the pipeline account access to the artifact S3 bucket.

---

## Account Topology Summary

| Account | Resources | Provisioned By |
|---|---|---|
| **Pipeline Account** | 1 CloudFormation template (14 resources): EventBus, TriggerRule, Pipeline, CodeBuild, SNS, Logs | `terraform-pipeline-framework.yaml` via StackSets |
| **Repository Account** | 2 CLI-created resources: Forwarder IAM Role + EventBridge Rule | `iam/setup-event-forwarder.sh` |

---

## Deployment Flow

```
Step 1: Create IAM roles + S3 buckets
         (per-account, manual or separate automation)
              │
              ▼
Step 2: Deploy terraform-pipeline-framework.yaml to Pipeline Account
         via StackSet → outputs EventBusArn
              │
              ▼
Step 3: Run iam/setup-event-forwarder.sh in Repository Account
         --event-bus-arn <EventBusArn from Step 2>
         (creates IAM Role + EventBridge Rule on default bus)
              │
              ▼
Step 4: Run iam/grant-artifact-access.sh in Pipeline Account
         (grants CodeBuild access to artifact S3 bucket)
              │
              ▼
Step 5: Copy buildspec files to artifact bucket
         Push commit → CodeCommit event → forwarder → pipeline triggers
```

---

## Artifact Flow

```
S3 Artifact Bucket (ArtifactBucket parameter)
│
├── [CodePipeline managed]
│   └── <pipeline-name>/<execution-id>/
│       ├── SourceOutput.zip        ← repository source code
│       └── PlanOutput.zip          ← contains tfplan.binary + plan.txt
│
└── [buildspec managed — uploaded by scripts]
    └── <project>/<environment>/<commit-id>/
        ├── tfplan.binary            ← binary plan (passed to Apply stage)
        ├── plan.txt                 ← human-readable plan output
        └── apply.txt                ← apply execution log
```

The plan binary lives in two places deliberately:
- Inside `PlanOutput.zip` for CodePipeline artifact chaining (Apply stage input)
- Uploaded directly to S3 by path for permanent audit trail keyed by commit SHA

---

## Scalability Model

This framework is designed to scale across hundreds of repositories:

```
Each Terraform repo gets its own isolated stack:

  payments-infra-prod-tf-pipeline
    ├── EventBus:  payments-infra-prod-terraform-pipeline-bus
    ├── Pipeline:  payments-infra-prod-main-tf-pipeline
    ├── SNS:       payments-infra-prod-tf-pipeline-notifications
    └── Logs:      /codebuild/payments-infra-prod-tf-plan

  network-core-prod-tf-pipeline
    ├── EventBus:  network-core-prod-terraform-pipeline-bus
    ├── Pipeline:  network-core-prod-main-tf-pipeline
    ├── SNS:       network-core-prod-tf-pipeline-notifications
    └── Logs:      /codebuild/network-core-prod-tf-plan

  shared-services-prod-tf-pipeline
    ...
```

No shared state, no cross-pipeline interference, full isolation per project.

Each repository account needs only two CLI-created resources (IAM Role + EventBridge Rule), making it trivial to add new repos.
