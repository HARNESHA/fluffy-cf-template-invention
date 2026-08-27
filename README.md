# Terraform Pipeline Framework

Enterprise-grade, reusable CloudFormation framework for deploying standardized
Terraform CI/CD pipelines across an AWS Organization via CloudFormation StackSets.

---

## What This Is

One CloudFormation template. Any number of Terraform repositories. Every project
gets an isolated, fully configured pipeline by passing parameters — no copy-paste,
no per-project template maintenance.

**Two templates. Two account types. One pipeline per project.**

| Template | Deploys To | Purpose |
|---|---|---|
| `templates/terraform-pipeline-framework.yaml` | Pipeline Account | CodePipeline, CodeBuild, EventBridge Bus, SNS, CloudWatch |
| `templates/codecommit-event-forwarder.yaml` | Repository Accounts | Forwards CodeCommit push events cross-account |

---

## Repository Structure

```
org-stackset-template/
│
├── templates/
│   ├── terraform-pipeline-framework.yaml   # Template 1 — Pipeline Account
│   └── codecommit-event-forwarder.yaml     # Template 2 — Repository Accounts
│
├── buildspec/
│   ├── buildspec-plan.yml                  # terraform init + validate + plan
│   └── buildspec-apply.yml                 # terraform apply (saved plan binary)
│
├── iam/
│   ├── trust-pipeline-role.json            # Trust policy for PipelineRole
│   ├── trust-codebuild-role.json           # Trust policy for CodeBuildRole
│   ├── trust-execution-role.json           # Trust policy template for ExecutionRole
│   ├── permissions-pipeline-role.json      # Permissions for PipelineRole
│   ├── permissions-codebuild-role.json     # Permissions for CodeBuildRole
│   └── create-iam-roles.sh                # Script to create roles via AWS CLI
│
├── parameters/
│   ├── pipeline-prod.json                  # Template 1 — prod with approval
│   ├── pipeline-dev.json                   # Template 1 — dev, auto-merge
│   ├── pipeline-test.json                  # Template 1 — test, auto-merge
│   ├── forwarder.json                      # Template 2 — event forwarder
│   ├── stackset-overrides.json             # StackSet parameter overrides
│   └── eventbridge-event.json             # Example raw CodeCommit event shape
│
├── docs/
│   ├── deployment-guide.md                 # Prerequisites, step-by-step deployment
│   ├── architecture.md                     # Account topology, event flow, resources
│   ├── parameter-reference.md              # All parameters, IAM roles, outputs
│   └── security.md                         # Security controls and recommendations
│
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

### 1. Prerequisites

- Two pre-existing IAM roles in the Pipeline Account:
  - `PipelineRoleArn` — CodePipeline service role
  - `CodeBuildRoleArn` — CodeBuild service role (shared by Plan and Apply)
  - (Optional) `ExecutionRoleArn` — Terraform execution role for infrastructure access
- S3 bucket for CodePipeline artifacts (Pipeline Account)
- S3 bucket for Terraform state
- Buildspec files committed to the target Terraform repository

### 2. Deploy Template 1 — Pipeline Account

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

Update `parameters/forwarder.json` with the ARN above.

### 4. Deploy Template 2 — Repository Account

```bash
aws cloudformation deploy \
  --template-file templates/codecommit-event-forwarder.yaml \
  --stack-name <repo>-<branch>-event-forwarder \
  --parameter-overrides file://parameters/forwarder.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --profile repo-account
```

### 5. Copy Buildspecs to the Target Repository

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
| [docs/parameter-reference.md](docs/parameter-reference.md) | Every parameter for both templates, IAM role trust policies, stack outputs |
| [docs/security.md](docs/security.md) | Least-privilege IAM, artifact security, secrets management, pipeline integrity |

---

## Key Design Principles

- **No IAM roles created** — all role ARNs are passed as parameters. Roles are managed separately per organizational standard.
- **Two IAM roles** — one for CodePipeline (`PipelineRoleArn`), one shared CodeBuild role (`CodeBuildRoleArn`). Optional execution role for infrastructure access.
- **No hardcoded values** — every project-specific value is a parameter.
- **Isolated per project** — each stack creates its own Event Bus, pipeline, SNS topic, and log groups. Zero shared state.
- **Plan binary integrity** — Apply consumes the exact plan binary from the Plan stage. No re-plan between plan and apply.
- **Event-driven only** — `PollForSourceChanges: false`. Every execution is tied to a specific commit ID passed through EventBridge.
- **Least privilege forwarding** — Template 2 grants only `events:PutEvents` on the exact target bus ARN. Nothing else.
- **Simple approval control** — one boolean (`EnableApproval`) determines whether a manual approval gate is inserted between Plan and Apply.
