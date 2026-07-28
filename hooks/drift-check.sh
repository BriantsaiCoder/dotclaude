#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 0

if ! bash tests/repo-integrity.sh >/dev/null 2>&1; then
  printf '%s\n' 'WARNING: ~/.claude global config integrity check failed; run bash ~/.claude/tests/repo-integrity.sh' >&2
fi

exit 0
