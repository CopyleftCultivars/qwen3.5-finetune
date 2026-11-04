#!/usr/bin/env bash
# Release build flow: tool/build_release.sh [--install] [--device SERIAL] [--skip-tests]
exec "$(dirname "$0")/build.sh" release "$@"
