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
# 與 guard-git-push.sh／guard-pr-merge.sh 對齊，刻意**不用** -e：PreToolUse 只有 exit 2
# 阻擋，任何意外的 exit 1 都是靜默放行，而 -e 正是把所有非預期失敗導向那裡的管道。
set -ufo pipefail

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
  # mktemp 失敗必須讓 selftest 立刻死，理由與上面的 jq 守護同一條，只是換一個依賴：
  # 本檔刻意不用 -e（見開頭），所以 `tmpdir="$(mktemp -d)"` 失敗會被吞掉、$tmpdir 變空字串，
  # 於是每個 fixture 路徑塌成 `/good.md`、`/splitaxis.md`——寫不進去，被測腳本一律走
  # 「body-file 不可讀」那條分支。結果是 allow 案例假 FAIL，而**整個 deny 半邊假 PASS**：
  # 它確實 deny 了，但不是因為規避被識破。2026-08-08 在 Bash sandbox 下實測到這個形態
  # （mkdtemp on /var/folders/… Operation not permitted）。裸 mktemp -d 也是主因之一，
  # 比照 guard-pr-merge.sh 改用 $TMPDIR 模板。
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/guard-s5-ledger.XXXXXX")" || {
    printf 'selftest 需要可寫的暫存目錄（否則 deny 案例會因 fixture 不存在而假 PASS）\n' >&2
    exit 1
  }
  trap 'rm -rf "$tmpdir"' EXIT
  # mktemp 成功不等於 fixture 寫得進去（唯讀掛載、配額滿、目錄權限被改都會讓 mkdir 過而
  # 寫入失敗）。而 run_case 只看 rc、不看 stderr、也不驗 fixture 存在，所以任何一條讓
  # fixture 寫不出來的路徑，都會讓**整個 deny 半邊因「body-file 不可讀」而假 PASS**——
  # 與 mktemp 失敗時完全同一個形狀。守 mktemp 只擋掉觀察到的那一條，canary 擋的是
  # **tmpdir 層級**那一類（唯讀掛載、配額滿、目錄權限被改）。
  # 不擋的仍有：fixture 逐案寫入失敗、寫出但內容為空、測試自身把路徑寫錯——根因是
  # run_case 丟掉 stderr、只斷言 rc，不驗 deny 的**理由**。真正的結構解是讓 run_case
  # 斷言 deny reason 屬於「缺兩軸狀態」而非「body-file 不可讀」（兩者訊息已可區分），
  # 比照 tests/repo-integrity.sh 的 _push_probe。列為 follow-up，不在本次範圍。
  # printf 不加 2>/dev/null：redirection 由左至右處理，`> file` 先失敗，抑制根本蓋不到
  # permission denied 那條；它真正會吃掉的是配額滿時的 `printf: write error`——也就是
  # 唯一說明原因的那行，而 repo-integrity.sh 會把 selftest 的 stderr 一起收進失敗輸出。
  printf 'canary\n' > "$tmpdir/.canary"
  if [ ! -s "$tmpdir/.canary" ]; then
    printf 'selftest 無法在暫存目錄寫入 fixture（deny 案例會因檔案不存在而假 PASS）：%s\n' "$tmpdir" >&2
    exit 1
  fi
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

  # 三欄 + 指紋的最小合法區塊。抽成變數而非逐個 fixture 重打：新檢查要求它們同時在場，
  # 於是每個原本只有兩行狀態的 allow fixture 都得補上——重打四次就會有一次打錯，
  # 而打錯的方向是 fixture 意外變成 deny 案例，看起來像被測邏輯壞了。
  record_block='| reviewer 型別 | 一次性 prompt 審查 |
| agent id | wf_deadbeef |
| finding 摘要 | 無 actionable findings |
FP:REVTMPL-2026Q3'

  good_body="$tmpdir/good.md"
  printf '## 摘要\n\nS5 Standards: PASS\nS5 Spec: SKIPPED（無 spec 檔）\n\n%s\n' "$record_block" > "$good_body"
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
  printf 'S5 Standards: PASS\nS5 Spec: PASS\n%s\n' "$record_block" > "$big_body"
  awk 'BEGIN { for (i = 0; i < 20000; i++) print "padding line to make the PR body large enough to matter" }' >> "$big_body"

  run_case allow '非 PR 指令安靜放行: git status'            'git status'
  run_case allow '非建立指令放行: gh pr view 42'              'gh pr view 42'
  run_case allow '非建立指令放行: gh pr merge 42 --squash'    'gh pr merge 42 --squash'
  run_case allow '兩軸狀態在 --body-file 內'                  "gh pr create --title t --body-file $good_body"
  run_case allow '兩軸狀態在 --body-file= 形式'               "gh pr create --title t --body-file=$good_body"
  run_case allow '兩軸狀態直接寫在 --body'                    'gh pr create --title t --body "S5 Standards: PASS / S5 Spec: FAIL / reviewer 型別: 一次性 prompt 審查 / agent id: wf_deadbeef / finding 摘要: 無 actionable findings / FP:REVTMPL-2026Q3"'
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
  # 狀態值的前綴不算數：沒有邊界條件時 PASSING／FAILSAFE 會命中 PASS／FAIL 而放行。
  prefix_body="$tmpdir/prefix.md"
  printf 'S5 Standards: PASSING\nS5 Spec: FAILSAFE\n' > "$prefix_body"
  run_case deny  '狀態值只是合法值的前綴（PASSING／FAILSAFE）' "gh pr create --title t --body-file $prefix_body"
  boundary_body="$tmpdir/boundary.md"
  # 三欄擺前面：這條測的是「最後一行無換行時狀態值仍靠字串結尾收邊」，狀態行必須留在最後。
  printf '%s\nS5 Standards: PASS\nS5 Spec: UNAVAILABLE' "$record_block" > "$boundary_body"
  run_case allow '最後一行無換行，狀態值靠字串結尾收邊'        "gh pr create --title t --body-file $boundary_body"
  # 狀態值必須與軸名同一行：[[:space:]] 會吃掉換行，讓下面兩種跨行寫法都算合法。
  crossline_body="$tmpdir/crossline.md"
  printf 'S5 Standards:\nPASS\nS5 Spec:\nPASS\n' > "$crossline_body"
  run_case deny  '狀態值跨行（軸名與值不同行）'                "gh pr create --title t --body-file $crossline_body"
  splitaxis_body="$tmpdir/splitaxis.md"
  printf 'S5\nStandards: PASS\nS5\nSpec: PASS\n' > "$splitaxis_body"
  run_case deny  '軸名本身被換行切開'                          "gh pr create --title t --body-file $splitaxis_body"

  # ── 三欄 + 指紋（reviewer-template.md :69-79）。
  # 上面每個 allow fixture 都已含 record_block，所以它們同時是這組檢查的 GREEN 負控：
  # 四項齊備時放行。下面補的是各缺一項的 RED，與「不該要求時別要求」的豁免。
  skipped_body="$tmpdir/skipped.md"
  printf 'S5 Standards: SKIPPED（低風險 docs）\nS5 Spec: SKIPPED（無 spec 檔）\n' > "$skipped_body"
  run_case allow '兩軸皆 SKIPPED 免三欄（沒跑審查就沒有記錄）'  "gh pr create --title t --body-file $skipped_body"
  half_skipped_body="$tmpdir/halfskipped.md"
  printf 'S5 Standards: PASS\nS5 Spec: SKIPPED（無 spec 檔）\n' > "$half_skipped_body"
  run_case deny  '只有一軸 SKIPPED，另一軸跑過就要三欄'        "gh pr create --title t --body-file $half_skipped_body"
  no_fp_body="$tmpdir/nofp.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\n| reviewer 型別 | 一次性 prompt 審查 |\n| agent id | wf_deadbeef |\n| finding 摘要 | 無 |\n' > "$no_fp_body"
  run_case deny  '三欄齊但缺指紋（沒載入 reviewer-template）'   "gh pr create --title t --body-file $no_fp_body"
  no_agent_body="$tmpdir/noagent.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nfinding 摘要：無\nFP:REVTMPL-2026Q3\n' > "$no_agent_body"
  run_case deny  '有指紋但缺 agent id'                         "gh pr create --title t --body-file $no_agent_body"
  # 這條釘住 agent id 的 pattern 不得寫成 `agent id|UNAVAILABLE`：那樣的話狀態行自己的
  # `S5 Standards: UNAVAILABLE` 就滿足了該欄，於是檢查對最需要它的那種 PR 恰好失效。
  unavail_body="$tmpdir/unavail.md"
  printf 'S5 Standards: UNAVAILABLE\nS5 Spec: SKIPPED（無 spec 檔）\nreviewer 型別：無\nfinding 摘要：無\nFP:REVTMPL-2026Q3\n' > "$unavail_body"
  run_case deny  'UNAVAILABLE 不豁免 agent id 欄'              "gh pr create --title t --body-file $unavail_body"
  unavail_ok_body="$tmpdir/unavailok.md"
  printf 'S5 Standards: UNAVAILABLE\nS5 Spec: SKIPPED（無 spec 檔）\nreviewer 型別：無\nagent id：UNAVAILABLE（probe: Agent tool 被 host 停用）\nfinding 摘要：無\nFP:REVTMPL-2026Q3\n' > "$unavail_ok_body"
  run_case allow 'UNAVAILABLE 在 agent id 欄填齊即放行'        "gh pr create --title t --body-file $unavail_ok_body"

  printf '\n'
  if [ "$fails" -eq 0 ]; then
    printf 'guard-s5-ledger selftest: 全數通過\n'
    exit 0
  fi
  printf 'guard-s5-ledger selftest: %s 項失敗\n' "$fails" >&2
  exit 1
fi

JQ="$(command -v jq 2>/dev/null || true)"
IFS= read -r -d '' INPUT || true   # bash 內建；用 $(cat) 會在 PATH 壞掉時 rc=127 放行

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
  # 相對路徑必須用 **gh 的 cwd** 解析，不是 hook 程序的 cwd。guard-pr-merge.sh 記過同型
  # 實測坑：payload 的 .cwd 是 session 目錄，指令寫成 `cd X && gh …` 時實際執行目錄是 X。
  # 驗錯目錄的後果是驗到另一份同名檔——上一輪殘留的 pr-body.md 是常態，於是 hook 看到帶
  # ledger 的舊檔而 gh 送出沒有 ledger 的新檔，rc=0 放行。定位不了就 deny，不猜。
  case "$BODY_FILE" in
    /*) ;;
    *)
      case "$SCAN_CMD" in
        cd[[:space:]]*|*[[:space:]]cd[[:space:]]*)
          deny "[S5-1] 指令含 cd 且 --body-file 是相對路徑（${BODY_FILE}），無法可靠判定它相對於哪個目錄，保守拒絕。請改用絕對路徑。"
          ;;
      esac
      HOOK_CWD="$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null || true)"
      [ -n "$HOOK_CWD" ] ||
        deny "[S5-1] --body-file 是相對路徑（${BODY_FILE}）但 payload 沒有 cwd，無從定位，保守拒絕。請改用絕對路徑。"
      BODY_FILE="${HOOK_CWD%/}/${BODY_FILE}"
      ;;
  esac
  # -f 不可省：`[ -r <dir> ]` 對目錄回 true，接著讀檔失敗——在有 -e 的版本是 exit 1 靜默
  # 放行，沒有 -e 也只是留下空 BODY 同樣不擋。
  if [ ! -f "$BODY_FILE" ] || [ ! -r "$BODY_FILE" ]; then
    deny "[S5-1] --body-file 指向 ${BODY_FILE}，但它不是可讀的一般檔案，無從確認 S5 兩軸狀態，保守拒絕。"
  fi
  # 只比對檔案內容，不串 ${CMD}：串起來的話 --title／--label 等旗標值裡的狀態字串就能滿足
  # 檢查，而真正送出的 body 可以完全沒有（實測 --label 'S5 Standards: PASS …' 即放行）。
  # $(<file) 是 bash 內建讀檔，不 fork cat。
  BODY="$(<"$BODY_FILE")"
fi

# 用 bash 內建 =~ 而非 `printf … | grep -Eq`，理由同上方路徑抽取，但這條更危險：
# grep -q **必定**在找到匹配後立刻退出，printf 只要還在寫就收 SIGPIPE。而 $BODY 含整個
# PR body 檔案內容——body 越長越容易觸發，真實 PR body 正是長的。觸發時 exit 1 = 放行，
# 也就是「PR body 寫得越完整，這道 gate 越可能不擋」，方向完全相反。
# =~ 零 fork、零 pipeline，$BODY 多大都一樣。
# 狀態值後面要求邊界：沒有它時 `PASSING`／`FAILSAFE`／`SKIPPEDX` 都會命中前綴而被放行。
# 邊界是「非字母數字底線」而不只是空白——`SKIPPED（無 spec 檔）` 是本檔 deny 訊息自己給
# 的範例，全形括號必須算邊界。BODY 是多行字串而 bash 的 =~ 沒有 multiline，所以 `$` 只
# 匹配整份字串的結尾；行尾的換行由前半接住。
# 用 [[:blank:]]（空白與 tab）而非 [[:space:]]（含換行）：後者讓 `S5 Standards:\nPASS`
# 與 `S5\nStandards:` 都算合法，與本檔到處在講的「狀態**行**」不一致。狀態值必須跟軸名
# 在同一行。
missing=""
[[ "$BODY" =~ S5[[:blank:]]+Standards:[[:blank:]]*$STATUS_RE([^A-Za-z0-9_]|$) ]] || missing="S5 Standards"
[[ "$BODY" =~ S5[[:blank:]]+Spec:[[:blank:]]*$STATUS_RE([^A-Za-z0-9_]|$) ]] ||
  missing="${missing:+$missing 與 }S5 Spec"

if [ -n "$missing" ]; then
  deny "[S5-1] PR body 缺 $missing 狀態行。進 PR 的變更 MUST 跑 Standards 與 Spec 兩軸，各標 PASS／FAIL／SKIPPED（附理由）／UNAVAILABLE（附 probe）。請在 PR body 加入例如：
  S5 Standards: PASS
  S5 Spec: SKIPPED（無 spec 檔）
缺 reviewer capability 時填 UNAVAILABLE 並附 probe 指令與失敗理由，不得以自審頂替（見 ~/.agents/skills/dev-workflow/references/reviewer-template.md）。"
fi

# ── 兩行狀態擋得住「沒宣告」，擋不住「宣告了但沒依據」。
#
# 2026-08-09 的失效：PR #99／#100 的 body 都寫了「全數套用 reviewer-template.md 的 canonical
# over-engineering contract」，而該檔從未被載入；同一輪還漏掉該檔 :69-79 的三欄 MUST 記錄，
# 只給分組統計。上面的兩軸檢查對這兩件事全無感覺——`S5 Standards: PASS` 照樣通過。
#
# 四項的強度**不相等**，這裡明寫免得誤以為都是硬證據：
#   * 指紋是唯一真正的機械證據——沒讀過 reviewer-template.md 就打不出那串。
#   * 三欄只是關鍵詞在場檢查。寫「reviewer 型別：無」照樣過。它擋的是「只有兩行狀態、
#     其餘什麼都沒有」的空洞 body，不是刻意造假。刻意造假由 review 本身承擔，不是 hook。
# 用寬鬆關鍵詞而非逐字欄名，是為了不誤擋 ledgers.md 範例那種散文寫法
# （`reviewer=dotnet-code-reviewer（agent id dcr-07）；2 findings 皆採納並修`）——
# 誤擋會逼人把 body 改成迎合 hook 的形狀，那比漏擋更糟。
#
# 豁免：兩軸皆 SKIPPED = 完全沒跑審查（[S5-1] 允許低風險 docs／trivial change 這樣標），
# 三欄與指紋無從產生。只要有一軸真的跑過就要求——**UNAVAILABLE 算跑過**：
# reviewer-template.md :76 明寫無審查者時是在 agent id 欄填 UNAVAILABLE 並附 probe，
# 那仍是三欄的一部分，不是三欄的豁免。
if [[ "$BODY" =~ S5[[:blank:]]+Standards:[[:blank:]]*SKIPPED([^A-Za-z0-9_]|$) ]] &&
   [[ "$BODY" =~ S5[[:blank:]]+Spec:[[:blank:]]*SKIPPED([^A-Za-z0-9_]|$) ]]; then
  exit 0
fi

# agent id 用逐字欄名而非 `|UNAVAILABLE` alternation：後者會被狀態行自己的
# `S5 Standards: UNAVAILABLE` 滿足，於是這條檢查對最需要它的那種 PR 恰好失效。
record=""
[[ "$BODY" =~ [Rr]eviewer ]] || record="reviewer 型別"
[[ "$BODY" =~ [Aa]gent[[:blank:]]+[Ii][Dd] ]] || record="${record:+${record}、}agent id"
[[ "$BODY" =~ [Ff]inding ]] || record="${record:+${record}、}finding 摘要"
[[ "$BODY" =~ FP:REVTMPL-2026Q3 ]] || record="${record:+${record}、}reviewer-template 指紋"

[ -z "$record" ] && exit 0

deny "[S5-1] 兩軸狀態齊了，但 PR body 缺 ${record}。至少一軸非 SKIPPED＝審查真的跑過，reviewer-template.md「審查者 MUST 記錄」要求三欄，缺一不得判 S5 PASS：
  reviewer 型別／agent id（無審查者時此欄填 UNAVAILABLE + probe 指令與失敗理由）／finding 逐條摘要
指紋 FP:REVTMPL-2026Q3 逐字引用自該檔檔頭——引不出來就是沒載入，那份 contract 就不算套過。
兩軸皆 SKIPPED（低風險且沒跑審查）時本檢查不適用。"
