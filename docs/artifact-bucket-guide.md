# Shared Bucket Guide

This guide describes the single shared S3 bucket that the Terraform Pipeline
Framework uses to store plan binaries, plan/apply logs, build cache, CodePipeline
artifacts, and Terraform remote state for **all** projects and environments in
one account.

## 1. Purpose

The framework uses **one shared bucket** (not one per stack/project). This keeps
IAM simpler, keeps costs low, and centralizes retention/archival governance.
Everything is scoped by project prefix: `{ProjectName}/` for artifacts and
`{ProjectName}/state/{Environment}/terraform.tfstate` for state.

Roles (created by the template) get `s3:GetObject/PutObject/ListBucket/DeleteObject`
scoped to this bucket and its governed path layout. See
[templates/terraform-pipeline-framework.yaml](../templates/terraform-pipeline-framework.yaml).

## 2. Recommended bucket properties

| Property | Recommended setting | Why |
|---|---|---|
| Name | `tf-artifacts-<account-id>` | Globally unique, account-scoped |
| Region | Same as the stacks | Lower latency, single-region governance |
| Versioning | `Enabled` | Recover overwritten/deleted plan artifacts, logs & state |
| Default encryption | `aws:kms` (SSE-KMS) | Plans/logs may contain sensitive resource metadata |
| Public access | Fully blocked | Never public |
| Block all public access | ON | Defense in depth |
| Object lock | Optional | WORM retention if required by policy |
| Bucket key (SSE-KMS) | Enabled | Reduces KMS cost |

> The plan/apply buildspecs upload with `--sse aws:kms`, so the bucket default
> encryption must be SSE-KMS (or the KMS key must permit usage).

## 3. Creating the bucket (CloudFormation)

```yaml
# artifact-bucket.yaml - deploy once per account
Resources:
  SharedBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "tf-artifacts-${AWS::AccountId}"
      VersioningConfiguration:
        Status: Enabled
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: aws:kms
            BucketKeyEnabled: true
      LifecycleConfiguration:
        Rules:
          # One rule set per project prefix (repeat for my-project-a, my-project-b, ...)
          - Id: KeepState
            Status: Enabled
            Prefix: my-project-a/state/
            NoncurrentVersionExpiration:
              NoncurrentDays: 30
          - Id: ExpirePlans
            Status: Enabled
            Prefix: my-project-a/terraform-artifacts/
            Transitions:
              - StorageClass: GLACIER
                TransitionInDays: 90
            ExpirationInDays: 365
      Tags:
        - Key: ManagedBy
          Value: CloudFormation
        - Key: Purpose
          Value: Terraform-artifact-storage
```

Deploy:

```
aws cloudformation create-stack \
  --stack-name tf-artifact-bucket \
  --template-body file://artifact-bucket.yaml
```

## 4. Governed key layout

All framework artifacts are written under the stack's project prefix (derived
from `ProjectName`; the pipeline and buildspecs build the keys automatically):

```
<project-name>/
├── terraform-artifacts/
│   └── <repository-name>/
│       └── <environment>/
│           └── <branch-name>/
│               ├── plans/<commit-id>/
│               │   ├── tfplan.binary
│               │   └── plan.txt
│               └── logs/<codebuild-build-id>/
│                   └── apply.txt
├── state/<environment>/terraform.tfstate
└── <pipeline-name>/      # CodePipeline's own artifact store (bucket root)
```

- **`<project-name>/terraform-artifacts/plans/`** — plan binaries + human-readable
  text, keyed by commit. Apply downloads the exact binary it plans to apply.
- **`<project-name>/terraform-artifacts/logs/`** — apply output, keyed by CodeBuild
  build id.
- **`<project-name>/state/<environment>/`** — Terraform remote state, one
  key per project/environment. Never expire or archive the current version.
- `<pipeline-name>/` — CodePipeline's built-in artifact store (the pipeline maps
  its ArtifactStore to this bucket root; CodePipeline manages its own keys).

## 5. IAM scoping (optional hardening)

You can further restrict roles to a project's governed prefixes by using a
condition on `<project>/terraform-artifacts/`. The template already scopes S3
actions to the whole bucket; to scope to a prefix, add a `StringLike` condition,
for example:

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": ["arn:aws:s3:::BUCKET/my-project/terraform-artifacts/*"],
  "Condition": {
    "StringLike": {
      "s3:prefix": ["my-project/terraform-artifacts/*"]
    }
  }
}
```

## 6. Retention, archival & deletion policy

Recommended lifecycle (one rule set per `<project>/` prefix):

- **Remote state (`state/`):** never transition or expire the current version.
  Prune old versions after **30 days** (`NoncurrentVersionExpiration`) so
  destroyed resources can still be recovered briefly without accruing cost.
- **Plan artifacts (`terraform-artifacts/plans/`):**
  - Move to `GLACIER` (or `DEEP_ARCHIVE`) after **90 days**.
  - Delete after **365 days** from the `GLACIER` transition start (set an
    `ExpirationInDays` relative to object creation).
- **Apply logs (`terraform-artifacts/logs/`):** same lifecycle as plans, or
  shorter depending on compliance.
- **CodePipeline artifact store:** CodePipeline manages its own lifecycle; keep
  versioning on to allow rollback recovery.

Adjust the day counts to your audit/compliance requirements.

## 7. Operators notes

- Regenerate the bucket key / rotate the KMS key per your key-rotation policy.
- Enable S3 server access logging to a separate log bucket if you need
  object-level audit trails for plan/apply/state activity.
- Because this bucket is **shared**, never point a lifecycle rule at the whole
  bucket — always scope by `<project>/` prefix so state is never expired and
  projects don't delete each other's artifacts.
