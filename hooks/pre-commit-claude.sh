#!/bin/bash
# Pre-commit 守門：阻止誤 commit 敏感檔、明文 secret、超大檔。
# 安裝：bash hooks/install-pre-commit.sh
# 繞過（謹慎）：git commit --no-verify

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'
fail() { echo -e "${RED}[pre-commit] $*${NC}" >&2; }
warn() { echo -e "${YEL}[pre-commit] $*${NC}" >&2; }

errors=0

# 1. 黑名單檔名（含部分路徑）
BLOCKED_PATTERNS=(
  'history\.jsonl$'
  '\.bak$'
  '\.bak\.[0-9]'
  '\.backup$'
  '\.backup\.[0-9]'
  'settings\.local\.json$'
  '^sessions/'
  '^projects/'
  '^cache/'
  '^image-cache/'
  '^paste-cache/'
  '^file-history/'
  '^session-env/'
  '^shell-snapshots/'
  '^agent-memory/'
  '^plans/'
  '^tasks/'
  '^todos/'
  '^telemetry/'
  '^statsig/'
  'security_warnings_state_.*\.json$'
  'stats-cache\.json$'
  'audit-bash\.log$'
)

staged=$(git diff --cached --name-only --diff-filter=ACMR)
[[ -z "$staged" ]] && exit 0

while IFS= read -r f; do
  for p in "${BLOCKED_PATTERNS[@]}"; do
    if [[ "$f" =~ $p ]]; then
      fail "黑名單檔案: $f （match: $p）"
      errors=$((errors + 1))
      break
    fi
  done
done <<< "$staged"

# 2. 單檔 > 1 MB
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  size=$(wc -c < "$f" | tr -d ' ')
  if (( size > 1048576 )); then
    fail "檔案過大 ($((size / 1024)) KB > 1 MB): $f"
    errors=$((errors + 1))
  fi
done <<< "$staged"

# 3. 明文 secret 偵測（key=value / "key": "value" 形式）
SECRET_REGEX='(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer[_-]?token|password|client[_-]?secret|private[_-]?key)["'"'"' ]*[:=][ ]*["'"'"']?[A-Za-z0-9/_+=.-]{16,}'
HIGH_ENTROPY_HINTS='(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

diff_added=$(git diff --cached --diff-filter=ACMR -U0 | grep -E '^\+' | grep -vE '^\+\+\+' || true)
if [[ -n "$diff_added" ]]; then
  if echo "$diff_added" | grep -iE "$SECRET_REGEX" > /dev/null; then
    fail "疑似明文 secret（key=value 形式）— 檢查 staged 變更"
    echo "$diff_added" | grep -inE "$SECRET_REGEX" | head -5 >&2
    errors=$((errors + 1))
  fi
  if echo "$diff_added" | grep -E "$HIGH_ENTROPY_HINTS" > /dev/null; then
    fail "疑似高熵 token / 私鑰"
    echo "$diff_added" | grep -nE "$HIGH_ENTROPY_HINTS" | head -5 >&2
    errors=$((errors + 1))
  fi
fi

if (( errors > 0 )); then
  fail "$errors 項問題，commit 中止。確認無誤可用 git commit --no-verify 繞過"
  exit 1
fi

exit 0
