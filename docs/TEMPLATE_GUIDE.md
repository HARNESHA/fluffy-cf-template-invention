# Template Authoring Guide

## Standard Template Structure

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: "Brief description of what this template does"

Parameters:
  <service-name>:
    Type: String
    Description: "..."
  # ... project, environment, and service-specific params

Conditions:
  # ... Fn::If conditions for optional features

Resources:
  # ... AWS resources

Outputs:
  # ... useful references for consumers
```

## Required Parameters

Every template should include these common parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `ProjectName` | String | Project/system identifier for resource naming |
| `EnvironmentName` | String | AllowedValues: dev, qa, uat, prod |

## Required Resources

### S3 Buckets
- Enable `VersioningConfiguration`
- Enable `BucketEncryption` with `SSEAlgorithm: AES256`
- Enable `PublicAccessBlockConfiguration` (all four blocks)
- Add `EnforceTlsRequests` bucket policy
- Set `DeletionPolicy: Retain` on stateful buckets

### IAM Roles
- Use service-specific trust policies (e.g., `codepipeline.amazonaws.com`)
- Use least-privilege policies - no `AdministratorAccess`
- Use `AWS::NoValue` with `Fn::If` for conditional IAM statements

### CloudWatch Logs
- Create log groups for services
- Set `RetentionInDays: 30` (or parameterized)
- Reference log groups in IAM policies

## IAM Best Practices

```yaml
# Good: scoped permissions
Sid: SpecificServiceAccess
Effect: Allow
Action:
  - s3:GetObject
  - s3:PutObject
Resource:
  - !Sub "${Bucket.Arn}"
  - !Sub "${Bucket.Arn}/*"

# BAD: never use AdministratorAccess
```

## Conditional Resources

```yaml
# Condition
EnableFeature: !Not [!Equals [!Ref FeatureParam, ""]]

# Resource
OptionalResource:
  Type: AWS::Some::Resource
  Condition: EnableFeature

# Conditional property
Property: !If
  - EnableFeature
  - !Ref SomeResource
  - !Ref "AWS::NoValue"

# Conditional IAM statement
Statement:
  - !If
    - EnableFeature
    -
      Sid: ConditionalAccess
      Effect: Allow
      Action: service:Action
      Resource: !Ref SomeArn
    - !Ref "AWS::NoValue"
```

## Outputs

Expose useful information for consumers:

```yaml
Outputs:
  ResourceName:
    Description: "..."
    Value: !Ref Resource
  ResourceArn:
    Description: "..."
    Value: !Sub "arn:aws:..."
```

## Parameter Files

Parameter files are JSON formatted for `aws cloudformation deploy`:

```json
{
  "Parameters": {
    "ProjectName": "myproject",
    "EnvironmentName": "dev"
  }
}
```
