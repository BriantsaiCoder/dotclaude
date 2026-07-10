#!/usr/bin/env bash
# Audit log for Bash tool invocations under Auto mode.
# Reads Claude Code hook JSON from stdin, appends timestamped command to log.
# Rotates when LOG exceeds 10MB (keeps 1 archive: .log.1).
# 命令內嵌的 secret 樣式先遮罩再落盤（[T0-4]）；log 檔權限固定 600。
set -u
LOG="${HOME}/.claude/audit-bash.log"
MAX_SIZE=10485760
JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"

if [ -f "$LOG" ]; then
  SIZE=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
  [ "$SIZE" -gt "$MAX_SIZE" ] && { mv -f "$LOG" "$LOG.1"; chmod 600 "$LOG.1" 2>/dev/null; }
fi

INPUT="$(cat)"
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)
TS=$(date +%Y-%m-%dT%H:%M:%S%z)
# 遮罩樣式與 pre-commit-claude.sh 的 SECRET_REGEX / HIGH_ENTROPY_HINTS 對齊
CMD=$(printf '%s' "$CMD" | perl -pe '
  s/((?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer[_-]?token|password|passwd|client[_-]?secret|private[_-]?key)["'"'"'\s]*[:=]\s*["'"'"']?)\S+/${1}***/gi;
  s/(authorization\s*[:=]\s*)\S+(\s+\S+)?/${1}***/gi;
  s/\bAKIA[0-9A-Z]{16}\b/AKIA***/g;
  s/\bghp_[A-Za-z0-9]{36}\b/ghp_***/g;
  s/\bsk-[A-Za-z0-9]{32,}\b/sk-***/g;
  s/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/xox-***/g;
  s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/<private-key ***>/g;  # 替換文字勿含 PEM 字面 marker，避免自撞 secret 偵測
' 2>/dev/null || printf '<mask-failed: command withheld>')
[ -z "$CMD" ] && CMD='<mask-failed: command withheld>'
printf '%s\t%s\t%s\n' "$TS" "$CWD" "$CMD" >> "$LOG"
chmod 600 "$LOG" 2>/dev/null
exit 0
