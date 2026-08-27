# Security Considerations

## IAM Least Privilege

### Template 2 — Absolute Minimum Permissions

The `EventForwarderRole` in Template 2 is the smallest possible IAM role for
its purpose:

```
Action:    events:PutEvents
Resource:  <exact target Event Bus ARN>   ← no wildcards
Trust:     events.amazonaws.com
           Condition: aws:SourceAccount = <repo account>
```

No S3, no CodeCommit, no EC2, no wildcards on resources. If this role is
compromised, the attacker can only send EventBridge events to one specific
Event Bus — they cannot read code, access state, or invoke pipelines directly.

### CodeBuild Role

A single CodeBuild role is shared between Plan and Apply projects. This
simplifies role management while maintaining security through the execution
role pattern:

```
CodeBuildRole (shared)
─────────────────────
s3:GetObject (artifacts)
s3:PutObject (artifacts)
s3:GetObject (state) ← read
s3:PutObject (state) ← write
logs:PutLogEvents
sts:AssumeRole (ExecutionRole)
sns:Publish
```

The CodeBuild role itself has minimal direct permissions. Infrastructure
access is granted through the execution role pattern (recommended).

### Terraform Execution Role Pattern

The execution role pattern is the recommended approach for production:

```
CodeBuild Build Role (pipeline account)
  ↓  sts:AssumeRole
Terraform Execution Role (pipeline account OR target account)
  ↓  has infrastructure permissions
  ↓  manages resources
```

Benefits:
- Build roles remain static and narrowly scoped regardless of what Terraform manages
- Execution role can be updated independently without modifying the pipeline
- In cross-account Terraform deployments, the execution role lives in the target account
- Audit trail: CloudTrail shows which role was assumed and when

Execution role trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": [
        "arn:aws:iam::444455556666:role/TerraformCodeBuildRole"
      ]
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "terraform-pipeline-payments-infra"
      }
    }
  }]
}
```

The `ExternalId` condition prevents confused deputy attacks — a role can only
be assumed by builds that supply the correct external ID.

---

## Artifact Security

### Plan Binary Sensitivity

The Terraform plan binary contains your full infrastructure state delta,
resource attribute names, and potentially sensitive values that Terraform
resolves at plan time. Treat it like sensitive data:

- S3 artifact bucket must use SSE-KMS (Customer Managed Key recommended)
- Block public access on the artifact bucket — no exceptions
- Restrict `s3:GetObject` to CodeBuild and CodePipeline roles only:

```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": [
      "arn:aws:iam::444455556666:role/TerraformCodeBuildRole",
      "arn:aws:iam::444455556666:role/TerraformPipelineServiceRole"
    ]
  },
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Resource": "arn:aws:s3:::my-org-codepipeline-artifacts-444455556666/*"
}
```

### KMS Key Rotation

Use a Customer Managed KMS Key for artifact bucket encryption and enable
annual automatic key rotation:

```bash
aws kms enable-key-rotation --key-id <key-id>
```

Key policy should grant access to CodeBuild roles, CodePipeline role, and
deny all other principals except the key admin.

---

## Secrets Management

### Never Use CloudFormation Parameters for Secrets

CloudFormation parameters are stored in plain text in the stack template and
visible in the console. Do not pass secrets (database passwords, API keys,
tokens) as parameters.

Use SSM Parameter Store (SecureString) or Secrets Manager instead, and
reference them in the buildspec:

```yaml
# In buildspec — pull from SSM Parameter Store
env:
  parameter-store:
    TF_VAR_db_password: "/myapp/prod/db_password"
    TF_VAR_api_key: "/myapp/prod/api_key"

# In buildspec — pull from Secrets Manager
env:
  secrets-manager:
    TF_VAR_slack_token: "myapp/prod/slack:token"
```

### Environment Variable Logging

CodeBuild logs all environment variable names (not values) in the build log.
Sensitive values injected via `parameter-store` or `secrets-manager` are
masked in the log output. Plain-text environment variables are logged verbatim —
do not use `PLAINTEXT` type for sensitive values.

The `TF_EXECUTION_ROLE_ARN` is logged as a plain-text variable — this is
acceptable since role ARNs are not secrets, but be aware that logs are
accessible to anyone with CloudWatch Logs read permission.

---

## Pipeline Integrity

### Preventing Plan Drift

A critical security property: the Apply stage runs `terraform apply tfplan.binary`,
not `terraform apply -auto-approve`. This means:

1. The plan binary approved in the manual gate is exactly what gets applied
2. No re-plan occurs between approval and apply
3. Any state change between plan and apply will cause apply to fail
   (not silently diverge)

If this guarantee is important in your environment, restrict apply build
permissions so operators cannot manually invoke the Apply CodeBuild project
outside of the pipeline — only the pipeline role should be able to start it.

### PollForSourceChanges = false

The CodeCommit source action has `PollForSourceChanges: false`. This means
the pipeline does not poll — it is triggered only by EventBridge. This
eliminates a class of race conditions where a stale poll triggers a pipeline
on an older commit. Every execution is tied to a specific commit ID passed
via the EventBridge InputTransformer.

### Approval Token Expiry

Manual approval tokens expire after 7 days. An expired token cannot be used
to approve the pipeline — a new execution must be started. This prevents
scenarios where an approval for an old plan is mistakenly used to apply a
newer, unapproved change.

---

## CloudWatch Logs Access Control

Pipeline and build logs contain full Terraform output, which includes resource
ARNs, property names, and potentially sensitive computed values. Restrict
CloudWatch Logs access:

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "logs:GetLogEvents",
  "Resource": "arn:aws:logs:us-east-1:444455556666:log-group:/codebuild/*:*",
  "Condition": {
    "StringNotEquals": {
      "aws:PrincipalArn": [
        "arn:aws:iam::444455556666:role/PlatformEngineeringRole",
        "arn:aws:iam::444455556666:role/TerraformCodeBuildRole"
      ]
    }
  }
}
```

Apply this as a resource-based policy via the AWS CLI or as part of your
baseline account configuration in the management account.

---

## Network Security

### CodeBuild in a VPC (Recommended for Production)

By default, CodeBuild runs in AWS-managed infrastructure with public internet
access. For production environments, run CodeBuild inside a VPC:

Add `VpcConfig` to the CodeBuild project resources in the template:

```yaml
VpcConfig:
  VpcId: !Ref VpcId
  Subnets: !Ref PrivateSubnetIds
  SecurityGroupIds: !Ref CodeBuildSecurityGroupIds
```

Required VPC endpoints (to avoid public internet access):
- `com.amazonaws.{region}.s3` — for artifact and state buckets
- `com.amazonaws.{region}.codecommit` — for source checkout
- `com.amazonaws.{region}.codepipeline` — for pipeline communication
- `com.amazonaws.{region}.logs` — for CloudWatch Logs
- `com.amazonaws.{region}.sts` — for role assumption
- `com.amazonaws.{region}.sns` — for notifications

### Outbound Traffic Restriction

Terraform downloads providers from the Terraform Registry by default. For
air-gapped environments or strict egress controls:

1. Use a private Terraform provider mirror hosted on S3 or Artifactory
2. Configure `TF_CLI_ARGS_init` in the buildspec to point to the mirror
3. Block all outbound internet traffic from the CodeBuild VPC except to
   required AWS service endpoints

---

## CloudTrail

Enable CloudTrail in the pipeline account and configure it to log:
- `codepipeline:*` — all pipeline starts, stops, approvals
- `codebuild:*` — all build starts and stops
- `sts:AssumeRole` — track execution role assumption
- `s3:GetObject`, `s3:PutObject` on artifact and state buckets

Send CloudTrail logs to a dedicated security account S3 bucket with
object lock enabled to prevent tampering.

---

## Drift Detection

### CloudFormation Drift

Run CloudFormation drift detection weekly on both StackSets:

```bash
aws cloudformation detect-stack-drift \
  --stack-name payments-infra-prod-tf-pipeline \
  --profile pipeline-account

aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id <detection-id> \
  --profile pipeline-account
```

Schedule this as a recurring EventBridge rule targeting a Lambda that
runs drift detection and publishes results to SNS.

### AWS Config Rules

Apply these Config Rules to the pipeline account:

| Rule | Purpose |
|---|---|
| `required-tags` | Alert if any resource is missing `ManagedBy: CloudFormation` tag |
| `codepipeline-deployment-count-check` | Alert if pipelines have not run recently |
| `s3-bucket-server-side-encryption-enabled` | Enforce encryption on artifact buckets |
| `s3-bucket-versioning-enabled` | Enforce versioning on artifact and state buckets |
| `cloudtrail-enabled` | Verify CloudTrail is active |

---

## Future Security Enhancements

1. **OPA/Conftest policy gates** — Add a CodeBuild stage between Plan and Approve
   that validates the plan JSON against Open Policy Agent rules. Fail the pipeline
   automatically on policy violations.

2. **Signed plan binaries** — Use AWS Signer or GPG to sign the plan binary after
   generation and verify the signature in the Apply stage to detect tampering
   between Plan and Apply.

3. **Immutable execution roles** — Use AWS Service Control Policies (SCPs) to
   prevent operators from modifying execution roles outside of an approved
   change management process.

4. **Automated access review** — Schedule IAM Access Analyzer reports quarterly
   to identify overly permissive execution roles and prune unnecessary permissions.

5. **Secrets rotation** — For any secrets used in Terraform variables, configure
   automatic rotation in Secrets Manager and trigger a pipeline re-run after
   rotation to validate infrastructure still deploys cleanly.
