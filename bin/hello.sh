#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

show_help() {
  cat <<'HELP'
Usage:
  hello.sh [name]

Print a greeting.

Arguments:
  name    Name to greet. Defaults to "world".
HELP
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    return 0
  fi

  local name="${1:-world}"
  info "Hello, ${name}."
}

main "$@"
