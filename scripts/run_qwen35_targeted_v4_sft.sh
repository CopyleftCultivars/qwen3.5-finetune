#!/usr/bin/env bash
# #59: retrain the Qwen3.5-2B LoRA on the #58 trigger-recipe SFT corpus v4.
#
# Same base model and LoRA/SFT recipe as #44/#47 (run_qwen35_targeted_v3_sft.sh):
# --assistant-only-loss stays on and the #43/#58 target markup is honoured; the
# only changes are the corpus (targeted_v4) and the new output directory.
# --save-total-limit 0 keeps every per-epoch checkpoint for the #59 development
# checkpoint selection. All outputs are new directories; the combined adapter/
# merged model, the CQ4 conversion and the #44 targeted-v2 / #47 targeted-v3
# outputs are never overwritten. The owner's uncommitted natural_farming_chat
# files are never touched.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PYTHON="${PROJECT_ROOT}/../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python"
TRAIN_PYTHON="${QWEN35_PYTHON:-${DEFAULT_PYTHON}}"
TARGETED_CORPUS="${TARGETED_CORPUS:-${PROJECT_ROOT}/../bioaccumulator-benchmark-workspace/corpus/targeted_v4}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/outputs/lora-adapter-qwen35-recipe-v4}"

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
    --run-name qwen35-2b-recipe-v4-assistant-mask \
    --epochs 4 \
    --batch-size 1 \
    --grad-accum 16 \
    --max-seq-len 4096 \
    --eval-strategy epoch \
    --save-total-limit 0 \
    --fail-on-truncation \
    --assistant-only-loss \
    "$@"
