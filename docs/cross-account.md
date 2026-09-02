# Cross-Account / Cross-Region CodeCommit Source

This guide covers `templates/terraform-pipeline-cross-account.yaml`, a variant of
the framework where the **CodeCommit source repository lives in a different AWS
account and/or region** than the pipeline. All orchestration (pipeline,
CodeBuild, S3, SNS, IAM for the pipeline) lives in the pipeline account where the
stack is deployed.

> Same-account **cross-region** works too: just set `RepositoryAccountId` to the
> pipeline's own account ID and `RepositoryRegion` to the repo's region.

---

## How it works (why three sides must be opened)

CodeCommit has **no repository-level resource policy**. To let a pipeline in one
account source a repo in another, CodePipeline's Source action needs:

1. A **cross-account IAM role in the repo account** (`SourceRoleArn`) that the
   pipeline's service role can `sts:AssumeRole` to read the repo.
2. A **customer-managed KMS key in the pipeline account** that is shared with the
   repo account, so the Source action can encrypt the source output artifact.
3. An **S3 bucket policy on the pipeline account's artifact bucket** granting the
   repo-account role write access (the Source action writes its output artifact
   into that bucket).

These are the **three-sided allow**. Each side must approve the other:

| Side | What it allows | Who does it |
|---|---|---|
| Pipeline role `sts:AssumeRole` on `SourceRoleArn` | Template (auto, when `SourceRoleArn` set) | pipeline account |
| Repo-account role trust policy → pipeline role | You, via CLI (below) | repo account |
| Repo-account role identity policy → `codecommit:*` on the remote repo | You, via CLI (below) | repo account |
| Repo-account role identity policy → `s3:*` on the artifact bucket | You, via CLI (below, or the template's bucket policy) | repo account |
| Repo-account role identity policy → `kms:*` on the shared key | You, via CLI (below) | repo account |
| Artifact bucket policy → repo-account role | Template (auto, when `GrantBucketToRepoAccount=true`) | pipeline account |
| Shared KMS key policy → repo-account role | You, via CLI (below) | pipeline account |

**Chicken-and-egg note:** the pipeline role name is deterministic —
`{ProjectName}-{Environment}-pipeline-role` — so the repo account can pre-create
the cross-account role **trusting that ARN before the stack exists**. Create the
repo-account role first, then deploy the stack.

---

## Prerequisites

- Two AWS accounts (or one account + two regions for the cross-region test):
  - **Repo account** (`REPO_ACCOUNT`) — owns the CodeCommit repo.
  - **Pipeline account** (`PIPE_ACCOUNT`) — wherever you deploy the stack.
- A shared, versioned, SSE-KMS-encrypted S3 bucket in the **pipeline account**
  (see `docs/artifact-bucket-guide.md`). You pass it as `BucketName`.
- AWS CLI v2 in both accounts, with `CAPABILITY_NAMED_IAM`.

Throughout, let:

```bash
REPO_ACCOUNT=654654593856
PIPE_ACCOUNT=677748260495
PIPE_REGION=ap-south-1          # pipeline region (deploy target)
REPO_REGION=us-east-1           # repo region
REPO_NAME=lakeformation
PROJECT=lakeformation
ENV=test
ROLE_PATH=/                     # must match RolePath used in the stack
```

> Cross-account tests under a single SuperAdmin principal need every role to
> actually need to assume the other role; the pattern below is the standard
> least-privilege cross-account codecommit source.

---

## Step 1: Repo-account — cross-account source role + key + perms

Run this against the **repo account**.

Create the trust policy file. It trusts the pipeline account's deterministic
service role to assume it (`codepipeline.amazonaws.com` **and**
`codebuild.amazonaws.com` for auto mode):

```bash
cat > /tmp/source-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${PIPE_ACCOUNT}:role/${PROJECT}-${ENV}-pipeline-role"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${PIPE_ACCOUNT}:role/${PROJECT}-${ENV}-codebuild-role"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

> With `CreateIamRoles=true` and `RolePath=/application_role/`, use
> `arn:aws:iam::<PIPE>:` role ARN including the path, e.g.
> `arn:aws:iam::${PIPE_ACCOUNT}:role/application_role/${PROJECT}-${ENV}-pipeline-role`.

Create the role:

```bash
aws iam create-role \
  --role-name "${PROJECT}-cross-account-source-role" \
  --path "${ROLE_PATH}" \
  --assume-role-policy-document file:///tmp/source-trust.json \
  --region us-east-1
```

Attach the identity policy giving the role `codecommit` (on the remote repo) plus
`s3`/`kms` (on the pipeline account's artifact bucket + shared key):

```bash
cat > /tmp/source-perms.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodeCommitRead",
      "Effect": "Allow",
      "Action": [
        "codecommit:GetBranch","codecommit:GetCommit","codecommit:GetRepository",
        "codecommit:GetUploadArchiveStatus","codecommit:UploadArchive",
        "codecommit:CancelUploadArchive","codecommit:GitPull",
        "codecommit:ListBranches","codecommit:GetFile",
        "codecommit:GetFolder","codecommit:GetTree"
      ],
      "Resource": "arn:aws:codecommit:${REPO_REGION}:${REPO_ACCOUNT}:${REPO_NAME}"
    },
    {
      "Sid": "ArtifactBucketWrite",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:GetBucketLocation",
        "s3:GetBucketVersioning","s3:ListBucket","s3:PutObject","s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    },
    {
      "Sid": "SharedKmsDecryptEncrypt",
      "Effect": "Allow",
      "Action": ["kms:Decrypt","kms:GenerateDataKey","kms:ReEncryptFrom",
        "kms:ReEncryptTo","kms:DescribeKey"],
      "Resource": "${KMS_KEY_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${PROJECT}-cross-account-source-role" \
  --policy-name "${PROJECT}-cross-account-source-policy" \
  --policy-document file:///tmp/source-perms.json \
  --region us-east-1
```

> `${BUCKET_NAME}` is the pipeline account's shared bucket and `${KMS_KEY_ARN}`
> is the shared key ARN (Step 3). Fill them in the JSON before uploading.

---

## Step 2: Pipeline account — shared KMS key (once)

Run this against the **pipeline account**. Create a customer-managed key and add a
key policy grant that lets the **repo-account source role** use it:

```bash
KMS_KEY_ID=$(aws kms create-key \
  --description "Terraform pipeline cross-account artifact key" \
  --region ${PIPE_REGION} \
  --query "KeyMetadata.KeyId" --output text)

KMS_KEY_ARN=$(aws kms describe-key --key-id ${KMS_KEY_ID} \
  --region ${PIPE_REGION} --query "KeyMetadata.Arn" --output text)
echo "KMS_KEY_ID=$KMS_KEY_ID"
echo "KMS_KEY_ARN=$KMS_KEY_ARN"
```

Add a statement to the key policy granting the repo-account source role:

```bash
aws kms put-key-policy --key-id ${KMS_KEY_ID} \
  --policy-name default \
  --region ${PIPE_REGION} \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "EnableIAM",
        "Effect": "Allow",
        "Principal": {"AWS": "arn:aws:iam::'"${PIPE_ACCOUNT}"':root"},
        "Action": "kms:*",
        "Resource": "*"
      },
      {
        "Sid": "AllowRepoSourceRole",
        "Effect": "Allow",
        "Principal": {"AWS": "arn:aws:iam::'"${REPO_ACCOUNT}"':role/'"${PROJECT}"'-cross-account-source-role"},
        "Action": ["kms:Decrypt","kms:GenerateDataKey","kms:ReEncryptFrom","kms:ReEncryptTo","kms:DescribeKey"],
        "Resource": "*"
      }
    ]
  }'
```

> Grant the repo account on a **shared** key in the pipeline account. Do **not**
> use a key owned by the repo account for artifacts written into the pipeline
> account's bucket.

---

## Step 3: Deploy the stack (pipeline account)

Run against the **pipeline account**, in `PIPE_REGION`.

Edit `parameters/cross-account-<env>.json` and fill in the real values
(`BucketName`, `EncryptionKeyId`, `NotificationEmail`). Key params:

| Parameter | Value | Purpose |
|---|---|---|
| `RepositoryName` | `lakeformation` | Remote repo name |
| `RepositoryAccountId` | `654654593856` | Repo owner account |
| `RepositoryRegion` | `us-east-1` | Repo region |
| `SourceRoleArn` | `arn:aws:iam::654654593856:role/lakeformation-cross-account-source-role` | Cross-account role (Step 1). Empty = same-account |
| `EncryptionKeyId` | KMS key ARN from Step 2 | Shared key; empty = default key |
| `GrantBucketToRepoAccount` | `true` | Adds the artifact bucket policy |
| `BucketName` | pipeline account shared bucket | Artifacts + state |

Deploy:

```bash
aws cloudformation deploy \
  --template-file templates/terraform-pipeline-cross-account.yaml \
  --stack-name lakeformation-test-tf-pipeline \
  --parameter-overrides file://parameters/cross-account-test.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ${PIPE_REGION}
```

### Verify

```bash
aws cloudformation describe-stacks \
  --stack-name lakeformation-test-tf-pipeline \
  --query "Stacks[0].StackStatus" --output text --region ${PIPE_REGION}

aws cloudformation describe-stacks \
  --stack-name lakeformation-test-tf-pipeline \
  --query "Stacks[0].Outputs" --output table --region ${PIPE_REGION}
```

Confirm artifacts:

```bash
aws s3api get-bucket-policy --bucket ${BUCKET_NAME} \
  --region ${PIPE_REGION} --query Policy --output text | \
  python3 -m json.tool   # has Sid: CrossAccountPipelineSource
```

> If `GrantBucketToRepoAccount=false` (bring-your-own bucket), add the bucket
> policy manually, scoped to the repo-account source role.

---

## Step 4: Push to the repo and confirm the source picks it up

Native **source polling** (no EventBridge) watches the remote CodeCommit repo.
Push to the monitored branch:

```bash
cd /path/to/lakeformation/repo
git push origin test
```

CodePipeline polls (up to ~1 min) and starts a run. Watch:

```bash
aws codepipeline list-pipeline-executions \
  --pipeline-name lakeformation-test-tf-pipeline \
  --region ${PIPE_REGION} --query "pipelineExecutionSummaries[0]"
```

---

## Same-account cross-region (single-account test)

If you only have one account, cross-account behavior can't be fully verified, but
the **cross-region** path exercises the same remote-ARN logic:

```json
"RepositoryAccountId": "YOUR_OWN_ACCOUNT_ID",
"RepositoryRegion":     "us-east-1",
"SourceRoleArn":        "",            // same-account: pipeline uses its own role
"EncryptionKeyId":      "",            // same-account: default key is fine
"GrantBucketToRepoAccount": "false"
```

Deploy the stack in a **different region** than `us-east-1` (e.g.
`ap-south-1`), with `RepositoryRegion=us-east-1`. The pipeline's CodeCommit source
ARN is now region-scoped to the remote region, and the CodeBuild/auto modes clone
from that region. Only a true second account exercises the assume-role + shared
KMS + bucket-policy path that the template and this guide describe.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Source action "Access Denied" | `sts:AssumeRole` missing on the pipeline role (should be auto when `SourceRoleArn` set), or the repo-account role trust policy doesn't list the pipeline role ARN |
| Source action can't read commits | Repo-account role identity policy lacks the `codecommit:*` actions on the remote repo ARN |
| Artifact bucket "access denied" on Source output | Repo-account role lacks `s3:*` on the pipeline account's bucket, or the bucket policy (`GrantBucketToRepoAccount=true`) is missing |
| Artifact "encryption error" | Shared `EncryptionKeyId` not set in the stack, the key policy doesn't grant the repo-account role, or the Key is missing `s3:PutObject` on the encrypted object |
| Auto mode can't clone | The CodeBuild role assumes `SourceRoleArn` to get codecommit credentials; confirm both trust policies and the role's `codecommit:GitPull` on the remote ARN |
| Region mismatch | `RepositoryRegion` must match the repo's actual region; pipeline stays in its own region |

---

## Deployment Order Summary

```
Step 1: (repo acct)  create cross-account source role + identity policy
Step 2: (pipeline acct) create shared KMS key + key policy grant
Step 3: (pipeline acct) deploy terraform-pipeline-cross-account.yaml
Step 4: push to remote repo branch; native source-polling triggers the run
```
