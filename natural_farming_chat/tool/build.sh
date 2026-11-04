#!/usr/bin/env bash
# Build the Android app (the only flavor is qwen35) in debug or release mode, optionally install it on a device.
#
#   tool/build.sh debug   [--install] [--device SERIAL] [--skip-tests] [--model-source auto|hosted|staged]
#   tool/build.sh release [--install] [--device SERIAL] [--skip-tests] [--model-source auto|hosted|staged]
#
# --model-source sets where the app gets its model on first launch: hosted = always download from Hugging Face (what a
# new user gets), staged = only use the bundle pushed by tool/stage_model.sh, auto (default) = staged if complete on the
# phone, otherwise download.
#
# Runs `flutter test` first unless --skip-tests. Debug builds are what the benchmark harness uses (it syncs its own test
# files into a disposable copy of this app; see the bioaccumulator-benchmark repo). Release builds are AOT-compiled and
# are what to use on a phone. NOTE: release is still signed with the debug key (android/app/build.gradle.kts); a store
# release needs a real keystore first.
set -euo pipefail

mode="${1:-}"
case "$mode" in debug | release) shift ;; *) echo "usage: $0 debug|release [--install] [--device SERIAL] [--skip-tests] [--model-source auto|hosted|staged]" >&2; exit 2 ;; esac

install=0
tests=1
model_source=auto
device="${ANDROID_SERIAL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --install) install=1 ;;
    --skip-tests) tests=0 ;;
    --device) shift; device="${1:?--device needs a serial}" ;;
    --model-source) shift; model_source="${1:?--model-source needs auto, hosted or staged}" ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$model_source" in auto | hosted | staged) ;; *) echo "--model-source must be auto, hosted or staged" >&2; exit 2 ;; esac

cd "$(dirname "$0")/.."

if [ "$tests" = 1 ]; then
  flutter test
fi

flutter build apk "--$mode" --flavor qwen35 "--dart-define=MODEL_SOURCE=$model_source"
apk="build/app/outputs/flutter-apk/app-qwen35-$mode.apk"
echo "built $apk"

if [ "$install" = 1 ]; then
  adb_args=()
  [ -n "$device" ] && adb_args=(-s "$device")
  adb "${adb_args[@]}" install -r "$apk"
  echo "installed com.copyleftcultivars.natural_farming_chat.qwen35 (model source: $model_source; first launch downloads the model, or copies the staged one)"
fi
