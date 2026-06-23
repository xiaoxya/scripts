#!/usr/bin/env bash

info() {
  printf '[info] %s\n' "$*"
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="${1:-}"
  [[ -n "${command_name}" ]] || die "require_command needs a command name"
  command -v "${command_name}" >/dev/null 2>&1 || die "missing required command: ${command_name}"
}
