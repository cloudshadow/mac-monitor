#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/package-app.sh "${1:-0.1.13}"
printf 'Development bundle: %s/artifacts/package/%s/Mac Monitor.app\n' "$PWD" "${CMM_ARCH:-$(uname -m)}"
