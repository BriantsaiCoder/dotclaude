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
  # payload MUST 用 jq 產生。printf 直接插值遇到引號或反斜線會產出無效 JSON，
  # 於是被測腳本走的是「payload 解析失敗」分支而非真正的判定邏輯——引號規避那項會
  # 因此變成假陽性（它 deny 了，但不是因為規避被識破）。jq 缺席時直接讓 selftest
  # 失敗，不降級成不可信的比對。
  if ! command -v jq >/dev/null 2>&1; then
    printf 'selftest 需要 jq 產生合法 JSON payload（否則無法區分「規避被擋」與「payload 壞掉被擋」）\n' >&2
    exit 1
  fi
  p=0; f=0
  run() { # 1=desc 2=command 3=state 4=expect
    # fake gate 只對 PR 42 回報指定的 STATE，其他編號一律 PASS。這讓「PR 編號抓錯」
    # 表現為誤放行（exit 0），才會被 expect=2 的案例抓到；若不分編號一律回同一個
    # STATE，抓錯編號的 bug 在 selftest 裡完全不可見。
    if [ -n "$3" ]; then
      # shellcheck disable=SC2016 # $1 要原樣寫進 fake gate 腳本，此處不得展開
      printf '#!/bin/sh\nif [ "$1" = 42 ]; then printf "STATE=%s pr=42 head=abc\\n"; else printf "STATE=PASS pr=%%s head=abc\\n" "$1"; fi\n' "$3" > "$d/gate"
    else
      printf '#!/bin/sh\nexit 1\n' > "$d/gate"
    fi
    chmod +x "$d/gate"
    jq -cn --arg cmd "$2" --arg cwd "$d/repo" '{tool_input:{command:$cmd},cwd:$cwd}' |
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
  # 前段的數字不得被當成 PR 編號。抓錯會拿到 99，fake gate 對 99 回 PASS → 誤放行 exit 0。
  run '前段數字不搶 PR 編號'     'echo 99 && gh pr merge 42'      FAIL_CI     2
  run '同段前置數字不搶編號'     'timeout 99 gh pr merge 42'      FAIL_CI     2
  # merge 之後才取編號，選項與其值要跳過
  run 'merge 後才取編號'         'gh pr merge --repo o/r 42'      FAIL_CI     2
  run '引號規避仍擋'             'gh "pr" merge'                  PASS        2
  run 'gh pr create 放行'        'gh pr create --fill'            FAIL_CI     0
  run 'gh pr view 放行'          'gh pr view 42'                  FAIL_CI     0
  run '無關指令放行'             'dotnet build -c Release'        FAIL_CI     0
  # json_escape canary：reason 會夾帶 pr-review-gate 的原始輸出，那可能含雙引號或反斜線
  # （GraphQL 錯誤訊息就常有）。只驗 exit code 會漏掉這種失敗——非法 JSON 一樣 exit 2，
  # 但 host 解析不了 block 回覆，等於靜默失去這道防線。所以這項直接驗輸出可被 jq 解析。
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" %s\n' "'STATE=FAIL_CI note=he said \"x\" path=C:\\tmp'"
  } > "$d/gate"
  chmod +x "$d/gate"
  esc_out=$(jq -cn --arg cmd 'gh pr merge 42' --arg cwd "$d/repo" '{tool_input:{command:$cmd},cwd:$cwd}' |
    PR_REVIEW_GATE="$d/gate" "$0" 2>&1 >/dev/null)
  if printf '%s' "$esc_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf '  PASS  reason 含引號與反斜線時 deny 仍輸出合法 JSON\n'; p=$((p+1))
  else
    printf '  FAIL  reason 含引號時 deny 輸出非法 JSON：%s\n' "$esc_out"; f=$((f+1))
  fi
  printf '總計：PASS=%s FAIL=%s\n' "$p" "$f"
  [ "$f" -eq 0 ]
  exit $?
fi

# JSON 字串轉義：純 bash 參數展開，不依賴 jq——deny() 必須在 jq 不可用時仍能輸出合法 JSON。
# 與 guard-git-push.sh 同一份實作。reason 會帶 pr-review-gate 的原始輸出，那可能含雙引號或
# 反斜線（GraphQL 錯誤訊息就常有），未轉義會產出非法 JSON，host 解析不了 block 回覆——那等於
# 靜默失去這道防線，比誤擋嚴重得多。
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # 反斜線必須先轉，否則會把後面補的反斜線再轉一次
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}" # 控制字元在 JSON string 內非法
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

deny() {
  printf '{"decision":"block","reason":%s}\n' "$(json_escape "$1")" >&2
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

# 複合命令切段（; | & 與 newline 皆為段界），只在含 gh…pr…merge 的那一段裡解析。
# 對整串取「第一個純數字」會被前段搶走：`echo 99 && gh pr merge 42` 會拿 99 去查，
# 而 99 若剛好是另一個已 PASS 的 PR，這個 gate 就放行了它根本沒驗過的目標 PR。
# 2026-08-06 Copilot review 指出，實測確認。
SEP=$'\034'
CMD_SEGMENTS=${SCAN//[\;\|\&]/$SEP}
CMD_SEGMENTS=${CMD_SEGMENTS//$'\n'/$SEP}
segments=()
IFS="$SEP" read -r -a segments <<< "$CMD_SEGMENTS"

merge_seg=""
for seg in "${segments[@]}"; do
  # gh 可執行檔認裸 token 與完整路徑；三個 token 必須同段出現才算執行意圖。
  case "$seg" in *[Gg][Hh]*pr*merge*) merge_seg=$seg; break ;; esac
done
[ -n "$merge_seg" ] || exit 0

# 編號只從 merge token 之後取。`timeout 99 gh pr merge 42` 的 99 在 merge 之前，
# 不是 PR 編號；選項與其值（--repo owner/name）都不是裸數字，略過即可。
PR=""
after_merge=0
for tok in $merge_seg; do
  if [ "$after_merge" -eq 0 ]; then
    [ "$tok" = merge ] && after_merge=1
    continue
  fi
  case "$tok" in
    -*)          ;;
    ''|*[!0-9]*) ;;
    *)           PR=$tok; break ;;
  esac
done
[ -n "$PR" ] || deny "[T0-9] 合併指令未帶明確 PR 編號，無法驗證 gate。請把編號寫在子指令之後。"

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
