# Deployment Examples

## Prerequisites

```bash
# Install cfn-lint
pip install cfn-lint

# Configure AWS credentials
aws configure
```

## Terraform Pipeline

### Dev (no approval, direct deploy)

```bash
aws cloudformation deploy \
    --template-file templates/cicd/terraform-pipeline/template.yaml \
    --stack-name myproject-dev-tf-pipeline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        ProjectName=myproject \
        EnvironmentName=dev \
        TerraformRepoName=my-terraform-repo \
        TerraformRepoBranch=develop \
        TerraformVersion=1.10.5 \
        ArtifactBucketName=myproject-dev-tf-artifacts \
        BackendBucketName=myproject-dev-tf-state \
        EnableManualApproval=No \
        CodeBuildComputeType=BUILD_GENERAL1_SMALL \
        TerraformRootPath=.
```

Or using parameter file:

```bash
./shared/deploy-stack.sh \
    cicd/terraform-pipeline \
    myproject-dev-tf-pipeline \
    templates/cicd/terraform-pipeline/parameters/dev.json
```

### QA (approval enabled)

```bash
./shared/deploy-stack.sh \
    cicd/terraform-pipeline \
    myproject-qa-tf-pipeline \
    templates/cicd/terraform-pipeline/parameters/qa.json
```

### Prod (cross-account)

```bash
./shared/deploy-stack.sh \
    cicd/terraform-pipeline \
    myproject-prod-tf-pipeline \
    templates/cicd/terraform-pipeline/parameters/prod.json
```

## Using Parameter Files

```bash
aws cloudformation deploy \
    --template-file templates/<category>/<name>/template.yaml \
    --stack-name <project>-<env>-<name> \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides file://templates/<category>/<name>/parameters/<env>.json
```

## Using the Generic Deploy Script

```bash
./shared/deploy-stack.sh <category>/<name> <stack-name> <params-file> [extra-args]

# Example:
./shared/deploy-stack.sh \
    cicd/terraform-pipeline \
    myproject-dev-tf-pipeline \
    templates/cicd/terraform-pipeline/parameters/dev.json \
    --tags Project=myproject Environment=dev ManagedBy=CloudFormation
```

## Lint and Validate

```bash
# Lint all templates
./shared/lint-cfn.sh

# Run full test suite
./tests/lint-all.sh
./tests/validate-all.sh
```
