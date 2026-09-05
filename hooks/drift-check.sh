#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." || exit 0

# SessionStart hook 只有 stdout 進 context；exit-0 的 stderr 只進 debug log，非零 exit 也只把 stderr 第一行帶進
# transcript（code.claude.com/docs/en/hooks）。2026-09-05 前走 >&2，本機 drift 從未被看見。
# '^ *FAIL' 連 suite 收尾的 fail-open 自證行（無前導空白）也收。
if ! out=$(bash tests/repo-integrity.sh 2>/dev/null); then
  printf '%s\n' 'WARNING: ~/.claude global config integrity check failed; run bash ~/.claude/tests/repo-integrity.sh'
  printf '%s\n' "$out" | grep -m5 '^ *FAIL'
fi

# [T0-3] guard 副本一致性。hooks/guard-git-push.sh 自 2026-07-29 起是實體副本
# 而非 wrapper，CI 比不了（runner 無 ~/.agents），只能在本機驗。邏輯單一實作於
# ~/.agents/bin/hook-parity-check；缺檔時靜默跳過。
if [ -x "$HOME/.agents/bin/hook-parity-check" ]; then
  bash "$HOME/.agents/bin/hook-parity-check" || true
fi

exit 0
