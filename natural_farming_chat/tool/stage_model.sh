#!/usr/bin/env bash
# Stage the Qwen3.5 recipe bundle on a device. The app copies it into its private storage on first launch.
#
#   tool/stage_model.sh [--device SERIAL] [--outputs DIR]
#
# DIR (default: ../outputs next to this app) must hold qwen35-recipe-v5-cactus-cq4-hessian (the calibrated candidate-4 weights)
# and qwen35-combined-cactus-cq4 (the architecture-only Cactus graph files: components/, optimized_ir*.json, raw_ir*.json,
# byte-identical copies kept next to the weights).
set -euo pipefail

slug=qwen35-recipe-v5-cactus-cq4-hessian
graph_source=qwen35-combined-cactus-cq4
cd "$(dirname "$0")/.."
outputs="../outputs"
device="${ANDROID_SERIAL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --device) shift; device="${1:?--device needs a serial}" ;;
    --outputs) shift; outputs="${1:?--outputs needs a directory}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$outputs/$slug" ] || { echo "missing $outputs/$slug" >&2; exit 1; }
[ -d "$outputs/$graph_source/components" ] || { echo "missing $outputs/$graph_source/components" >&2; exit 1; }

adb_args=()
[ -n "$device" ] && adb_args=(-s "$device")
remote="/data/local/tmp/$slug"

adb "${adb_args[@]}" push "$outputs/$slug/." "$remote/"
adb "${adb_args[@]}" push "$outputs/$graph_source/components" "$remote/"
for f in "$outputs/$graph_source"/optimized_ir*.json "$outputs/$graph_source"/raw_ir*.json; do
  adb "${adb_args[@]}" push "$f" "$remote/"
done
echo "staged $slug on the device"
