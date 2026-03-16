#!/usr/bin/env bash
set -euo pipefail

# Manual benchmark harness for Phase 0 scale-smoke coverage.
# Usage:
#   tools/phase0_scale_benchmark.sh [max_seconds]
#
# Default threshold is intentionally conservative to reduce machine variance.
MAX_SECONDS="${1:-20}"

START_TS="$(date +%s)"
bazel test //auto_dotnet/tests:scale_smoke_test --nocache_test_results >/dev/null
END_TS="$(date +%s)"

ELAPSED="$((END_TS - START_TS))"
echo "Phase 0 scale benchmark elapsed: ${ELAPSED}s (threshold: ${MAX_SECONDS}s)"

if [[ "${ELAPSED}" -gt "${MAX_SECONDS}" ]]; then
  echo "Benchmark exceeded threshold."
  exit 1
fi

echo "Benchmark within threshold."
