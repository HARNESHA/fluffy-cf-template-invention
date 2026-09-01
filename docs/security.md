# Security Considerations

## IAM Least Privilege

Roles are created by the template when `CreateIamRoles=true`. `RolePath` places
them under a team/org path. When `CreateIamRoles=false`, use `PipelineRoleArn` /
`CodeBuildRoleArn` with pre-existing roles that carry the same permissions below.

### CodePipeline Role

Trusts `codepipeline.amazonaws.com`. Permissions (see the template's
`PipelineRolePolicy`):

- `s3:GetObject/PutObject/ListBucket/DeleteObject` on the shared artifact bucket
- CodeCommit source (`codecommit:GetBranch/GetCommit/GetRepository/GetUploadArchiveStatus/UploadArchive/CancelUploadArchive/GitPull`) OR `codestar-connections:UseConnection` for GitHub
- `codepipeline:StartPipelineExecution`, `codebuild:StartBuild/StopBuild/BatchGetBuilds`
- `sns:Publish`, `logs:*` on the pipeline log group

### CodeBuild Role (clone-capable)

Trusts `codebuild.amazonaws.com`. This role can **clone the repository** because
the auto mode clones from inside the build (NO_SOURCE). See the template's
`CodeBuildRolePolicy`:

- `s3:GetObject/PutObject/ListBucket/DeleteObject` on the shared artifact bucket
- `s3:GetObject/PutObject/ListBucket` on the Terraform state bucket
- Clone: `codecommit:GitPull/GetBranch/GetCommit/GetFile/GetFolder/GetTree` OR `codestar-connections:UseConnection`
- `logs:*`, `sns:Publish`, `ssm:GetParameter/GetParameters`
- `sts:AssumeRole` on `ExecutionRoleArn` (optional)

### Terraform Execution Role Pattern (recommended for production)

The CodeBuild role only needs to assume a dedicated execution role that carries
Terraform's infrastructure permissions:

```
CodeBuild Role
  ↓  sts:AssumeRole
Terraform Execution Role
  ↓  has infrastructure permissions
  ↓  manages resources
```

Benefits:
- Build roles stay static and narrowly scoped regardless of what Terraform manages
- The execution role can be updated independently without reconfiguring the pipeline
- CloudTrail records which role was assumed

Execution role trust policy (template: `iam/trust-execution-role.json`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::ACCOUNT_ID:role/TerraformCodeBuildRole"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "terraform-pipeline-PROJECT_NAME"
      }
    }
  }]
}
```

The `ExternalId` condition prevents confused-deputy attacks.

### Auto-mode guard (non-approval)

The auto CodeBuild project refuses to run `terraform apply` when the plan
contains `must be replaced` or `will be destroyed`. This prevents accidental
destructive changes from auto-applying. For environments where a human must
review such changes, set `EnableApproval=true`.

---

## Artifact Security

### Plan Binary Sensitivity

The Terraform plan binary contains the full infrastructure state delta, resource
attribute names, and potentially sensitive values resolved at plan time. Treat it
as sensitive:

- The shared artifact bucket must use SSE-KMS (Customer Managed Key recommended)
- Block public access on the artifact bucket — no exceptions
- Restrict `s3:GetObject` to the CodeBuild and CodePipeline roles only
- Versioning enabled (see [artifact-bucket-guide.md](artifact-bucket-guide.md))
- Apply lifecycle rules to archive/delete expired plans and logs

### KMS Key Rotation

Enable annual automatic rotation on the bucket KMS key:

```bash
aws kms enable-key-rotation --key-id <key-id>
```

Key policy should grant access to the CodeBuild and CodePipeline roles and deny
all other principals except the key admin.

---

## Secrets Management

### Never Use CloudFormation Parameters for Secrets

CloudFormation parameters are stored in plain text and visible in the console.
Do not pass secrets as parameters.

Use SSM Parameter Store (SecureString) or Secrets Manager instead, referenced in
the buildspec:

```yaml
env:
  parameter-store:
    TF_VAR_db_password: "/myapp/prod/db_password"
  secrets-manager:
    TF_VAR_api_key: "myapp/prod/api_key"
```

### Environment Variable Logging

CodeBuild logs environment variable names (not values). Values injected via
`parameter-store` or `secrets-manager` are masked in logs. Plain-text
environment variables are logged verbatim — do not use `PLAINTEXT` for secrets.

---

## Pipeline Integrity

### Preventing Plan Drift

The Apply stage runs `terraform apply tfplan.binary` (the exact binary produced
and shared by the Plan stage), **not** `-auto-approve`. This guarantees:

1. The reviewed plan binary is exactly what gets applied
2. No re-plan occurs between plan and apply
3. State changes between plan and apply cause apply to fail, not silently diverge

Restrict who can start the Apply CodeBuild project outside the pipeline.

### PollForSourceChanges = false

The CodeCommit source uses `PollForSourceChanges: false` — the pipeline is
triggered only by EventBridge. Each execution is tied to a specific commit ID
passed via the EventBridge InputTransformer, eliminating stale-poll races.

### Approval Token Expiry

Manual approval tokens expire after 7 days. An expired token cannot approve a
pipeline — a new execution must be started. This prevents an approval for an old
plan from applying a newer, unapproved change.

---

## CloudWatch Logs Access Control

Build logs contain full Terraform output (resource ARNs, property names,
potentially sensitive computed values). Restrict access:

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "logs:GetLogEvents",
  "Resource": "arn:aws:logs:us-east-1:ACCOUNT_ID:log-group:/codebuild/*:*",
  "Condition": {
    "StringNotEquals": {
      "aws:PrincipalArn": [
        "arn:aws:iam::ACCOUNT_ID:role/PlatformEngineeringRole",
        "arn:aws:iam::ACCOUNT_ID:role/TerraformCodeBuildRole"
      ]
    }
  }
}
```

---

## Network Security

### CodeBuild in a VPC (Recommended for Production)

By default CodeBuild runs on AWS-managed infrastructure with public internet
access. For production, run CodeBuild in a VPC by adding `VpcConfig` to the
CodeBuild project resources.

Required VPC endpoints (to avoid public internet):
- `com.amazonaws.<region>.s3` — artifact + state buckets
- `com.amazonaws.<region>.codecommit` — source checkout
- `com.amazonaws.<region>.codepipeline` — pipeline communication (approval mode)
- `com.amazonaws.<region>.logs` — CloudWatch Logs
- `com.amazonaws.<region>.sts` — execution role assumption
- `com.amazonaws.<region>.sns` — notifications

### Outbound Traffic Restriction

Terraform downloads providers from the Terraform Registry by default. For
air-gapped environments, use a private provider mirror and block outbound
internet except to required AWS endpoints.

---

## CloudTrail & Auditing

Enable CloudTrail and log:
- `codepipeline:*`, `codebuild:*`
- `sts:AssumeRole` — track execution role assumption
- `s3:GetObject/PutObject` on artifact and state buckets

Send logs to a dedicated security bucket with object lock enabled.

---

## Drift Detection

- Run CloudFormation drift detection on each stack (schedule via EventBridge + Lambda).
- Apply AWS Config rules: `required-tags`, `s3-bucket-server-side-encryption-enabled`, `s3-bucket-versioning-enabled`, `cloudtrail-enabled`.

---

## Future Security Enhancements

1. **OPA/Conftest policy gates** — add a CodeBuild stage between Plan and Approve that validates the plan JSON against Open Policy Agent rules.
2. **Signed plan binaries** — sign the plan binary after generation (AWS Signer/GPG) and verify in the Apply stage.
3. **Immutable execution roles** — use SCPs to prevent altering execution roles outside change management.
4. **Automated access review** — quarterly IAM Access Analyzer reports on execution roles.
5. **Secrets rotation** — rotate Terraform secrets in Secrets Manager and re-run after rotation.
