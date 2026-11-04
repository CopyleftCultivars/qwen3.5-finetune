#!/usr/bin/env bash
# Debug build flow: tool/build_debug.sh [--install] [--device SERIAL] [--skip-tests]
exec "$(dirname "$0")/build.sh" debug "$@"
