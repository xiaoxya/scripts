# scripts

A small repository for reusable shell scripts.

## Layout

- `bin/`: executable scripts intended to be run directly.
- `lib/`: shared shell helpers sourced by scripts.
- `tests/`: lightweight script checks.

## Usage

Run a script directly:

```sh
./bin/hello.sh Codex
```

Run checks:

```sh
make test
```

## Conventions

- Use `#!/usr/bin/env bash` for Bash scripts.
- Start scripts with `set -euo pipefail`.
- Keep shared functions in `lib/`.
- Prefer clear arguments and `--help` output for scripts used by others.
