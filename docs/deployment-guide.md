# Deployment Guide

Step-by-step guide for deploying the Terraform Pipeline Framework within a
single AWS account.

---

## Prerequisites

### AWS Account

| Requirement | Details |
|---|---|
| AWS account | The account where both the Terraform repositories and the pipeline live |
| Shared S3 bucket | **One** versioned, SSE-KMS-encrypted S3 bucket for pipeline artifacts, Terraform plan binaries/logs, and remote state (`BucketName`) |
| CodeCommit repository | The Terraform repository already exists in this account (or a GitHub repo + CodeStar connection) |

### Tooling

- AWS CLI v2 configured
- CloudFormation deployment capabilities (`CAPABILITY_NAMED_IAM`)

---

## Step 1: Create the shared bucket (once per account)

Follow [docs/artifact-bucket-guide.md](artifact-bucket-guide.md) to create one
bucket (e.g. `tf-artifacts-<acct>`) with:
- Versioning enabled
- Default SSE-KMS encryption
- Public access fully blocked
- Optional lifecycle rules for archival/deletion

This single bucket serves the CodePipeline artifact store, Terraform plan
binaries/logs, and Terraform remote state. You'll pass it as `BucketName` in
every stack in this account. State lives at `{ProjectName}/state/{Environment}/terraform.tfstate`.

---

## Step 2: (GitHub only) Create a CodeStar Connections connection

If `RepositoryProvider=github`:

1. Open **CodePipeline → Settings → Connections → Create connection**.
2. Choose **GitHub** and complete the GitHub App authorization.
3. Note the connection ARN → pass it as `CodeStarConnectionArn`.

Skip this step for `RepositoryProvider=codecommit`.

---

## Step 3: Prepare the parameter file

Copy and edit a parameter file:

```bash
cp parameters/pipeline-prod.json parameters/pipeline-mypipeline.json
```

Key values you must set:

```json
[
  {"ParameterKey": "ProjectName",        "ParameterValue": "my-project"},
  {"ParameterKey": "Environment",        "ParameterValue": "prod"},
  {"ParameterKey": "RepositoryProvider", "ParameterValue": "codecommit"},
  {"ParameterKey": "RepositoryName",     "ParameterValue": "my-terraform-repo"},
  {"ParameterKey": "BranchName",         "ParameterValue": "main"},
  {"ParameterKey": "CodeStarConnectionArn", "ParameterValue": ""},
  {"ParameterKey": "TerraformDirectory", "ParameterValue": "."},
  {"ParameterKey": "TfVarsFile",       "ParameterValue": "envs/prod.tfvars"},
  {"ParameterKey": "BucketName",        "ParameterValue": "tf-artifacts-826136930409"},
  {"ParameterKey": "EnableApproval",    "ParameterValue": "true"},
  {"ParameterKey": "CreateIamRoles",     "ParameterValue": "true"},
  {"ParameterKey": "RolePath",           "ParameterValue": "/application_role/"},
  {"ParameterKey": "NotificationEmail",  "ParameterValue": "team@myorg.com"}
]
```

> Leave `PipelineRoleArn` / `CodeBuildRoleArn` empty. With `CreateIamRoles=true`
> the template creates the roles under `RolePath`.

---

## Step 4: Deploy the stack

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name my-project-prod-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-mypipeline.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

### Verify

```bash
aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].StackStatus" \
  --output text

aws cloudformation describe-stacks \
  --stack-name my-project-prod-tf-pipeline \
  --query "Stacks[0].Outputs" \
  --output table
```

---

## Step 5: Configure the Terraform repository

Copy the buildspecs and the example Terraform module to the **root** of the
Terraform repository:

```bash
cp buildspec/buildspec-plan.yml    /path/to/your-terraform-repo/buildspec-plan.yml
cp buildspec/buildspec-apply.yml   /path/to/your-terraform-repo/buildspec-apply.yml
cp examples/terraform/main.tf      /path/to/your-terraform-repo/main.tf
cp examples/terraform/provider.tf  /path/to/your-terraform-repo/provider.tf
cp -r examples/terraform/envs/     /path/to/your-terraform-repo/
```

- `provider.tf` keeps the AWS provider config (region, `default_tags`, and the
  `assume_role` used to delegate resource CRUD to the execution role). State
  access (`terraform init`) stays on the CodeBuild role in the repo account.
- The `envs/` dir must contain `<environment>.tfvars` (selected via the
  `TfVarsFile` stack parameter). Keep the `<environment>.tfbackend` files in the
  repo (the buildspec references them), but leave their values **empty** — the
  pipeline overrides bucket/key/region/encrypt from stack parameters via
  `-backend-config` flags, so the file is only a placeholder.

### Auto mode (EnableApproval=false)

```bash
cp buildspec/buildspec-auto.yml /path/to/your-terraform-repo/buildspec-auto.yml
```

### Commit and push

```bash
cd /path/to/your-terraform-repo
git add buildspec-*.yml main.tf provider.tf envs/
git commit -m "Add CI/CD buildspecs and Terraform module"
git push origin main
```

The EventBridge trigger starts the pipeline/build automatically on push.

---

## Step 6: Approve (approval mode only)

For `EnableApproval=true`, when the pipeline reaches the **Approve** stage:

- A plan notification is emailed to `NotificationEmail` — it contains the plan
  **summary**, a **presigned download link to `plan.txt`** (valid 7 days, so you
  can review the full plan from mail without console login), and a link to the
  pipeline console.
- Open the pipeline console and review the plan, then choose **Approve** (or **Reject**).
- On approval, the **Apply** stage downloads the exact plan binary and applies it.

> State is written to S3 only on apply: the S3 object at
> `{ProjectName}/state/{Environment}/terraform.tfstate` (e.g.
> `org-infra/state/dev/terraform.tfstate`) appears after the **Apply** stage
> runs. `terraform plan` reads state but does not persist it.

---

## Day-2 Operations

### Verifying remote state in S3

State is written to S3 only when the **Apply** stage succeeds. The object lives
at `{ProjectName}/state/{Environment}/terraform.tfstate` in the shared
`BucketName` bucket — the key is derived (not a parameter). After a successful
apply, confirm:

```bash
aws s3 ls s3://tf-artifacts-826136930409/org-infra/state/dev/
aws s3api get-object --bucket tf-artifacts-826136930409 \
  --key org-infra/state/dev/terraform.tfstate /tmp/terraform.tfstate
grep '"serial"' /tmp/terraform.tfstate || true
```

Sanity rules to keep state location predictable:

- The pipeline derives the backend entirely from parameters — `BucketName` +
  `{ProjectName}/state/{Environment}/terraform.tfstate` — and passes them to
  `terraform init` as `-backend-config` flags that **override** the
  `envs/<env>.tfbackend` file (kept empty in the repo as a placeholder).
- Always deploy the stack and the repo files from the **same** parameter set for
  an environment (e.g. `pipeline-dev.json` ⇒ `envs/dev.tfvars`).
- A plan-only run reads state but does not persist it; recreated demo resources on
  every run is a sign Apply never completed, not a framework fault.
- CodePipeline writes its stage artifacts at the bucket root (`SourceOutput/…`);
  plan binaries/logs live under `{ProjectName}/terraform-artifacts/…`.

### Updating Terraform version

Update `TerraformVersion` in the parameter file and redeploy:

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-framework.yaml \
  --stack-name my-project-prod-tf-pipeline \
  --parameter-overrides file://parameters/pipeline-mypipeline.json \
  --capabilities CAPABILITY_NAMED_IAM
```

### Toggling approval gate

Change `EnableApproval` in the parameter file (e.g. to `"false"`) and redeploy.
The stack will replace the pipeline with the auto CodeBuild project (or vice versa).

### Adding a new repository / environment

1. Copy the relevant buildspec(s) to the new repo.
2. Deploy a new stack with its own parameter file (unique `ProjectName`/`Environment`).
3. Use the same shared bucket (`BucketName`) as the other stacks in the account.
4. Push to trigger.

### Adding an environment to the same repo

Deploy another stack with a different `Environment`. State is kept distinct
automatically via the `{ProjectName}/state/{Environment}/terraform.tfstate` key.

---

## Troubleshooting

| Issue | Check |
|---|---|
| Pipeline/Build not triggering | Confirm the EventBridge rule is enabled (`aws events describe-rule`). Only pushes to `BranchName` on the default bus trigger it. The target role's trust policy must allow `events.amazonaws.com` to assume it (the template's `PipelineRole` includes this; if you pass your own `PipelineRoleArn`, add it manually) |
| Source fails (approval mode, CodeCommit) | Confirm the pipeline role has `codecommit:*` on the repo ARN; a repo policy is NOT needed same-account |
| Auto mode cannot clone (CodeCommit) | Confirm the CodeBuild role has `codecommit:GitPull` (template grants it when `RepositoryProvider=codecommit`) |
| Auto mode cannot clone (GitHub) | Confirm `CodeStarConnectionArn` is set and the connection is **available**; the CodeBuild role has `codestar-connections:UseConnection` |
| Plan fails | CodeBuild logs, state bucket access, Terraform version validity, network egress for provider download |
| Apply fails | Plan binary present in S3 (shared keyed by commit), execution role trust, execution role permissions |
| Auto mode reports "destroy/replace blocked" | The plan contained `must be replaced` or `will be destroyed`. This is intentional — set `EnableApproval=true` to review manually |
| SNS not received | Topic ARN correct, email subscription confirmed, `EnableEmailNotifications=true` |

---

## Deployment Order Summary

```
Step 1: Create shared artifact S3 bucket (once per account)
Step 2: (GitHub only) Create CodeStar Connections connection
Step 3: Prepare the parameter file (CreateIamRoles=true)
Step 4: Deploy terraform-pipeline-framework.yaml
Step 5: Copy buildspec(s) to the Terraform repo and push
Step 6: (Approval mode) Review and approve the plan
```
