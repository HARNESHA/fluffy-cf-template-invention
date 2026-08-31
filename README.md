# Terraform Pipeline Framework

Enterprise-grade, reusable CloudFormation framework for deploying standardized
Terraform CI/CD pipelines across an AWS Organization via CloudFormation StackSets.

**Version 4.0.0**

---

## What This Is

One CloudFormation template. One CLI script. Any number of Terraform repositories.
Every project gets an isolated, fully configured pipeline by passing parameters —
no copy-paste, no per-project template maintenance, no second template to deploy.

**One template. One CLI script. One pipeline per project.**

| Component | Type | Deployed To | Purpose |
|---|---|---|---|
| `templates/terraform-pipeline-framework.yaml` | CloudFormation Template | Pipeline Account | CodePipeline, CodeBuild, EventBridge Bus, SNS, CloudWatch |
| `iam/setup-event-forwarder.sh` | CLI Script | Repository Account | Creates forwarder IAM role + EventBridge rule |
| `iam/grant-artifact-access.sh` | CLI Script | Pipeline Account | Grants forwarder role S3 bucket access |

---

## Repository Structure

```
org-stackset-template/
├── templates/
│   └── terraform-pipeline-framework.yaml   # THE ONLY template — Pipeline Account
│
├── buildspec/
│   ├── buildspec-plan.yml                  # terraform init + validate + plan
│   └── buildspec-apply.yml                 # terraform apply (saved plan binary)
│
├── iam/
│   ├── setup-event-forwarder.sh            # Creates forwarder role + EventBridge rule
│   ├── grant-artifact-access.sh            # Grants forwarder role S3 bucket access
│   ├── create-iam-roles.sh                 # Creates pipeline + codebuild roles
│   ├── trust-pipeline-role.json            # Trust policy for PipelineRole
│   ├── trust-codebuild-role.json           # Trust policy for CodeBuildRole
│   ├── trust-execution-role.json           # Trust policy template for ExecutionRole
│   ├── permissions-pipeline-role.json      # Permissions for PipelineRole
│   └── permissions-codebuild-role.json     # Permissions for CodeBuildRole
│
├── parameters/
│   ├── pipeline-prod.json                  # Pipeline — prod with approval
│   ├── pipeline-dev.json                   # Pipeline — dev, auto-merge
│   ├── pipeline-test.json                  # Pipeline — test, auto-merge
│   ├── stackset-overrides.json             # StackSet parameter overrides
│   └── eventbridge-event.json              # Example raw CodeCommit event shape
│
├── docs/
│   ├── deployment-guide.md                 # Prerequisites, step-by-step deployment
│   ├── architecture.md                     # Account topology, event flow, resources
│   ├── parameter-reference.md              # All parameters, IAM roles, outputs
│   └── security.md                         # Security controls and recommendations
│
├── org-setup.txt                           # AWS Organizations setup notes
└── README.md                               # This file
```

---

## Pipeline Behavior

One boolean controls everything. No mode selection required.

| EnableApproval | Pipeline Flow | Use For |
|---|---|---|
| `false` | Source → Plan → Apply (auto) | Dev / sandbox — fast automated deploys |
| `true` | Source → Plan → Approve → Apply | Staging and production — gated deployments |

In both modes, the Apply stage runs `terraform apply tfplan.binary`
— the exact plan binary produced by the Plan stage. No re-plan occurs.

---

## Quick Start

### 1. Create IAM Roles and S3 Buckets

In both the Pipeline Account and Repository Account, create the required IAM roles
and S3 buckets before deploying anything.

```bash
cd iam/
./create-iam-roles.sh --profile pipeline-account   # PipelineRole + CodeBuildRole
./create-iam-roles.sh --profile repo-account       # ForwarderRole (created by setup-event-forwarder.sh)
```

Ensure you have:
- S3 bucket for CodePipeline artifacts (Pipeline Account)
- S3 bucket for Terraform state (your backend)

### 2. Deploy the Pipeline Stack — Pipeline Account

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name <project>-<env>-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-prod.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --profile pipeline-account
```

### 3. Capture the Event Bus ARN

```bash
aws cloudformation describe-stacks \
  --stack-name <project>-<env>-tf-pipeline \
  --query "Stacks[0].Outputs[?OutputKey=='EventBusArn'].OutputValue" \
  --output text --profile pipeline-account
```

### 4. Set Up the Event Forwarder — Repository Account

Run the setup script in the Repository Account with the Event Bus ARN from step 3.
This creates the forwarder IAM role and EventBridge rule that forwards CodeCommit
push events to your pipeline's event bus.

```bash
./iam/setup-event-forwarder.sh \
  --event-bus-arn <EventBusArn from step 3> \
  --profile repo-account
```

### 5. Grant Artifact Access — Pipeline Account

The forwarder role needs S3 access to push events to the pipeline's artifact bucket.
Run this script to attach the bucket policy.

```bash
./iam/grant-artifact-access.sh \
  --stack-name <project>-<env>-tf-pipeline \
  --forwarder-role-arn <ForwarderRoleArn from step 4> \
  --profile pipeline-account
```

### 6. Copy Buildspecs to the Target Repository

| File | Purpose |
|---|---|
| `buildspec/buildspec-plan.yml` | Plan stage — runs init, validate, plan |
| `buildspec/buildspec-apply.yml` | Apply stage — runs apply on saved plan binary |

Commit both to the repository root and push. The pipeline triggers automatically.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment-guide.md](docs/deployment-guide.md) | Prerequisites, IAM roles, step-by-step deployment, day-2 operations, troubleshooting |
| [docs/architecture.md](docs/architecture.md) | Account topology, event flow diagram, resources created, conditions logic, artifact paths |
| [docs/parameter-reference.md](docs/parameter-reference.md) | Every parameter, IAM role trust policies, stack outputs |
| [docs/security.md](docs/security.md) | Least-privilege IAM, artifact security, secrets management, pipeline integrity |

---

## Key Design Principles

- **Single template** — one CloudFormation template (`terraform-pipeline-framework.yaml`) deploys the entire pipeline. No per-project template maintenance.
- **CLI-managed forwarder** — `setup-event-forwarder.sh` creates the forwarder role and EventBridge rule in repository accounts. No second template to deploy.
- **Generic forwarder role** — one role per repository account, forwards to ALL pipeline event buses. Shared across every pipeline triggered from that account.
- **Bucket policy via CLI** — `grant-artifact-access.sh` manages S3 bucket access for the forwarder role. No IAM roles created by the template.
- **No IAM roles created by the template** — all role ARNs are passed as parameters. Roles are managed separately per organizational standard.
- **No hardcoded values** — every project-specific value is a parameter.
- **Isolated per project** — each stack creates its own Event Bus, pipeline, SNS topic, and log groups. Zero shared state.
- **Plan binary integrity** — Apply consumes the exact plan binary from the Plan stage. No re-plan between plan and apply.
- **Event-driven only** — `PollForSourceChanges: false`. Every execution is tied to a specific commit ID passed through EventBridge.
- **Least privilege forwarding** — the forwarder role grants only `events:PutEvents` on `arn:aws:events:*:<pipeline-account>:event-bus/*`. Nothing else.
- **Simple approval control** — one boolean (`EnableApproval`) determines whether a manual approval gate is inserted between Plan and Apply.
