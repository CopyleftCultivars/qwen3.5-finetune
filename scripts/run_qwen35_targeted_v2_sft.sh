#!/usr/bin/env bash
# #44: retrain the combined Qwen3.5-2B LoRA on the #43 targeted corpus.
#
# Same base model and LoRA/SFT settings as run_qwen35_combined_sft.sh. The only
# recipe change is --assistant-only-loss, which honours the #43 target marker so
# system/user/history tokens are masked and only the final assistant turn is
# learned. Outputs go to new directories; the existing combined adapter/merged
# model and the CQ4 conversion are never overwritten.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PYTHON="${PROJECT_ROOT}/../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python"
TRAIN_PYTHON="${QWEN35_PYTHON:-${DEFAULT_PYTHON}}"
TARGETED_CORPUS="${TARGETED_CORPUS:-${PROJECT_ROOT}/../bioaccumulator-benchmark-workspace/corpus/targeted_v2}"

if [[ ! -x "${TRAIN_PYTHON}" ]]; then
    printf 'Training Python is not executable: %s\n' "${TRAIN_PYTHON}" >&2
    printf 'Set QWEN35_PYTHON or install the dependencies from requirements-training.txt.\n' >&2
    exit 1
fi

cd "${PROJECT_ROOT}"
exec "${TRAIN_PYTHON}" "${PROJECT_ROOT}/scripts/train_qwen35_sft.py" \
    --train-data "${TARGETED_CORPUS}/train.jsonl" \
    --val-data "${TARGETED_CORPUS}/validation.jsonl" \
    --output-dir "${PROJECT_ROOT}/outputs/lora-adapter-qwen35-targeted-v2" \
    --run-name qwen35-2b-targeted-v2-assistant-mask \
    --epochs 4 \
    --batch-size 1 \
    --grad-accum 16 \
    --max-seq-len 4096 \
    --eval-strategy epoch \
    --fail-on-truncation \
    --assistant-only-loss \
    "$@"
