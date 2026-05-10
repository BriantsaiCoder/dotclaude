#!/usr/bin/env bash
# Audit log for Bash tool invocations under Auto mode.
# Reads Claude Code hook JSON from stdin, appends timestamped command to log.
# Rotates when LOG exceeds 10MB (keeps 1 archive: .log.1).
set -u
LOG="${HOME}/.claude/audit-bash.log"
MAX_SIZE=10485760
JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"

if [ -f "$LOG" ]; then
  SIZE=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
  [ "$SIZE" -gt "$MAX_SIZE" ] && mv -f "$LOG" "$LOG.1"
fi

INPUT="$(cat)"
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)
TS=$(date +%Y-%m-%dT%H:%M:%S%z)
printf '%s\t%s\t%s\n' "$TS" "$CWD" "$CMD" >> "$LOG"
exit 0
