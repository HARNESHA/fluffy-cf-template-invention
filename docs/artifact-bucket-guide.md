# Artifact Bucket Guide

This guide describes the single shared S3 bucket that the Terraform Pipeline
Framework uses to store plan binaries, plan/apply logs, build cache, and
CodePipeline artifacts for **all** projects and environments in one account.

## 1. Purpose

The framework uses **one shared bucket** (not one per stack/project). This keeps
IAM simpler, keeps costs low, and centralizes retention/archival governance.

Roles (created by the template) get `s3:GetObject/PutObject/ListBucket/DeleteObject`
scoped to this bucket and its governed path layout. See
[templates/terraform-pipeline-framework.yaml](../templates/terraform-pipeline-framework.yaml).

## 2. Recommended bucket properties

| Property | Recommended setting | Why |
|---|---|---|
| Name | `tf-artifacts-<account-id>` | Globally unique, account-scoped |
| Region | Same as the stacks | Lower latency, single-region governance |
| Versioning | `Enabled` | Recover overwritten/deleted plan artifacts & logs |
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
  ArtifactBucket:
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
          - Id: ArchivePlans
            Status: Enabled
            Prefix: terraform-artifacts/
            Transitions:
              - StorageClass: GLACIER
                TransitionInDays: 90
          - Id: DeletePlans
            Status: Enabled
            Prefix: terraform-artifacts/
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

All framework artifacts are written under a single prefix (default
`ArtifactPrefix`, e.g. `terraform-artifacts/`):

```
terraform-artifacts/
├── <repository-name>/
│   └── <environment>/
│       └── <branch-name>/
│           ├── plans/<commit-id>/
│           │   ├── tfplan.binary
│           │   └── plan.txt
│           └── logs/<codebuild-build-id>/
│               └── apply.txt
├── build-cache/<project>-<environment>-<plan|apply|auto>/
└── <pipeline-name>/      # CodePipeline's own artifact store
```

- **plans/** — plan binaries + human-readable text, keyed by commit. Apply
  downloads the exact binary it plans to apply.
- **logs/** — apply output, keyed by CodeBuild build id.
- **build-cache/** — CodeBuild Terraform provider cache.
- `<pipeline-name>/` — CodePipeline's built-in artifact store (the pipeline maps
  its ArtifactStore to this bucket).

## 5. IAM scoping (optional hardening)

You can further restrict roles to the governed prefix by using a condition on
`ArtifactPrefix`. The template already scopes S3 actions to the whole bucket; to
scope to the prefix, add a `StringLike` condition, for example:

```json
{
  "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject"],
  "Resource": ["arn:aws:s3:::BUCKET/terraform-artifacts/*"],
  "Condition": {
    "StringLike": {
      "s3:prefix": ["terraform-artifacts/*"]
    }
  }
}
```

## 6. Retention, archival & deletion policy

Recommended lifecycle:

- **Plan artifacts (plans/):**
  - Move to `GLACIER` (or `DEEP_ARCHIVE`) after **90 days**.
  - Delete after **365 days** from the `GLACIER` transition start (set an
    `ExpirationInDays` relative to object creation).
- **Apply logs (logs/):** same lifecycle as plans, or shorter depending on
  compliance.
- **Build cache:** expire aggressively (e.g. delete after **30 days**) since it
  is regenerable.
- **CodePipeline artifact store:** CodePipeline manages its own lifecycle; keep
  versioning on to allow rollback recovery.

Adjust the day counts to your audit/compliance requirements.

## 7. Operators notes

- Regenerate the bucket key / rotate the KMS key per your key-rotation policy.
- Enable S3 server access logging to a separate log bucket if you need
  object-level audit trails for plan/apply activity.
- Because this bucket is **shared**, name projects/environments clearly in the
  key layout so artifacts are easy to locate and to apply prefix-scoped
  retention policies.
