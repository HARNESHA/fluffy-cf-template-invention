# Contributing

## Adding a New Template

1. **Choose a category** or create a new one under `templates/`
2. **Create the template directory** with the required structure (see TEMPLATE_GUIDE.md)
3. **Write the CloudFormation template** following the conventions
4. **Add parameters files** for dev, qa, uat, prod
5. **Add scripts** if the template needs helper logic
6. **Write a README** documenting the template
7. **Run linting** to validate the template
8. **Submit a pull request**

## Template Requirements

Every template must have:

- `template.yaml` - Single CloudFormation stack (no nested stacks)
- `parameters/dev.json` - At minimum, development parameters
- `README.md` - Template documentation

Recommended:

- `parameters/qa.json`, `parameters/uat.json`, `parameters/prod.json`
- `scripts/` - Any helper scripts needed for deployment or management

## Naming Conventions

- **Template names**: lowercase-kebab-case (e.g., `terraform-pipeline`, `vpc-baseline`)
- **Category names**: lowercase (e.g., `cicd`, `networking`, `security`)
- **Parameter files**: `{environment}.json` (e.g., `dev.json`, `prod.json`)
- **Stack names**: `{project}-{environment}-{template-name}` (e.g., `myproject-dev-tf-pipeline`)

## CloudFormation Conventions

- One template, one stack. No nested stacks.
- Use `Parameters` for all configurable values. No hardcoding.
- Use `Conditions` for optional features (SNS, cross-account, etc.)
- Use `Fn::Sub` and `Fn::If` for dynamic naming and conditional logic
- Use `AWS::NoValue` with `Fn::If` for conditional resource properties
- Follow least-privilege IAM: no `AdministratorAccess`
- Use SSE encryption on all S3 buckets
- Use `DeletionPolicy: Retain` on stateful resources (S3, DynamoDB, etc.)
- Tag all resources where possible

## Validation

Before submitting:

```bash
# Lint all templates
./shared/lint-cfn.sh

# Validate a specific template
cfn-lint templates/<category>/<name>/template.yaml
```
