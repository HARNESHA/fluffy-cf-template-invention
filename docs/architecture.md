# Architecture

## Overview

The framework consists of two CloudFormation templates deployed via StackSets
across an AWS Organization. Together they form an event-driven, cross-account
Terraform CI/CD pipeline where repositories and the pipeline infrastructure
live in separate AWS accounts.

---

## Account Topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          AWS ORGANIZATIONS                                │
│                        Management Account                                 │
│                        (000000000000)                                     │
│                                                                           │
│   StackSets deploy both templates to target accounts                      │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
           ┌─────────────────┴──────────────────┐
           │                                    │
           ▼                                    ▼
┌──────────────────────┐           ┌────────────────────────────────────┐
│  REPOSITORY ACCOUNT  │           │         PIPELINE ACCOUNT           │
│  (111122223333)      │           │         (444455556666)              │
│                      │           │                                    │
│  Template 2          │           │  Template 1                        │
│  codecommit-event-   │           │  terraform-pipeline-framework      │
│  forwarder.yaml      │           │                                    │
│                      │           │  Per-project resources:            │
│  ┌────────────────┐  │           │  ┌──────────────────────────────┐  │
│  │  CodeCommit    │  │           │  │  Custom EventBridge Bus      │  │
│  │  Repository    │  │           │  │  EventBridge Trigger Rule    │  │
│  └───────┬────────┘  │           │  │  CodePipeline                │  │
│          │ push      │           │  │  CodeBuild (Plan)            │  │
│          ▼           │           │  │  CodeBuild (Apply)           │  │
│  ┌───────────────┐   │           │  │  SNS Topic                   │  │
│  │  EventBridge  │   │  events   │  │  CloudWatch Log Groups       │  │
│  │  Rule         ├───┼──────────►│  └──────────────────────────────┘  │
│  │  (default bus)│   │ PutEvents │                                    │
│  └───────────────┘   │           │                                    │
│                      │           │                                    │
│  IAM Role            │           │                                    │
│  (events:PutEvents   │           │                                    │
│   only)              │           │                                    │
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
3. EventBridge Rule (Template 2) matches the event:
     source          = aws.codecommit
     repositoryName  = <RepositoryName parameter>
     referenceName   = <BranchName parameter>
     referenceType   = branch   ← explicitly excludes tags
     event           = referenceCreated | referenceUpdated
           │
           │  cross-account PutEvents via IAM Role
           ▼
4. Custom Event Bus in Pipeline Account receives the event
   (Template 1: TerraformPipelineEventBus)
           │
           ▼
5. EventBridge Rule on the custom bus triggers CodePipeline
   (Template 1: PipelineTriggerRule)
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

**Note:** CloudWatch Log Groups (resources 1-3) also have condition `EnableCloudWatch=true`.

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

### Template 2 — codecommit-event-forwarder.yaml

**Deployed to: Repository Accounts**
**Resources per stack: 2 (always)**

| # | Resource Logical ID | AWS Type | Purpose |
|---|---|---|---|
| 1 | `EventForwarderRole` | `AWS::IAM::Role` | Assumed by EventBridge to `PutEvents` to the pipeline account bus |
| 2 | `CodeCommitForwarderRule` | `AWS::Events::Rule` | Captures CodeCommit events on the default bus and forwards them |

#### Conditions Reference

| Condition | Expression | Controls |
|---|---|---|
| `ForwardingEnabled` | `EnableForwarding == "true"` | Rule state (ENABLED/DISABLED) |
| `IncludeDeleteEvents` | `ForwardDeleteEvents == "true"` | Include `referenceDeleted` in event pattern |

---

## Pipeline Artifact Flow

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
