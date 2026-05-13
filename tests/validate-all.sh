#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES_DIR="${ROOT_DIR}/templates"

echo "============================================"
echo "  Validating CloudFormation templates"
echo "============================================"
echo ""

EXIT_CODE=0

while IFS= read -r template; do
    echo "  Validating: ${template}"
    aws cloudformation validate-template \
        --template-body file://"${template}" \
        --output text \
        --query 'Description' > /dev/null 2>&1 && \
        echo "    PASS" || { echo "    FAIL"; EXIT_CODE=1; }
done < <(find "${TEMPLATES_DIR}" -name "template.yaml" -type f)

echo ""
if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "==> All templates validated successfully"
else
    echo "==> Some templates failed validation"
fi

exit "${EXIT_CODE}"
