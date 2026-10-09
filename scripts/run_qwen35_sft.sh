#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PYTHON="${PROJECT_ROOT}/../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python"
TRAIN_PYTHON="${QWEN35_PYTHON:-${DEFAULT_PYTHON}}"

if [[ ! -x "${TRAIN_PYTHON}" ]]; then
    printf 'Training Python is not executable: %s\n' "${TRAIN_PYTHON}" >&2
    printf 'Set QWEN35_PYTHON or install the dependencies from requirements-training.txt.\n' >&2
    exit 1
fi

cd "${PROJECT_ROOT}"
exec "${TRAIN_PYTHON}" "${PROJECT_ROOT}/scripts/train_qwen35_sft.py" "$@"
