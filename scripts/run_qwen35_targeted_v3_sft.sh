#!/usr/bin/env bash
# #47: retrain the combined Qwen3.5-2B LoRA on the rebalanced #46 corpus v3.
#
# Same base model and LoRA/SFT settings as #44 (run_qwen35_targeted_v2_sft.sh):
# --assistant-only-loss stays on and the #43 target marker is honoured. The one
# recipe addition is --save-total-limit 0, so every per-epoch checkpoint is kept
# for the #47 checkpoint selection (corpus eval loss plus development runs). All
# outputs are new directories; the combined adapter/merged model, the CQ4
# conversion and the #44 targeted-v2 outputs are never overwritten.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PYTHON="${PROJECT_ROOT}/../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python"
TRAIN_PYTHON="${QWEN35_PYTHON:-${DEFAULT_PYTHON}}"
TARGETED_CORPUS="${TARGETED_CORPUS:-${PROJECT_ROOT}/../bioaccumulator-benchmark-workspace/corpus/targeted_v3}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/outputs/lora-adapter-qwen35-targeted-v3}"

if [[ ! -x "${TRAIN_PYTHON}" ]]; then
    printf 'Training Python is not executable: %s\n' "${TRAIN_PYTHON}" >&2
    printf 'Set QWEN35_PYTHON or install the dependencies from requirements-training.txt.\n' >&2
    exit 1
fi

cd "${PROJECT_ROOT}"
exec "${TRAIN_PYTHON}" "${PROJECT_ROOT}/scripts/train_qwen35_sft.py" \
    --train-data "${TARGETED_CORPUS}/train.jsonl" \
    --val-data "${TARGETED_CORPUS}/validation.jsonl" \
    --output-dir "${OUTPUT_DIR}" \
    --run-name qwen35-2b-targeted-v3-assistant-mask \
    --epochs 4 \
    --batch-size 1 \
    --grad-accum 16 \
    --max-seq-len 4096 \
    --eval-strategy epoch \
    --save-total-limit 0 \
    --fail-on-truncation \
    --assistant-only-loss \
    "$@"
