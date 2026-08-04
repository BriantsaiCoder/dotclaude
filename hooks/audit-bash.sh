#!/usr/bin/env bash
# Metadata-only audit log for Bash tool invocations under Auto mode.
# The command body is never extracted or persisted.
# Rotates when LOG exceeds 10MB (keeps 1 archive: .log.1).
# Log opens are no-follow and owner-only; the legacy command log is untouched.
# This async telemetry is not an authorization control; failures are visible and non-zero.
set -u
umask 077
LOG="${HOME}/.claude/audit-bash-metadata.log"
MAX_SIZE=10485760
JQ="$(command -v jq 2>/dev/null || true)"
[ -n "$JQ" ] || { printf 'audit-bash: jq unavailable\n' >&2; exit 1; }
PYTHON="$(command -v python3 2>/dev/null || true)"
[ -n "$PYTHON" ] || { printf 'audit-bash: python3 unavailable\n' >&2; exit 1; }
HELPER="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/append-audit-metadata.py"
[ -f "$HELPER" ] || { printf 'audit-bash: metadata helper unavailable\n' >&2; exit 1; }

TS=$(date +%Y-%m-%dT%H:%M:%S%z)
META=$("$JQ" -c --arg timestamp "$TS" '
  {
    timestamp: $timestamp,
    tool: "Bash",
    permission_mode: (.permission_mode // "unknown"),
    cwd: (.cwd // "")
  }
' 2>/dev/null) || { printf 'audit-bash: invalid hook payload\n' >&2; exit 1; }
[ -n "$META" ] || { printf 'audit-bash: empty metadata\n' >&2; exit 1; }
printf '%s\n' "$META" | "$PYTHON" "$HELPER" "$LOG" "$MAX_SIZE"
