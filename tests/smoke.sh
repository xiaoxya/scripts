#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

output="$("${ROOT_DIR}/bin/hello.sh" Codex)"

if [[ "${output}" != "[info] Hello, Codex." ]]; then
  printf 'unexpected output: %s\n' "${output}" >&2
  exit 1
fi

printf 'smoke test passed\n'
