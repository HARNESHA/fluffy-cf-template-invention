# Terraform Pipeline Framework

Enterprise-grade, reusable CloudFormation framework for deploying standardized
Terraform CI/CD pipelines within a single AWS account.

**Version 5.0.0**

---

## What This Is

One CloudFormation template. One shared S3 bucket. Any number of Terraform
repositories. Every project gets an isolated, fully configured pipeline by
passing parameters — no copy-paste, no per-project template maintenance.

The template creates its own IAM roles, CodeBuild projects, CodePipeline
(approval mode) or a self-contained auto-apply CodeBuild project (non-approval
mode), EventBridge triggers, SNS notifications, and CloudWatch logs.

**One template. One account. One pipeline per project.**

| Component | Type | Purpose |
|---|---|---|
| `templates/terraform-pipeline-framework.yaml` | CloudFormation Template | Pipeline, CodeBuild, IAM roles, EventBridge, SNS, CloudWatch |
| `buildspec/buildspec-plan.yml` | Buildspec | Approval mode plan stage |
| `buildspec/buildspec-apply.yml` | Buildspec | Approval mode apply stage |
| `buildspec/buildspec-auto.yml` | Buildspec | Non-approval mode clone + plan + guard + apply |
| `iam/trust-execution-role.json` | Reference | Optional execution-role trust policy template |

---

## Repository Structure

```
fluffy-cf-template-invention/
├── templates/
│   └── terraform-pipeline-framework.yaml   # THE ONLY template — single account
│
├── buildspec/
│   ├── buildspec-plan.yml                  # Plan stage (approval mode)
│   ├── buildspec-apply.yml                 # Apply stage (approval mode)
│   └── buildspec-auto.yml                  # Auto mode (clone + guard + apply)
│
├── iam/
│   └── trust-execution-role.json           # Optional execution-role trust template
│
├── parameters/
│   ├── pipeline-prod.json                  # prod with approval
│   ├── pipeline-dev.json                   # dev with approval
│   ├── pipeline-test.json                  # test — auto mode (no approval)
│   └── stackset-overrides.json             # StackSet parameter overrides
│
├── docs/
│   ├── architecture.md                     # Topology, event flow, resources
│   ├── deployment-guide.md                 # Prerequisites, step-by-step deploy, ops, troubleshooting
│   ├── parameter-reference.md              # Every parameter, conditions, outputs
│   ├── security.md                         # Security controls and recommendations
│   └── artifact-bucket-guide.md            # Shared bucket creation, retention, lifecycle
│
└── README.md                               # This file
```

---

## Pipeline Behavior

One boolean controls the deployment mode.

| EnableApproval | Pipeline Flow | Use For |
|---|---|---|
| `true` | Source → Plan → Approve → Apply | Staging and production — gated, reviewed deployments |
| `false` | single CodeBuild: clone → plan → guard → auto-apply | Dev / sandbox — fast automated deploys |

In approval mode, the Apply stage downloads and applies the **exact plan binary**
produced by the Plan stage (shared via S3, keyed by commit). No re-plan occurs.

In auto mode, the build **blocks any plan that would destroy or replace
resources** (`must be replaced` / `will be destroyed`), failing the build instead.

---

## Quick Start

### 1. Create the shared artifact bucket (once per account)

Follow [docs/artifact-bucket-guide.md](docs/artifact-bucket-guide.md) to create a
single versioned, SSE-KMS-encrypted bucket used by all projects (pass its name
as `ArtifactBucket`).

### 2. (GitHub only) Create a CodeStar Connections connection

If `RepositoryProvider=github`, create a CodeStar Connections (GitHub App)
connection and pass its ARN as `CodeStarConnectionArn`.

### 3. Deploy the stack

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name <project>-<env>-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-prod.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

Roles are created by the template (`CreateIamRoles=true`, `RolePath` controls the
IAM path). For approval mode the manual approval happens in the CodePipeline
console or via the SDK.

### 4. Copy buildspecs to the repository

| File | When Required | Purpose |
|---|---|---|
| `buildspec/buildspec-plan.yml` | approval mode | Plan stage — init, validate, plan, upload |
| `buildspec/buildspec-apply.yml` | approval mode | Apply stage — download plan, apply, upload log |
| `buildspec/buildspec-auto.yml` | auto mode | Auto build — clone, plan, guard, apply |

Commit the relevant buildspec(s) to the repository and push. EventBridge
triggers the pipeline/build on the monitored branch.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/deployment-guide.md](docs/deployment-guide.md) | Prerequisites, step-by-step deployment, day-2 operations, troubleshooting |
| [docs/architecture.md](docs/architecture.md) | Single-account topology, event flow, resources, conditions, artifact paths |
| [docs/parameter-reference.md](docs/parameter-reference.md) | Every parameter, conditions, stack outputs |
| [docs/security.md](docs/security.md) | Least-privilege IAM, artifact security, pipeline integrity |
| [docs/artifact-bucket-guide.md](docs/artifact-bucket-guide.md) | Shared bucket creation, versioning, encryption, retention, lifecycle |

---

## Key Design Principles

- **Single template** — one CloudFormation template deploys the entire pipeline. No per-project template maintenance.
- **Single account** — repo and pipeline live in the same account. No cross-account roles, forwarders, or custom event buses.
- **Template-created roles** — `CreateIamRoles` + `RolePath` let the template mint IAM roles in a team's allowed path. No separate role scripts.
- **Clone-capable CodeBuild role** — the CodeBuild role can clone CodeCommit (GitPull) or use a CodeStar connection for GitHub, so the auto mode needs no Source stage.
- **One shared artifact bucket** — plan binaries, logs, build cache, and CodePipeline artifacts all share one governed, versioned, encrypted bucket.
- **Plan binary integrity** — Apply downloads the exact S3 plan binary produced by Plan, keyed by commit. No re-plan between plan and apply.
- **Block destructive auto-apply** — auto mode fails the build if the plan contains destroy/replace actions.
- **Event-driven only** — `PollForSourceChanges: false`. Every execution is tied to a specific commit passed through EventBridge on the default bus.
- **Simple mode control** — one boolean (`EnableApproval`) selects approval vs. auto mode.
