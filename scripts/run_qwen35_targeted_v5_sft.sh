#!/usr/bin/env bash
# #63: retrain the Qwen3.5-2B LoRA on the #63 app-rendered SFT corpus v5.
#
# Same base model and LoRA/SFT recipe as #59 (run_qwen35_targeted_v4_sft.sh); the
# new corpus (targeted_v5) declares `render: app_chat_template`, so this run adds
# `--render app_chat_template`, which renders the app/Cactus serving bytes (the
# assistant generation boundary starts with the empty think block
# `<think>\n\n</think>\n\n`) and masks that empty block out of the loss. The
# fidelity-weighted assumption/top-up instruction rows are already baked into
# targeted_v5. `--assistant-only-loss` is implied by `--render app_chat_template`
# and is kept explicit for readability. All outputs are new directories; the
# combined adapter/merged model, the CQ4 conversion and the #44/#47/#59 outputs
# are never overwritten. The owner's uncommitted natural_farming_chat files are
# never touched.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PYTHON="${PROJECT_ROOT}/../localllm-qwen3.5/retry-evidence/q1-isolated/venv/bin/python"
TRAIN_PYTHON="${QWEN35_PYTHON:-${DEFAULT_PYTHON}}"
TARGETED_CORPUS="${TARGETED_CORPUS:-${PROJECT_ROOT}/../bioaccumulator-benchmark-workspace/corpus/targeted_v5}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/outputs/lora-adapter-qwen35-recipe-v5}"

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
    --run-name qwen35-2b-recipe-v5-app-render \
    --epochs 4 \
    --batch-size 1 \
    --grad-accum 16 \
    --max-seq-len 4096 \
    --eval-strategy epoch \
    --save-total-limit 0 \
    --fail-on-truncation \
    --assistant-only-loss \
    --render app_chat_template \
    "$@"
