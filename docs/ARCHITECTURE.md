# Architecture

## Repository Overview

This repository houses reusable AWS CloudFormation templates organized by service category. Each template is self-contained with its own parameters, scripts, and documentation.

## Directory Layout

```
templates/
├── <category>/                # Service category (cicd, networking, security, etc.)
│   └── <template-name>/       # Individual template
│       ├── template.yaml      # CloudFormation template (single stack, no nesting)
│       ├── parameters/        # Environment-specific parameter files
│       │   ├── dev.json
│       │   ├── qa.json
│       │   ├── uat.json
│       │   └── prod.json
│       ├── scripts/           # Template-specific helper scripts
│       ├── buildspec/         # CodeBuild buildspecs (if applicable)
│       └── README.md          # Template-specific documentation
shared/                         # Shared utilities across templates
├── lint-cfn.sh                # cfn-lint wrapper
└── deploy-stack.sh            # Generic deploy helper
docs/                           # Repository-level documentation
tests/                          # Validation scripts
examples/                       # Usage examples
```

## Design Principles

- **Simplicity** - One CloudFormation stack per template, no nested stacks
- **Self-contained** - Each template directory has everything needed to deploy
- **Minimal sharing** - Only truly cross-cutting utilities go in shared/
- **Environment parity** - Parameter files for dev/qa/uat/prod per template
- **Security first** - Least-privilege IAM, encryption, TLS enforcement
- **GitOps ready** - Templates designed for pipeline deployment

## Template Categories

| Category | Purpose |
|----------|---------|
| `cicd/` | CI/CD pipelines (CodePipeline, CodeBuild) |
| `networking/` | VPC, subnets, TGW, DNS, connectivity |
| `security/` | GuardDuty, Security Hub, IAM baselines, Config |
| `monitoring/` | CloudTrail, dashboards, alerts, logging |
| `data/` | S3 baselines, RDS, backup policies |
| `serverless/` | API Gateway, Lambda, event-driven patterns |
