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
  # bash 解析後照樣執行，正規化前 *pr*merge* 卻看不到連續的 merge——fail-open
  run 'line-continuation 拆字仍擋' "$(printf 'gh pr mer\\\nge 42')" FAIL_CI    2
  # 以下四項刻意用 STATE=PASS 的 gate：若 exit 仍是 2，就證明是 substitution 判定擋的，
  # 而不是 gate 回報擋的——用 FAIL_CI 的 gate 兩者無法區分。
  # shellcheck disable=SC2016 # $( ) 是測試字面，不得展開
  run '$( ) 拆字一律保守拒絕'    'gh pr m$(printf er)ge 42'       PASS        2
  # shellcheck disable=SC2016
  run '$( ) 於引數也保守拒絕'    'gh pr merge $(echo 42)'         PASS        2
  # shellcheck disable=SC2016
  run '反引號同樣保守拒絕'       'gh pr merge `echo 42`'          PASS        2
  # shellcheck disable=SC2016
  run '${ } 同樣保守拒絕'        'gh pr merge ${N}'               PASS        2
  # 裸變數不含括號，列舉形狀的寫法會漏掉它——`gh pr $M 42`（M=merge）展開後照樣執行
  # shellcheck disable=SC2016
  run '裸 $VAR 取代子指令也擋'   'gh pr $M 42'                    PASS        2
  # shellcheck disable=SC2016
  run '裸 $VAR 當引數也擋'       'gh pr merge $N'                 PASS        2
  # 刻意誤擋的記錄：唯讀的 gh pr view 帶 substitution 也會被擋。判不出是否為合併就保守，
  # 正解是改寫成不含 substitution 的明確形式。
  # shellcheck disable=SC2016
  run '唯讀指令帶 subst 也擋(刻意)' 'gh pr view $(echo 42)'        PASS        2
  # normalize 剝掉引號後含空白的路徑會被切成多段，只取第一段等於用錯目錄；
  # 錯的目錄可能有同號且 PASS 的 PR——誤放行。無法解析成單一 token 必須拒絕。
  run 'cd 目標含空白時拒絕'      'cd /a b/c && gh pr merge 42'    PASS        2
  run 'cd 帶選項時拒絕'          'cd -P /tmp && gh pr merge 42'   PASS        2
  run 'cd 無引數時拒絕'          'cd && gh pr merge 42'           PASS        2
  run 'gh pr create 放行'        'gh pr create --fill'            FAIL_CI     0
  run 'gh pr view 放行'          'gh pr view 42'                  FAIL_CI     0
  run '無關指令放行'             'dotnet build -c Release'        FAIL_CI     0
  # 誤擋防護：子字串比對時代這四項都會被擋，且擋得毫無道理。gate 一律用 FAIL_CI，
  # 所以 exit 0 只可能來自「沒被判定成合併意圖」，不可能來自 gate 放行。
  # shellcheck disable=SC2016 # $( ) 是測試字面，不得展開
  run '--left-right+printf 不誤擋' 'git rev-list --left-right main...origin/main; printf "%s" $(echo x)' FAIL_CI 0
  # shellcheck disable=SC2016
  run 'highlight+prefix 不誤擋'  'grep --highlight --prefix=x $(pwd)' FAIL_CI  0
  # gh pr view --json 的 merge* 欄位全列在此（2026-08-06 用 `gh pr view --json` 取得完整
  # 清單）：五個都含 merge 子字串、五個都不等於 merge token。子字串比對會把它們全部誤判
  # 成合併意圖，實測擋過兩次。Copilot 於 PR #14 另舉 `--json merge`，但 gh 沒有這個欄位，
  # 該形式不是合法指令。
  run 'gh pr view merge* 欄位放行' 'gh pr view 42 --json mergeCommit,mergeStateStatus,mergeable,mergedAt,mergedBy' FAIL_CI 0
  # 收窄成 token 後，完整路徑呼叫仍須偵測得到——否則就從誤擋修成了漏擋。
  run 'gh 完整路徑仍偵測'        '/opt/homebrew/bin/gh pr merge 42' FAIL_CI   2
  # jq fallback canary：jq 不可用或 payload 壞掉時走的那條路徑，也必須用同一份
  # 正規化結果比對。若只比對原始字串，line-continuation 拆開的意圖在 jq 缺席時
  # 完全不會被偵測——防線在最該保守的情境下反而最寬。傳入無效 JSON 觸發同一分支。
  if printf 'not-json gh pr mer\\\nge 42' | PR_REVIEW_GATE="$d/gate" "$0" >/dev/null 2>&1; then
    printf '  FAIL  jq fallback 未偵測正規化後的意圖（fail-open）\n'; f=$((f+1))
  else
    printf '  PASS  jq fallback 用正規化結果比對\n'; p=$((p+1))
  fi
  # substitution 判定也必須在 fallback 生效，否則 jq 缺席時兩層防護同時失效。
  # shellcheck disable=SC2016 # $( ) 是測試字面
  if printf 'not-json gh pr m$(printf er)ge 42' | PR_REVIEW_GATE="$d/gate" "$0" >/dev/null 2>&1; then
    printf '  FAIL  jq fallback 未擋 command substitution（fail-open）\n'; f=$((f+1))
  else
    printf '  PASS  jq fallback 對 substitution 保守拒絕\n'; p=$((p+1))
  fi

  # cwd canary：payload 的 .cwd 是 session 目錄，指令若寫成 `cd X && …`，實際執行
  # 目錄是 X。取錯目錄時 pr-review-gate 查的是另一個 repo 的同號 PR——那不會報錯，
  # 只會安靜地回一個錯的答案，所以必須用「兩個目錄回不同 STATE」的 gate 才測得到。
  mkdir -p "$d/right" "$d/wrong"
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016 # $PWD 要原樣寫進 fake gate，此處不得展開
    printf 'case "$PWD" in *right) printf "STATE=PASS pr=42 head=abc\\n" ;; *) printf "STATE=FAIL_CI pr=42 head=abc\\n" ;; esac\n'
  } > "$d/cwdgate"
  chmod +x "$d/cwdgate"
  if jq -cn --arg cmd "cd $d/right && gh pr merge 42" --arg cwd "$d/wrong" \
       '{tool_input:{command:$cmd},cwd:$cwd}' |
       PR_REVIEW_GATE="$d/cwdgate" "$0" >/dev/null 2>&1; then
    printf '  PASS  cd 目標優先於 payload.cwd\n'; p=$((p+1))
  else
    printf '  FAIL  cwd 仍取 payload.cwd——會查到別的 repo 的同號 PR\n'; f=$((f+1))
  fi
  if jq -cn --arg cmd 'gh pr merge 42' --arg cwd "$d/right" \
       '{tool_input:{command:$cmd},cwd:$cwd}' |
       PR_REVIEW_GATE="$d/cwdgate" "$0" >/dev/null 2>&1; then
    printf '  PASS  無 cd 時退回 payload.cwd\n'; p=$((p+1))
  else
    printf '  FAIL  無 cd 時未使用 payload.cwd\n'; f=$((f+1))
  fi

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

# 比對前的正規化，與 guard-git-push.sh 同一套。順序是必要的：line continuation
# 必須最先移除，否則後面剝掉反斜線會留下裸 newline，把 `mer\<newline>ge` 永遠切成兩半。
# 剝 $ ( ) 是為了讓 `m$(printf er)ge` 這類 command substitution 少一層遮蔽。
#
# 2026-08-06 Copilot review 指出：只剝引號與反斜線時，`gh pr mer\<newline>ge 42`
# bash 解析後照樣執行，但 `*pr*merge*` 看不到連續的 merge——那是 fail-open，不是誤擋。
normalize() {
  local s=$1
  s=${s//$'\\\n'/}
  s=${s//\"/}
  s=${s//\'/}
  s=${s//\\/}
  s=${s//\$/}
  s=${s//\(/}
  s=${s//\)/}
  printf '%s' "$s"
}

# command substitution 讓合併意圖無法用字串比對可靠判定：`m$(printf er)ge` 展開後就是
# merge，但任何純字串正規化都看不出來——剝掉 $ ( ) 只會得到 `mprintf erge`。要真的判定
# 必須執行它，而執行未知指令比誤擋危險得多。
#
# 因此帶 substitution 的 gh…pr 指令一律保守拒絕。這是刻意的誤擋，會連 `gh pr view $(…)`
# 這種唯讀用法一起擋掉；正解與本檔開頭記載的相同——把指令改寫成不含 $( )、${ } 或反引號
# 的明確形式。MUST NOT 為了消除這類誤擋而改成解析 shell 語法，那會開出規避路徑。
has_subst() {
  # 認任何 $ 與反引號，不只 $( ${ 兩種形狀：裸 `gh pr $M 42`（M=merge）同樣展開成合併
  # 指令，而它不含括號。列舉形狀永遠會漏一種——這裡改成「只要有展開的可能就保守」。
  # shellcheck disable=SC2016 # 要比對字面 $ 與反引號，不得展開
  case "$1" in
    *'$'*|*'`'*) return 0 ;;
  esac
  return 1
}

# gh 與 pr 必須是**獨立 token** 才算 gh 指令。原本寫成 `*[Gg][Hh]*pr*` 子字串比對，
# 於是 `git rev-list --left-right`（--left-ri"gh"t）配上 `printf`（"pr"intf）就湊出一次
# 命中——2026-08-06 實測誤擋兩次，兩次都與 GitHub 毫無關係。highlight+--prefix、
# through+props、weight+preview 都會中。誤擋看起來像故障，而長期被誤擋的守門遲早被
# 關掉，等於守不住。
#
# token 化不會鬆掉 substitution 防線：`gh pr m$(printf er)ge 42` 裡的 gh 與 pr 本來就是
# 完整 token，照樣命中、照樣走保守拒絕。收窄的只有「字裡剛好有這兩串字母」那一類。
#
# 迴圈刻意不對 $1 加引號——就是要 word splitting 來切 token。檔首 `set -f` 已關閉
# globbing，所以 * 與 ? 不會被展開成檔名。
has_gh_pr() { # 1=已 normalize 的字串；2 非空時額外要求 merge token
  local need_merge=${2:-} stage=0 t
  for t in $1; do
    case "$stage" in
      # gh 可執行檔認裸 token 與完整路徑（/opt/homebrew/bin/gh）。
      0) case "$t" in [Gg][Hh]|*/[Gg][Hh]) stage=1 ;; esac ;;
      # gh 與 pr 之間可以夾全域選項（gh --repo o/r pr merge 42），所以持續往後掃。
      1) if [ "$t" = pr ]; then
           stage=2
           [ -n "$need_merge" ] || return 0
         fi ;;
      # 只認精確等於 merge 的 token。`gh pr view 42 --json state,mergeCommit` 的
      # mergeCommit 不是合併動作，子字串比對會把它誤判成 merge——實測擋過一次。
      2) [ "$t" = merge ] && return 0 ;;
    esac
  done
  return 1
}

JQ="$(command -v jq 2>/dev/null || true)"
INPUT="$(cat)"

# jq 缺席時不能靜默放行，但也不能一律拒絕。只對含 merge 意圖的 payload 保守拒絕——
# 而「含意圖」必須用與正常路徑同一份正規化結果判斷，否則 jq 不可用時同樣的
# line-continuation 規避完全不會被偵測，防線在最需要保守的情境下反而最寬。
SCAN_INPUT=$(normalize "$INPUT")
if [ -z "$JQ" ] || ! CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null); then
  case "$SCAN_INPUT" in
    *"pr"*"merge"*) deny "[T0-9] jq 不可用或 payload 解析失敗，無法驗證 merge gate，保守拒絕。" ;;
  esac
  # substitution 判定也必須在 fallback 生效，否則 jq 缺席時 `m$(printf er)ge` 直接通過——
  # 那是兩層防護同時失效，正好落在最該保守的情境。
  if has_subst "$INPUT" && has_gh_pr "$SCAN_INPUT"; then
    deny "[T0-9] payload 無法解析且指令含 command substitution，無法判定是否為合併操作，保守拒絕。"
  fi
  exit 0
fi
[ -z "$CMD" ] && exit 0

SCAN=$(normalize "$CMD")

if has_subst "$CMD" && has_gh_pr "$SCAN"; then
  deny "[T0-9] 指令含 command substitution，無法可靠判定是否為合併操作，保守拒絕。請改寫成不含 \$( )、\${ } 或反引號的明確形式。"
fi

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
  # gh、pr、merge 三者都必須是同段內的獨立 token，順序也要對，才算合併意圖。
  if has_gh_pr "$seg" merge; then merge_seg=$seg; break; fi
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

# pr-review-gate 用 cwd 解析 repo，查錯目錄就會查到別的 repo 的同號 PR——它自己的
# 註解記錄過這個實測坑，而本 hook 第一版正好踩了：payload 的 .cwd 是 **session 目錄**，
# 指令若寫成 `cd X && gh pr merge N`，實際執行目錄是 X，兩者不同。
#
# 2026-08-06 實測：session 在 Anormal_Unit_Detection、指令為
# `cd ~/.claude && gh pr merge 14`，hook 切到 session 目錄去查 #14，回報
# 「Could not resolve to a PullRequest」。反向更危險：session 目錄那個 repo 若剛好
# 有同號且 STATE=PASS 的 PR，這個 gate 會安靜地放行它根本沒驗過的目標 PR。
#
# 因此以「merge 段之前最後一個 cd 的目標」為準，沒有 cd 時才退回 payload 的 .cwd。
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null)
for seg in "${segments[@]}"; do
  [ "$seg" = "$merge_seg" ] && break
  seg_toks=()
  read -r -a seg_toks <<< "$seg"
  if [ "${seg_toks[0]:-}" = cd ]; then
    # normalize 已剝掉引號與反斜線，所以 `cd "/a b/c"` 到這裡是 `cd /a b/c`，
    # tokenization 會切成三段而取到 `/a`——用錯目錄，而錯的目錄可能有同號且
    # STATE=PASS 的 PR，那是誤放行。同理 `cd -P /x` 也不是單一路徑。
    # 只接受 `cd <單一 token>` 這一種能確定語意的形狀，其餘一律拒絕。
    [ "${#seg_toks[@]}" -eq 2 ] ||
      deny "[T0-9] cd 的目標無法安全解析成單一路徑（含空白、跳脫或額外引數），pr-review-gate 會查到錯的 repo，保守拒絕。"
    CWD=${seg_toks[1]}
  fi
done
CWD=${CWD/#\~/$HOME}
[ -n "$CWD" ] || deny "[T0-9] 無法判定合併指令的執行目錄，pr-review-gate 會查到錯的 repo，保守拒絕。"
[ -d "$CWD" ] || deny "[T0-9] 合併指令的執行目錄不存在（${CWD}），無法驗證 gate。"
cd "$CWD" || deny "[T0-9] 無法切換到執行目錄（${CWD}），pr-review-gate 會查到錯的 repo，保守拒絕。"

OUT=$("$GATE" "$PR" 2>&1) || true
case "$OUT" in
  STATE=PASS*) exit 0 ;;
  *) deny "[T0-9] merge gate 未通過，禁止 merge。pr-review-gate #$PR 回報：${OUT%%$'\n'*}" ;;
esac
