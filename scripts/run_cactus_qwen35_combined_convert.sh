#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_CACTUS="${PROJECT_ROOT}/vendor/cactus-sdk/venv/bin/cactus"
CACTUS_CLI="${CACTUS_CLI:-${DEFAULT_CACTUS}}"
ADAPTER_DIR="${QWEN35_ADAPTER_DIR:-${PROJECT_ROOT}/outputs/lora-adapter-qwen35-combined/final}"
MERGED_MODEL_DIR="${QWEN35_MERGED_MODEL_DIR:-}"
OUTPUT_DIR="${QWEN35_CACTUS_OUTPUT_DIR:-${PROJECT_ROOT}/outputs/qwen35-combined-cactus-cq4}"

if [[ ! -x "${CACTUS_CLI}" ]]; then
    printf 'Cactus CLI is not executable: %s\n' "${CACTUS_CLI}" >&2
    printf 'Set up the pinned submodule once with: cd vendor/cactus-sdk && source ./setup\n' >&2
    printf 'Set CACTUS_CLI to a compatible Cactus executable.\n' >&2
    exit 1
fi
if [[ -e "${OUTPUT_DIR}" ]]; then
    printf 'Output path already exists: %s\n' "${OUTPUT_DIR}" >&2
    printf 'Set QWEN35_CACTUS_OUTPUT_DIR to a fresh path.\n' >&2
    exit 1
fi

export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
CONVERT_ARGS=(--bits 4 --weights-only --local-files-only)
MODEL_SOURCE="Qwen/Qwen3.5-2B"
if [[ -n "${MERGED_MODEL_DIR}" ]]; then
    if [[ ! -f "${MERGED_MODEL_DIR}/config.json" ]]; then
        printf 'Merged model directory is missing config.json: %s\n' "${MERGED_MODEL_DIR}" >&2
        exit 1
    fi
    MODEL_SOURCE="${MERGED_MODEL_DIR}"
else
    if [[ ! -f "${ADAPTER_DIR}/adapter_config.json" ]]; then
        printf 'LoRA adapter is missing: %s\n' "${ADAPTER_DIR}" >&2
        exit 1
    fi
    CONVERT_ARGS+=(--lora "${ADAPTER_DIR}")
fi

exec "${CACTUS_CLI}" convert "${MODEL_SOURCE}" "${OUTPUT_DIR}" \
    "${CONVERT_ARGS[@]}" "$@"
