#!/usr/bin/env bash
#
# PreToolUse(Bash) guard — [T0-9] merge gate 機械強制。
#
# 為什麼需要這支：`gh pr merge` 能否放行取決於 **live CI 狀態**，permission rule 只比對字串，
# 表達不了這個條件。而 PreToolUse hook exit 2 會「在 permission rules 被評估之前就停住 tool
# call」——所以即使 permissions.allow 有 `Bash(gh *)`，這支仍然擋得住。
#
# 判定完全委給既有的 ~/.agents/bin/pr-review-gate：只有 STATE=PASS 才放行。
# 這支不自己判 CI，避免兩套判定漂移。
#
# 設計約束（與 guard-git-push.sh 同）：
#   * fail-closed：解析不出 PR 編號、jq 缺席、gate 不可執行 → 一律拒絕，不靜默放行。
#   * 非 merge 指令安靜結束（無輸出、exit 0）。
#   * 比對整個 command 字串。刻意接受誤擋（commit message 提到 "gh pr merge" 也會被擋），
#     不改成解析 shell 語法——那會開出引號規避路徑。
set -ufo pipefail

if [ "${1:-}" = "--selftest" ]; then
  # 每個 gate STATE 都必須對到明確的放行／拒絕，且只有 PASS 能放行。用假 gate 驗這段對應：
  # 真實情境要撞到 FAIL_MERGE 或 UNAVAILABLE 很難，等撞上才發現對應寫錯就太晚了。
  d=$(mktemp -d "${TMPDIR:-/tmp}/guard-pr-merge.XXXXXX") || exit 1
  mkdir -p "$d/repo"
  p=0; f=0
  run() { # 1=desc 2=command 3=state 4=expect
    if [ -n "$3" ]; then printf '#!/bin/sh\nprintf "STATE=%s pr=1 head=abc\\n"\n' "$3" > "$d/gate"
    else printf '#!/bin/sh\nexit 1\n' > "$d/gate"; fi
    chmod +x "$d/gate"
    printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$d/repo" |
      PR_REVIEW_GATE="$d/gate" "$0" >/dev/null 2>&1
    g=$?
    if [ "$g" = "$4" ]; then printf '  PASS  %s\n' "$1"; p=$((p+1))
    else printf '  FAIL  %s（期望 exit=%s 實得 %s）\n' "$1" "$4" "$g"; f=$((f+1)); fi
  }
  run 'STATE=PASS 放行'          'gh pr merge 42'                 PASS        0
  run 'STATE=FINDINGS 擋'        'gh pr merge 42'                 FINDINGS    2
  run 'STATE=WAIT_CI 擋'         'gh pr merge 42'                 WAIT_CI     2
  run 'STATE=WAIT_REVIEW 擋'     'gh pr merge 42'                 WAIT_REVIEW 2
  run 'STATE=FAIL_CI 擋'         'gh pr merge 42'                 FAIL_CI     2
  run 'STATE=FAIL_MERGE 擋'      'gh pr merge 42'                 FAIL_MERGE  2
  run 'STATE=UNAVAILABLE 擋'     'gh pr merge 42'                 UNAVAILABLE 2
  run 'gate 執行失敗時擋'        'gh pr merge 42'                 ''          2
  run '缺 PR 編號擋'             'gh pr merge'                    PASS        2
  run '帶 --squash 放行'         'gh pr merge 42 --squash'        PASS        0
  run '帶 --repo 放行'           'gh pr merge --repo o/r 42'      PASS        0
  run '複合指令 PASS 放行'       'git status && gh pr merge 42'   PASS        0
  run '複合指令 FAIL 仍擋'       'git status && gh pr merge 42'   FAIL_CI     2
  run '引號規避仍擋'             'gh \"pr\" merge'                PASS        2
  run 'gh pr create 放行'        'gh pr create --fill'            FAIL_CI     0
  run 'gh pr view 放行'          'gh pr view 42'                  FAIL_CI     0
  run '無關指令放行'             'dotnet build -c Release'        FAIL_CI     0
  printf '總計：PASS=%s FAIL=%s\n' "$p" "$f"
  [ "$f" -eq 0 ]
  exit $?
fi

deny() {
  printf '{"decision":"block","reason":"%s"}\n' "$1" >&2
  exit 2
}

JQ="$(command -v jq 2>/dev/null || true)"
INPUT="$(cat)"

# jq 缺席時不能靜默放行，但也不能一律拒絕。只對原始 payload 就含 merge 意圖的保守拒絕。
if [ -z "$JQ" ] || ! CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null); then
  case "$INPUT" in
    *"pr"*"merge"*) deny "[T0-9] jq 不可用或 payload 解析失敗，無法驗證 merge gate，保守拒絕。" ;;
  esac
  exit 0
fi
[ -z "$CMD" ] && exit 0

# 剝引號再比對，避免 `gh "pr" merge` 之類規避。
SCAN=${CMD//\"/}
SCAN=${SCAN//\'/}
SCAN=${SCAN//\\/}

# 只認 gh ... pr ... merge 三個 token 同段出現。gh 可執行檔認裸 token 與完整路徑。
case "$SCAN" in
  *[Gg][Hh]*pr*merge*) ;;
  *) exit 0 ;;
esac

# 取 PR 編號：`gh pr merge 42`、`gh pr merge --repo x 42` 都能抓到第一個裸數字。
PR=""
for tok in $SCAN; do
  case "$tok" in
    ''|*[!0-9]*) ;;
    *) PR=$tok; break ;;
  esac
done
[ -n "$PR" ] || deny "[T0-9] gh pr merge 未帶明確 PR 編號，無法驗證 merge gate。請寫成 'gh pr merge <號碼>'。"

GATE="${PR_REVIEW_GATE:-$HOME/.agents/bin/pr-review-gate}"
[ -x "$GATE" ] || deny "[T0-9] 找不到可執行的 pr-review-gate（${GATE}），無法驗證 merge gate。"

# pr-review-gate 用 cwd 解析 repo，所以必須切到 PostToolUse payload 帶的 cwd，
# 否則會查到別的 repo 的同號 PR（該工具註解裡記錄過這個實測坑）。
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  cd "$CWD" || deny "[T0-9] 無法切換到 payload 指定的 cwd（${CWD}），pr-review-gate 會查到錯的 repo，保守拒絕。"
fi

OUT=$("$GATE" "$PR" 2>&1) || true
case "$OUT" in
  STATE=PASS*) exit 0 ;;
  *) deny "[T0-9] merge gate 未通過，禁止 merge。pr-review-gate #$PR 回報：${OUT%%$'\n'*}" ;;
esac
