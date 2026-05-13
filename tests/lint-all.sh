#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "============================================"
echo "  Linting all CloudFormation templates"
echo "============================================"
echo ""

"${ROOT_DIR}/shared/lint-cfn.sh"

echo ""
echo "============================================"
echo "  Checking template structure"
echo "============================================"
echo ""

EXIT_CODE=0
TEMPLATES_DIR="${ROOT_DIR}/templates"

while IFS= read -r template_dir; do
    template_name="$(basename "${template_dir}")"
    template_file="${template_dir}/template.yaml"

    echo "  Checking: ${template_dir}"

    if [ ! -f "${template_file}" ]; then
        echo "    MISSING: template.yaml"
        EXIT_CODE=1
    fi

    params_dir="${template_dir}/parameters"
    if [ -d "${params_dir}" ]; then
        if [ ! -f "${params_dir}/dev.json" ]; then
            echo "    MISSING: parameters/dev.json"
            EXIT_CODE=1
        fi
    fi

    echo ""
done < <(find "${TEMPLATES_DIR}" -mindepth 2 -maxdepth 2 -type d)

if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "==> All template structure checks passed"
else
    echo "==> Some template structure checks failed"
fi

exit "${EXIT_CODE}"
