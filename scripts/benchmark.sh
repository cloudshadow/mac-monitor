#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/swift.sh build -c release --product Benchmark -j 4
mkdir -p artifacts/benchmarks
# Flags are validated by the executable. No machine settings or launchd jobs are changed.
.build/release/Benchmark "$@"
