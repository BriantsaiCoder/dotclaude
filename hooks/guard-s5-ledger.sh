#!/usr/bin/env bash
# guard-s5-ledger.sh
# PreToolUse(Bash) guard — [S5-1] 兩軸狀態在開 PR 時強制入 PR body。
#
# 為什麼需要這支：2026-08-08 的失效不是「S5 判斷錯」，而是**整個階段沒進意識**——
# 連續三個 PR（#91/#92/#93）動 production 程式邏輯進 PR，Standards 與 Spec 一次都沒跑、
# 也沒標 SKIPPED。事後補跑的 Spec 軸抓到 bot review 沒抓到的真缺口。
#
# 這支只保證一件事：開 PR 時 body 裡必須出現兩軸狀態行。狀態是自我宣告，可以填 PASS
# 而不真跑——但當時的失效模式是完全沒想到這一步，不是刻意造假。強制寫下狀態就足以讓
# 它進入意識。真正擋在「code 還沒寫」的是 PreToolUse(Write|Edit) 那層，這支只是補網。
#
# 設計約束（與 guard-git-push.sh / guard-pr-merge.sh 同）：
#   * fail-closed：是 gh pr create 但讀不到 body、jq 缺席、body-file 不可讀 → 一律拒絕。
#   * 非 PR 建立指令安靜結束（無輸出、exit 0）。
#   * 比對整個 command 字串，刻意接受誤擋，不解析 shell 語法——那會開出引號規避路徑。
set -euo pipefail

STATUS_RE='(PASS|FAIL|SKIPPED|UNAVAILABLE)'

# JSON 字串轉義：純 bash 參數展開，不依賴 jq——deny() 必須在 jq 不可用時仍能輸出合法 JSON。
# 與 guard-git-push.sh / guard-pr-merge.sh 同一份實作。
deny() {
  local reason="$1"
  reason=${reason//\\/\\\\}
  reason=${reason//\"/\\\"}
  reason=${reason//$'\n'/\\n}
  reason=${reason//$'\t'/\\t}
  reason=${reason//$'\r'/}
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 2
}

if [ "${1:-}" = "--selftest" ]; then
  JQ="$(command -v jq 2>/dev/null || true)"
  if [ -z "$JQ" ]; then
    printf 'selftest 需要 jq 產生合法 JSON payload（否則無法區分「規避被擋」與「payload 壞掉被擋」）\n' >&2
    exit 1
  fi
  self="${BASH_SOURCE[0]:-$0}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  fails=0

  run_case() {
    # $1=期望 allow|deny  $2=說明  $3=command
    local want="$1" label="$2" cmd="$3" out rc
    out="$(printf '%s' "$cmd" | "$JQ" -R '{tool_input:{command:.}}' | bash "$self" 2>/dev/null)" && rc=0 || rc=$?
    if [ "$want" = "allow" ] && [ "$rc" -eq 0 ]; then
      printf '  PASS  %s\n' "$label"
    elif [ "$want" = "deny" ] && [ "$rc" -eq 2 ]; then
      printf '  PASS  %s\n' "$label"
    else
      printf '  FAIL  %s (rc=%s, want=%s)\n' "$label" "$rc" "$want"
      fails=$((fails + 1))
    fi
  }

  good_body="$tmpdir/good.md"
  printf '## 摘要\n\nS5 Standards: PASS\nS5 Spec: SKIPPED（無 spec 檔）\n' > "$good_body"
  bad_body="$tmpdir/bad.md"
  printf '## 摘要\n\n修了一個 bug。\n' > "$bad_body"
  one_axis_body="$tmpdir/one.md"
  printf 'S5 Standards: PASS\n' > "$one_axis_body"
  no_status_body="$tmpdir/nostatus.md"
  printf 'S5 Standards:\nS5 Spec:\n' > "$no_status_body"
  # 大 body 且狀態行在最前面:舊版 `printf … | grep -Eq` 在這個形狀下最容易早退觸發
  # SIGPIPE(grep 第一行就命中,printf 還有幾百 KB 沒寫完)→ exit 1 → 靜默放行。
  # 這條是那個競態的回歸測試,不是一般的 happy path。
  big_body="$tmpdir/big.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\n' > "$big_body"
  awk 'BEGIN { for (i = 0; i < 20000; i++) print "padding line to make the PR body large enough to matter" }' >> "$big_body"

  run_case allow '非 PR 指令安靜放行: git status'            'git status'
  run_case allow '非建立指令放行: gh pr view 42'              'gh pr view 42'
  run_case allow '非建立指令放行: gh pr merge 42 --squash'    'gh pr merge 42 --squash'
  run_case allow '兩軸狀態在 --body-file 內'                  "gh pr create --title t --body-file $good_body"
  run_case allow '兩軸狀態在 --body-file= 形式'               "gh pr create --title t --body-file=$good_body"
  run_case allow '兩軸狀態直接寫在 --body'                    'gh pr create --title t --body "S5 Standards: PASS / S5 Spec: FAIL"'
  run_case deny  'body-file 缺兩軸狀態'                       "gh pr create --title t --body-file $bad_body"
  run_case deny  'body-file 只有 Standards 一軸'              "gh pr create --title t --body-file $one_axis_body"
  run_case deny  '有軸名但無合法狀態值'                       "gh pr create --title t --body-file $no_status_body"
  run_case allow '大 body 且狀態行在最前（SIGPIPE 競態回歸）'  "gh pr create --title t --body-file $big_body"
  run_case allow '--body-file 與路徑間多個空白'               "gh pr create --title t --body-file    $good_body"
  run_case deny  '多個 --body-file 取最後一個（最後一個缺狀態）' "gh pr create --body-file $good_body --body-file $bad_body"
  run_case allow '多個 --body-file 取最後一個（最後一個有狀態）' "gh pr create --body-file $bad_body --body-file $good_body"
  run_case deny  'body-file 路徑不存在'                       "gh pr create --title t --body-file $tmpdir/missing.md"
  run_case deny  '完全沒給 body'                              'gh pr create --title t'
  run_case deny  'draft PR 一樣要有兩軸'                      'gh pr create --draft --title t --body "no ledger here"'
  run_case deny  'command substitution 保守拒絕'              'gh pr create --title t --body-file $(mktemp)'
  run_case deny  '規避: pr cre\<newline>ate'                  'gh pr cre\
ate --title t --body "nothing"'

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    printf 'guard-s5-ledger selftest: 全數通過\n'
    exit 0
  fi
  printf 'guard-s5-ledger selftest: %s 項失敗\n' "$fails" >&2
  exit 1
fi

JQ="$(command -v jq 2>/dev/null || true)"
INPUT="$(cat)"

# 正規化，與 guard-pr-merge.sh 同一套、同一順序：line continuation 必須最先移除，
# 否則後面剝掉反斜線會留下裸 newline，把 `cre\<newline>ate` 永遠切成兩半。
normalize() {
  local s="$1"
  s=${s//$'\\\n'/}
  s=${s//$'\n'/ }
  s=${s//\"/}
  s=${s//\'/}
  s=${s//\\/}
  printf '%s' "$s"
}

SCAN_INPUT="$(normalize "$INPUT")"

# jq 不可用或解析失敗時 MUST NOT 靜默放行。折衷同 guard-git-push.sh：只對「原始 payload
# 就看得出在建 PR」的請求保守拒絕，其餘放行。
if [ -z "$JQ" ] || ! CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null); then
  case "$SCAN_INPUT" in
    *gh*pr*create*) deny "[S5-1] jq 不可用或 payload 解析失敗，無法判定是否在開 PR，保守拒絕。請確認 jq 已安裝且在 PATH 中。" ;;
  esac
  exit 0
fi

[ -z "$CMD" ] && exit 0
SCAN_CMD="$(normalize "$CMD")"

# 只管 gh ... pr ... create
case "$SCAN_CMD" in
  *gh*pr*create*) ;;
  *) exit 0 ;;
esac

# command substitution 讓 body 來源無法用字串比對可靠判定（`--body-file $(mktemp)` 展開後
# 才知道指向哪）。要真的判定必須執行它，而執行未知指令比誤擋危險得多。理由與正解同
# guard-pr-merge.sh：把指令改寫成不含 $( )、${ } 或反引號的明確形式。
case "$CMD" in
  *'$('*|*'${'*|*'`'*)
    deny "[S5-1] 指令含 command substitution，無法可靠判定 PR body 來源，保守拒絕。請改寫成不含 \$( )、\${ } 或反引號的明確形式。"
    ;;
esac

# 取 body 內容：--body-file 指向的檔案內容，加上原始 command（涵蓋 --body "..." 直接寫的情況）。
#
# 路徑抽取刻意用純 bash 參數展開，不用 `sed … | head -1`：那條 pipeline 在 `set -euo pipefail`
# 下會間歇性讓整支腳本以 exit 1 收場（head 讀到第一行就關 pipe，sed 收 SIGPIPE，pipefail 傳播，
# set -e 攔下）。而 exit 1 對 PreToolUse 是「放行」——只有 exit 2 才阻擋。也就是說那個競態會讓
# 這道 gate 偶爾**靜默失效**，且失效時看起來一切正常。2026-08-08 在另一台環境的 selftest 上
# 重現（同一份腳本在本機連跑 5 次全過），是時序相依而非邏輯錯。
# 純參數展開零外部程序、零 pipeline，順帶不再依賴 sed 的 BSD/GNU 行為差異。
#
# `##` 取最後一個 --body-file：gh 以最後一個為準，取第一個會驗錯來源。
BODY="$CMD"
BODY_FILE=""
case "$CMD" in
  *--body-file*)
    rest="${CMD##*--body-file}"
    rest="${rest#=}"
    while [ -n "$rest" ] && [ "${rest#[[:space:]]}" != "$rest" ]; do
      rest="${rest#[[:space:]]}"
    done
    BODY_FILE="${rest%%[[:space:]]*}"
    ;;
esac
if [ -n "$BODY_FILE" ]; then
  BODY_FILE="${BODY_FILE#\"}"; BODY_FILE="${BODY_FILE%\"}"
  BODY_FILE="${BODY_FILE#\'}"; BODY_FILE="${BODY_FILE%\'}"
  case "$BODY_FILE" in
    "~/"*) BODY_FILE="$HOME/${BODY_FILE#\~/}" ;;
  esac
  if [ ! -r "$BODY_FILE" ]; then
    deny "[S5-1] --body-file 指向 ${BODY_FILE}，但該檔不可讀，無從確認 S5 兩軸狀態，保守拒絕。"
  fi
  # $(<file) 是 bash 內建讀檔,不 fork cat。
  BODY="$BODY"$'\n'"$(<"$BODY_FILE")"
fi

# 用 bash 內建 =~ 而非 `printf … | grep -Eq`，理由同上方路徑抽取，但這條更危險：
# grep -q **必定**在找到匹配後立刻退出，printf 只要還在寫就收 SIGPIPE。而 $BODY 含整個
# PR body 檔案內容——body 越長越容易觸發，真實 PR body 正是長的。觸發時 exit 1 = 放行，
# 也就是「PR body 寫得越完整，這道 gate 越可能不擋」，方向完全相反。
# =~ 零 fork、零 pipeline，$BODY 多大都一樣。
missing=""
[[ "$BODY" =~ S5[[:space:]]Standards:[[:space:]]*$STATUS_RE ]] || missing="S5 Standards"
[[ "$BODY" =~ S5[[:space:]]Spec:[[:space:]]*$STATUS_RE ]] ||
  missing="${missing:+$missing 與 }S5 Spec"

[ -z "$missing" ] && exit 0

deny "[S5-1] PR body 缺 $missing 狀態行。進 PR 的變更 MUST 跑 Standards 與 Spec 兩軸，各標 PASS／FAIL／SKIPPED（附理由）／UNAVAILABLE（附 probe）。請在 PR body 加入例如：
  S5 Standards: PASS
  S5 Spec: SKIPPED（無 spec 檔）
缺 reviewer capability 時填 UNAVAILABLE 並附 probe 指令與失敗理由，不得以自審頂替（見 ~/.agents/skills/dev-workflow/references/reviewer-template.md）。"
