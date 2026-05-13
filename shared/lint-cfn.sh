#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_DIR="${ROOT_DIR}/templates"

echo "==> Running cfn-lint on all CloudFormation templates"
echo ""

EXIT_CODE=0

while IFS= read -r template; do
    echo "  Linting: ${template}"
    if command -v cfn-lint &> /dev/null; then
        cfn-lint "${template}" || EXIT_CODE=1
    else
        echo "  WARNING: cfn-lint not installed. Install with: pip install cfn-lint"
        echo "  Skipping lint for: ${template}"
    fi
    echo ""
done < <(find "${TEMPLATES_DIR}" -name "template.yaml" -type f)

if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "==> All templates passed linting"
else
    echo "==> Some templates failed linting"
fi

exit "${EXIT_CODE}"
