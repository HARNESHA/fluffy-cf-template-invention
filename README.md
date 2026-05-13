# Global CloudFormation Templates

Enterprise-grade, reusable AWS CloudFormation templates organized by service category. Designed for platform teams, landing zones, and multi-account environments.

## Repository Structure

```
.
├── templates/                      # CloudFormation templates by category
│   ├── cicd/                       # CI/CD pipelines
│   │   └── terraform-pipeline/     # Complete Terraform CI/CD platform
│   ├── networking/                 # Network infrastructure
│   │   └── vpc-baseline/           # Multi-AZ VPC (placeholder)
│   ├── security/                   # Security and compliance
│   │   ├── guardduty/              # GuardDuty activation (placeholder)
│   │   ├── security-hub/           # Security Hub standards (placeholder)
│   │   ├── iam-baseline/           # IAM password policy, roles (placeholder)
│   │   └── config-baseline/        # AWS Config rules (placeholder)
│   ├── monitoring/                 # Observability
│   │   ├── cloudtrail/             # Organization CloudTrail (placeholder)
│   │   └── dashboards/             # CloudWatch dashboards (placeholder)
│   ├── data/                       # Data infrastructure
│   │   ├── s3-baseline/            # Secure S3 buckets (placeholder)
│   │   └── rds-baseline/           # RDS instances (placeholder)
│   └── serverless/                 # Serverless infrastructure
│       └── api-gateway-baseline/   # API Gateway + Lambda (placeholder)
├── shared/                         # Shared utilities
│   ├── lint-cfn.sh                 # cfn-lint wrapper
│   └── deploy-stack.sh             # Generic deploy helper
├── docs/                           # Documentation
│   ├── ARCHITECTURE.md             # Architecture overview
│   ├── CONTRIBUTING.md             # How to contribute
│   └── TEMPLATE_GUIDE.md           # Template authoring conventions
├── tests/                          # Validation scripts
│   ├── lint-all.sh                 # Lint all templates
│   └── validate-all.sh             # Validate all templates
└── examples/                       # Usage examples
    └── deploy-commands.md          # Example deploy commands
```

## Design Principles

- **Simplicity** - One stack per template. No nested stacks.
- **Self-contained** - Each template has its own params, scripts, and docs.
- **Security first** - Least-privilege IAM, encryption, TLS enforcement.
- **Environment parity** - Parameter files for dev/qa/uat/prod per template.
- **GitOps ready** - Templates designed for pipeline deployment.

## Quick Start

```bash
# Lint all templates
./shared/lint-cfn.sh

# Deploy a template
./shared/deploy-stack.sh \
    cicd/terraform-pipeline \
    myproject-dev-tf-pipeline \
    templates/cicd/terraform-pipeline/parameters/dev.json

# Or directly
aws cloudformation deploy \
    --template-file templates/cicd/terraform-pipeline/template.yaml \
    --stack-name myproject-dev-tf-pipeline \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides file://templates/cicd/terraform-pipeline/parameters/dev.json
```

## Template Categories

| Category | Description |
|----------|-------------|
| `cicd/` | CI/CD pipelines (CodePipeline, CodeBuild) for infrastructure deployment |
| `networking/` | VPC, subnets, routing, connectivity |
| `security/` | GuardDuty, Security Hub, IAM, Config |
| `monitoring/` | CloudTrail, dashboards, alerts |
| `data/` | S3, RDS, backup policies |
| `serverless/` | API Gateway, Lambda, event-driven patterns |

## Available Templates

| Template | Status | Description |
|----------|--------|-------------|
| `cicd/terraform-pipeline` | Complete | Terraform CI/CD with CodePipeline, CodeBuild, S3 backend, native lockfile |
| `networking/vpc-baseline` | Placeholder | Multi-AZ VPC with public/private subnets (coming soon) |
| `security/guardduty` | Placeholder | GuardDuty with S3 protection (coming soon) |
| `security/security-hub` | Placeholder | Security Hub with CIS/PCI/FSBP standards (coming soon) |
| `security/iam-baseline` | Placeholder | IAM password policy and permission boundaries (coming soon) |
| `security/config-baseline` | Placeholder | AWS Config rules and remediation (coming soon) |
| `monitoring/cloudtrail` | Placeholder | Organization CloudTrail trail (coming soon) |
| `monitoring/dashboards` | Placeholder | CloudWatch dashboards and alarms (coming soon) |
| `data/s3-baseline` | Placeholder | Secure S3 with encryption and lifecycle (coming soon) |
| `data/rds-baseline` | Placeholder | RDS with Multi-AZ and encryption (coming soon) |
| `serverless/api-gateway-baseline` | Placeholder | API Gateway with Lambda integration (coming soon) |

## Documentation

- [Architecture](docs/ARCHITECTURE.md) - Repository architecture and design
- [Contributing](docs/CONTRIBUTING.md) - How to add new templates
- [Template Guide](docs/TEMPLATE_GUIDE.md) - Conventions for authoring templates
- [Deployment Examples](examples/deploy-commands.md) - Example deploy commands
