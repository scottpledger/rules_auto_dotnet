#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_file="$(mktemp)"
trap 'rm -f "${log_file}"' EXIT

cd "${script_dir}"

if bazel build @dotnet_projects//:diagnostics.json >"${log_file}" 2>&1; then
    echo "Expected strict diagnostics failure, but build succeeded."
    cat "${log_file}"
    exit 1
fi

python3 - "${log_file}" <<'PY'
import pathlib
import sys

log_file = pathlib.Path(sys.argv[1])
content = log_file.read_text(encoding="utf-8")

required = [
    "Paket strict mode diagnostic: Workspace uses Paket projects but paket.dependencies is set-to-strict-without-bang and must include `references: strict!`.",
    "Paket diagnostic: Project imports Paket restore targets but no paket.references was found.",
    "InternalsVisibleTo diagnostic: Project is referenced by src/tests/CoreTests.csproj",
]

missing = [msg for msg in required if msg not in content]
if missing:
    print("Missing expected strict diagnostics:", file=sys.stderr)
    for msg in missing:
        print(f"- {msg}", file=sys.stderr)
    print(content, file=sys.stderr)
    raise SystemExit(1)
PY

echo "Strict diagnostics failure behavior verified."
