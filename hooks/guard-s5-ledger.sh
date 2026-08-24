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
#   * fail-closed：是 gh pr create、或是會改寫 body 的 gh pr edit，但讀不到 body、
#     jq 缺席、body-file 不可讀 → 一律拒絕。
#   * 目標是讓既非 PR 建立、也不改寫 body 的指令安靜結束（無輸出、exit 0）；
#     字串比對做不到精確，已知的誤擋類別列在下方 dispatch 處的 ceiling 清單。
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
  BASH_BIN="$(command -v bash || printf '/bin/bash')"

  run_case() {
    # $1=期望 allow|deny  $2=說明  $3=command  $4=（選用）被測腳本的 PATH
    # $4 給空目錄即可測「被測腳本找不到 jq」那條分支；用參數而非全域變數配 set/reset，
    # 否則任何插進那個窗口的案例都會靜默在無 jq 下執行。
    local want="$1" label="$2" cmd="$3" runpath="${4:-$PATH}" rc
    # invoker 用絕對路徑（$4 可能是空目錄，PATH 查找會失敗），但取的是**線上那個**
    # bash：settings.json 以 `bash ~/.claude/hooks/…` 呼叫，寫死 /bin/bash 會讓 selftest
    # 在 PATH 前段有較新 bash 的機器上驗到與線上不同的直譯器。
    printf '%s' "$cmd" | "$JQ" -R '{tool_input:{command:.}}' |
      PATH="$runpath" "$BASH_BIN" "$self" >/dev/null 2>&1 && rc=0 || rc=$?
    if [ "$want" = "allow" ] && [ "$rc" -eq 0 ]; then
      printf '  PASS  %s\n' "$label"
    elif [ "$want" = "deny" ] && [ "$rc" -eq 2 ]; then
      printf '  PASS  %s\n' "$label"
    else
      printf '  FAIL  %s (rc=%s, want=%s)\n' "$label" "$rc" "$want"
      fails=$((fails + 1))
    fi
  }

  # 三欄 + baseline 標題的最小合法區塊。抽成變數而非逐個 fixture 重打：新檢查要求它們同時在場，
  # 於是每個原本只有兩行狀態的 allow fixture 都得補上——重打四次就會有一次打錯，
  # 而打錯的方向是 fixture 意外變成 deny 案例，看起來像被測邏輯壞了。
  record_block='| reviewer 型別 | 一次性 prompt 審查 |
| agent id | wf_deadbeef |
| finding 摘要 | 無 actionable findings |
baseline: Reinvented Stdlib、Wrong Altitude'

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
  run_case allow '兩軸狀態直接寫在 --body'                    'gh pr create --title t --body "S5 Standards: PASS / S5 Spec: FAIL / reviewer 型別: 一次性 prompt 審查 / agent id: wf_deadbeef / finding 摘要: 無 actionable findings / baseline: Reinvented Stdlib、Wrong Altitude"'
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

  # ── 三欄 + baseline 標題（reviewer-template.md 的「審查者 MUST 記錄」與「五條 baseline」）。
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
  run_case deny  '三欄齊但缺 baseline 標題（沒讀那一節）'   "gh pr create --title t --body-file $no_fp_body"
  no_agent_body="$tmpdir/noagent.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nfinding 摘要：無\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$no_agent_body"
  run_case deny  '有 baseline 標題但缺 agent id'                         "gh pr create --title t --body-file $no_agent_body"
  # 這條釘住 agent id 的 pattern 不得寫成 `agent id|UNAVAILABLE`：那樣的話狀態行自己的
  # `S5 Standards: UNAVAILABLE` 就滿足了該欄，於是檢查對最需要它的那種 PR 恰好失效。
  unavail_body="$tmpdir/unavail.md"
  printf 'S5 Standards: UNAVAILABLE\nS5 Spec: SKIPPED（無 spec 檔）\nreviewer 型別：無\nfinding 摘要：無\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$unavail_body"
  run_case deny  'UNAVAILABLE 不豁免 agent id 欄'              "gh pr create --title t --body-file $unavail_body"
  unavail_ok_body="$tmpdir/unavailok.md"
  printf 'S5 Standards: UNAVAILABLE\nS5 Spec: SKIPPED（無 spec 檔）\nreviewer 型別：無\nagent id：UNAVAILABLE（probe: Agent tool 被 host 停用）\nfinding 摘要：無\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$unavail_ok_body"
  run_case allow 'UNAVAILABLE 在 agent id 欄填齊即放行'        "gh pr create --title t --body-file $unavail_ok_body"
  # agent id 的分隔符變體：只認一個 ASCII 空白會誤擋這三種合法寫法。
  agent_variant_body="$tmpdir/agentvariant.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nagentId: wf_deadbeef\nfinding 摘要：無\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$agent_variant_body"
  run_case allow 'agent id 寫成 agentId 不誤擋'                "gh pr create --title t --body-file $agent_variant_body"

  # ── 豁免的極性。前三條全是 S5 實測到的**放行**，不是假想：`=~` 在多行字串上是任意位置
  # 匹配，所以「body 某處長得像 SKIPPED 狀態行」曾等同於「兩軸都是 SKIPPED」。
  fake_skip_body="$tmpdir/fakeskip.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\n\n散文提到 S5 Standards: SKIPPED 與 S5 Spec: SKIPPED 這兩種寫法。\n' > "$fake_skip_body"
  run_case deny  '真狀態 PASS，散文含 SKIPPED 形狀不得豁免'    "gh pr create --title t --body-file $fake_skip_body"
  fail_skip_body="$tmpdir/failskip.md"
  printf 'S5 Standards: FAIL\nS5 Spec: FAIL\n\n散文提到 S5 Standards: SKIPPED 與 S5 Spec: SKIPPED 這兩種寫法。\n' > "$fail_skip_body"
  run_case deny  '兩軸皆 FAIL，散文含 SKIPPED 形狀不得豁免'    "gh pr create --title t --body-file $fail_skip_body"
  # 這條釘死 deny 文案不得自己交出答案：把本 hook 的 deny 訊息整段貼回 body 是被擋者最自然
  # 的反應，訊息若列出五條標題就等於四項全被自己餵滿。S5 實測前一版（印指紋值）在此 ALLOW。
  echoed_deny_body="$tmpdir/echoeddeny.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\n\n[S5-1] 兩軸狀態齊了，但 PR body 缺 reviewer 型別、agent id、finding 摘要、over-engineering baseline 五條中至少兩條的逐字標題。這裡不列出五條是什麼——去讀 reviewer-template.md 的「五條 baseline」那一節。\n' > "$echoed_deny_body"
  run_case deny  '把 deny 訊息貼回 body 不得放行'              "gh pr create --title t --body-file $echoed_deny_body"
  # 「至少兩條」的邊界：單一標題（尤其 Wrong Altitude）可能在無關討論裡自然出現。
  one_title_body="$tmpdir/onetitle.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nagent id: wf_deadbeef\nfinding 摘要：無\n這裡討論了 Wrong Altitude 這個概念。\n' > "$one_title_body"
  run_case deny  '只有一條 baseline 標題不算數'                "gh pr create --title t --body-file $one_title_body"
  # 五條中任意兩條都成立，不是只認 record_block 裡那一組。
  other_pair_body="$tmpdir/otherpair.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nagent id: wf_deadbeef\nfinding 摘要：無\n命中 Needless Indirection 與 Unused Local Reuse 兩條。\n' > "$other_pair_body"
  run_case allow '五條中任兩條皆成立（非只認固定一組）'        "gh pr create --title t --body-file $other_pair_body"
  # reviewer／finding 兩條檢查原本零覆蓋：把三欄檢查全部短路後只有 agent id 的 case 翻紅
  # （S5 突變測試實證）。程式是對的，但它們可以被改壞而 selftest 全綠——正是上方 canary
  # 註解記載那個形態（斷言只看 rc、不驗 deny 的理由）的近親。
  no_reviewer_body="$tmpdir/noreviewer.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nagent id: wf_deadbeef\nfinding 摘要：無\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$no_reviewer_body"
  run_case deny  '缺 reviewer 型別'                            "gh pr create --title t --body-file $no_reviewer_body"
  no_finding_body="$tmpdir/nofinding.md"
  printf 'S5 Standards: PASS\nS5 Spec: PASS\nreviewer 型別：一次性 prompt 審查\nagent id: wf_deadbeef\nbaseline: Reinvented Stdlib、Wrong Altitude\n' > "$no_finding_body"
  run_case deny  '缺 finding 摘要'                             "gh pr create --title t --body-file $no_finding_body"

  # ── edit 破口（2026-08-24 補）。先用合格 body 開 PR、再 edit 換掉 body，狀態行就消失
  # 而 gate 從未執行。deny 半邊釘住「edit 帶 body 要走同一套檢查」，allow 半邊釘住
  # 「不碰 body 的 edit 不得誤擋」——後者缺席的話，最省事的修法（無條件攔所有 edit）
  # 會全綠通過，而那會擋掉 --add-label 這類完全正當的操作。
  run_case deny  'edit 帶 --body-file 但缺兩軸狀態'            "gh pr edit 42 --body-file $bad_body"
  run_case deny  'edit 帶 --body-file= 形式但缺狀態'           "gh pr edit 42 --body-file=$bad_body"
  run_case deny  'edit 帶 --body 但缺兩軸狀態'                 'gh pr edit 42 --body "只是改個描述"'
  run_case allow 'edit 帶 body 且兩軸齊全'                     "gh pr edit 42 --body-file $good_body"
  run_case allow 'edit 不碰 body：--add-label'                 'gh pr edit 42 --add-label needs-review'

  # ── 不得誤擋。曾經有一版把短旗標 -b／-F 併進同一個 case：實測那一版擋中下列三條
  # （awk -F／sort -b／ls -F），因為比對是三段子字串、不要求 gh pr edit 真的是被執行的
  # 指令，所以唯讀查詢、甚至完全沒有 gh 的指令都會命中。留著釘住不再回頭。
  run_case allow 'edit --add-label 後接 awk -F'                "gh pr edit 42 --add-label x && awk -F: '{print \$1}' /etc/hosts"
  run_case allow '唯讀查詢 pr list --search edit | sort -b'    'gh pr list --search edit --json number | sort -b'
  run_case allow '非 gh 指令，路徑含 pr-editor，旗標在後'      'ls docs/highlights/pr-editor/ -F'
  # arm 順序：把 edit arm 移到 create arm 之前會讓這條落到 edit arm 的 exit 0 成為
  # fail-open。這是唯一釘住該順序的斷言（實測：現行 rc=2、對調後 rc=0）。
  run_case deny  'create --fill 且字串含 edit（arm 順序）'     'gh pr create --fill --title "add credit page"'

  # ── jq 不可用分支。run_case 用 $JQ 絕對路徑組 payload，所以第 4 參數指到空目錄只影響
  # 被測腳本自己找不找得到 jq。用空目錄而非 /nonexistent：invoker 是絕對路徑 /bin/bash，
  # 兩者實測等價（相對 bash invoker 才會 127）。
  empty_bin="$tmpdir/nobin"
  mkdir -p "$empty_bin"
  run_case deny  '[no jq] create --body-file'                  "gh pr create --title t --body-file $good_body" "$empty_bin"
  run_case deny  '[no jq] edit --body-file'                    "gh pr edit 42 --body-file $good_body"          "$empty_bin"
  run_case deny  '[no jq] edit 內聯 --body'                    'gh pr edit 42 --body "沒有狀態行"'              "$empty_bin"
  run_case allow '[no jq] edit 不碰 body 不誤擋'               'gh pr edit 42 --add-label x'                    "$empty_bin"

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
    # 改寫 body 的 edit 與 create 同等：狀態行被換掉的後果一樣，jq 不可用時同樣保守拒絕。
    # 結構與下方主路徑相同（3 段外層 + 巢狀 `*--body*`），**不要**改回單一 4 段 pattern
    # `*gh*pr*edit*--body*`：bash 3.2 的 case glob 對不匹配的長字串是超線性，段數每多
    # 一段慢一個數量級，實測 4 段在 15KB 是分鐘級（量測見本次 PR 描述）。3 段版在
    # miss 時同樣超線性，只是慢一個數量級——所以也不要再加第三個 arm。
    # 兩處判定必須同步改。
    #
    # 注意匹配側與不匹配側的極性相反：不匹配時 timeout 被砍掉＝放行，與正確結果相同；
    # 匹配（該 deny）時被砍掉也是放行，那就與正確結果相反 —— 見下方 ceiling (6)。
    *gh*pr*edit*)
      case "$SCAN_INPUT" in
        *--body*)
          deny "[S5-1] jq 不可用或 payload 解析失敗，無法判定是否在改寫 PR body，保守拒絕。請確認 jq 已安裝且在 PATH 中。" ;;
      esac
      ;;
  esac
  exit 0
fi

[ -z "$CMD" ] && exit 0
SCAN_CMD="$(normalize "$CMD")"

# 管 gh ... pr ... create，以及會改寫 body 的 gh ... pr ... edit。
#
# 為什麼 edit 也要管：這道 gate 的保證是「PR body 裡有兩軸狀態行」。只攔 create 的話，
# 先用合格 body 開 PR、再用 edit 把 body 換掉，狀態行就消失了而 gate 從未執行——本檔
# 上方註解自承的破口，2026-08-24 實測確認帶 --body-file 的 edit 完全不進這支。
#
# 但不是所有 edit 都要求 ledger：--add-label／--add-assignee／--title 不碰 body，
# 而下面的檢查會拿「command 字串 + --body-file 內容」當 body 找狀態行，對不碰 body 的
# edit 必然找不到 → 誤擋一批完全正當的操作。所以只在 edit 真的改 body 時才管。
#
# 只認長形式 `--body*`（涵蓋 --body、--body-file、--body-file=）。短旗標 `-b`／`-F` 曾經
# 也攔，兩輪 S5 各自量出誤擋多於攔截後移除（量測與語料見本次 PR 描述）：這裡的比對是
# 三段子字串、不要求 `gh pr edit` 真的是被執行的指令，而 `-b`／`-F` 屬於一大票程式。
#
# Ceiling，明講——這道 gate 只擋「整個階段沒進意識」的疏漏，擋不住任何刻意規避。
# 以下**放行**路徑實測確認，都不打算補：
#   (1) 複合指令：`gh pr edit N --body-file 合格.md && gh pr edit N --body "沒有狀態行"`。
#       成因是 body 抽取取整串最後一個字面 `--body-file`，第二段的 `--body` 從不進判定；
#       反方向（`edit 壞.md && edit 合格.md`）同一成因，與走哪個 arm 無關。一個 `&&`
#       就繞過，這是最便宜的一條。
#   (2) 短旗標 `-b`／`-F`（見上）。
#   (3) `gh pr new` —— create 的官方 alias（`gh pr create --help` 的 ALIASES 段）。
#   (4) `gh api repos/o/r/pulls/N --method PATCH -f body=…`。要管就得比對
#       `gh*api*pulls*body=`，但那與用 --jq 讀 body 的正當查詢難以區分。
#   (5) shell 註解誘餌：`gh pr edit N --body '沒有狀態行'  # --body-file 合格.md`
#       —— 同 (1) 的抽取機制，create 側在 main 就有同一個洞。
#   (6) hook timeout：settings.json 給這支 5 秒，而 inline `--body` 塞夠長的 gh/pr
#       密集雜訊會讓上面的 case glob 比對超時被砍掉 → 放行（實測 14000 字元 4.8 秒）。
#       `--body-file` 免疫（指令列短）。相對 main 不是 regression，但這份清單自承在窮舉。
# 以及一類**誤擋**（同樣不補）：
#   (7) 指令字串任何位置出現 `--body` 且同時依序含 gh／pr／edit —— commit message、
#       `rg` 探查、`--title` 值提到旗標名都會命中。症狀有三種訊息（缺狀態行／`--body-file`
#       指向一個從該字串憑空造出的路徑／含 command substitution），都指不到真正的問題。
#       create 側在 main 就是同一個形狀（`git commit -m "… gh pr create …"` 實測即被擋），
#       本檔 :18「刻意接受誤擋」涵蓋這一類；收斂它需要 token 化解析，違反該設計約束。
#       jq 不可用時比對範圍是整個 payload（含 description／cwd／transcript_path），比這
#       行描述的更寬。
case "$SCAN_CMD" in
  # 已知 arm shadowing，main 既有行為，本次刻意不動：字串中出現 create 的 edit 指令
  # （`--add-label created`、`--title "add create button"` 等）會先命中這條，走下面的
  # body 檢查而被擋。不改成先判 edit —— `gh pr create --fill --title "add credit page"`
  # 沒有 `--body*`，改順序後會落到 edit arm 的 `exit 0` 變成 fail-open，比誤擋嚴重得多。
  # 順序由下方 selftest 釘住。
  *gh*pr*create*) ;;
  *gh*pr*edit*)
    case "$SCAN_CMD" in
      # 長形式：走下面與 create 同一套檢查。涵蓋 --body、--body-file、--body-file=。
      *--body*) ;;
      # 不碰 body、且字串不含 create 的 edit（--add-label／--add-reviewer 等）安靜放行。
      *) exit 0 ;;
    esac
    ;;
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
  # 範例刻意兩行都用 SKIPPED：被擋的人常把這段訊息貼進 body 當說明，而範例若寫
  # `S5 Standards: PASS`，一個真正兩軸 SKIPPED 的 docs PR 就會因為 body 裡出現那個形狀
  # 而失去下方的豁免，接著被要求它誠實填不出來的三欄——兩則 deny 訊息互相打架（S5 實測）。
  deny "[S5-1] PR body 缺 $missing 狀態行。進 PR 的變更 MUST 跑 Standards 與 Spec 兩軸，各標 PASS／FAIL／SKIPPED（附理由）／UNAVAILABLE（附 probe）。請在 PR body 加入例如：
  S5 Standards: SKIPPED（低風險 docs，未跑審查）
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
#   * baseline 標題最強，但也只是「真的讀到 reviewer-template.md 的那一節」。它**不是**
#     證明——決心造假的人照樣抄得到兩個詞。
#     這一項換過三版才定案，前三版都是「在該檔放一個識別碼、要求 ledger 引用它」，
#     S5 三輪各打掉一次：值被複印進消費端 → 兄弟指紋可代換 → 引入它的 commit message
#     自己寫出了值。根因是識別碼與「讀過那一節」之間沒有必然關係，每堵一條旁路就長出
#     下一條。改驗 contract 內容之後這整類問題消失：標題外流等於 contract 外流，正是
#     要的結果，所以沒有洩漏面、不必輪替、deny 訊息也可以直說要什麼。
#   * 三欄只是關鍵詞在場檢查。寫「reviewer 型別：無」照樣過；三個詞散落在不相干散文
#     （「呼叫 reviewer service，用 agent id 當 cache key，寫入 finding 表」）也照樣過，
#     S5 實測。它擋的是「只有兩行狀態、其餘什麼都沒有」的空洞 body，不是刻意造假。
#     刻意造假由 review 本身承擔，不是 hook。
# 用寬鬆關鍵詞而非逐字欄名，是為了不誤擋 ledgers.md 範例那種散文寫法
# （`reviewer=dotnet-code-reviewer（agent id dcr-07）；2 findings 皆採納並修`）——
# 誤擋會逼人把 body 改成迎合 hook 的形狀，那比漏擋更糟。
#
# 豁免：兩軸皆 SKIPPED = 完全沒跑審查（[S5-1] 允許低風險 docs／trivial change 這樣標），
# 三欄與指紋無從產生。只要有一軸真的跑過就要求——**UNAVAILABLE 算跑過**：
# reviewer-template.md 明寫無審查者時是在 agent id 欄填 UNAVAILABLE 並附 probe，
# 那仍是三欄的一部分，不是三欄的豁免。
#
# 第三個條件（沒有任何非 SKIPPED 狀態值）不是保險，是這個豁免唯一能成立的理由。
# bash 的 `=~` 在多行字串上是「任意位置匹配」，前兩個條件因此只證明 body 的**某處**
# 長得像 `S5 Standards: SKIPPED`，不是真正的狀態行就是它。S5 實測到兩種放行：
#   * 狀態 PASS/PASS，散文裡引用了兩個 SKIPPED 形狀 → 整段豁免（本 PR 自己的 body
#     只要描述 skipped_body fixture 就命中）。
#   * 兩軸皆 **FAIL**，散文同上 → 零記錄放行。
# 這是本檔第一條由 body 內容驅動的 early exit 0，而 exit 0 對 PreToolUse 就是放行，
# 所以它必須比其他判定更嚴，不是更鬆。
# 前兩個條件在目前排序下是 documentation 不是判定：上方的 `missing` gate 已保證兩軸各
# 跟著一個合法狀態值，第三個條件又排除掉 PASS/FAIL/UNAVAILABLE，於是那個值只能是 SKIPPED。
# 實證：把條件一改成 `true`，selftest 仍全過。留著是因為它們寫明了「兩軸皆 SKIPPED」這個
# 意圖，而且一旦有人把本區塊移到 `missing` 的 deny 之前，它們立刻變成活判定。
#
# 修法的覆蓋範圍要說準（前一版註解宣稱過寬）：第三個條件只關掉「真狀態是 PASS/FAIL/
# UNAVAILABLE，而散文另外提到 SKIPPED 形狀」那一半。body **完全沒有真狀態行**、只靠散文
# 滿足上方 gate 時，豁免仍會成立——那是 gate 1 本身可被散文滿足的既有性質，不是本區塊
# 引入的，修它要改的是 gate 1 的比對方式。
if [[ "$BODY" =~ S5[[:blank:]]+Standards:[[:blank:]]*SKIPPED([^A-Za-z0-9_]|$) ]] &&
   [[ "$BODY" =~ S5[[:blank:]]+Spec:[[:blank:]]*SKIPPED([^A-Za-z0-9_]|$) ]] &&
   ! [[ "$BODY" =~ S5[[:blank:]]+(Standards|Spec):[[:blank:]]*(PASS|FAIL|UNAVAILABLE)([^A-Za-z0-9_]|$) ]]; then
  exit 0
fi

# agent id 用逐字欄名而非 `|UNAVAILABLE` alternation：後者會被狀態行自己的
# `S5 Standards: UNAVAILABLE` 滿足，於是這條檢查對最需要它的那種 PR 恰好失效。
# 分隔符收寬到 `[[:blank:]_-]*`：`agent_id`／`agent-id`／`agentId` 都是合法寫法，
# 只認一個 ASCII 空白會誤擋它們——這條檢查的攔截力本來就低，再拿它製造誤擋不划算。
#
# 已知不足（S5 實測，不修）：inline `--body` 時 BODY 是整條 command（見上方 `BODY="$CMD"`），
# 於是 `--title`／`--label` 的值也能滿足這四項。--body-file 路徑沒有這個問題（只讀檔案內容，
# 理由見該處註解）。不修的理由是可靠的修法要解析 shell 引號，而本檔開宗明義拒絕解析 shell
# 語法——那會開出新的規避路徑，比這個洞更糟。實務上寫得下完整 ledger 的 PR 都用 --body-file。
#
# 同一個洞有嚴重一級的形態，一併記著：`--title 'S5 Standards: SKIPPED / S5 Spec: SKIPPED'`
# 配 inline body 會**觸發上方的豁免**而不只是「餵滿四項」——豁免是 early exit 0，四項一項
# 都不會查（S5 實測 ALLOW，`--label` 同）。
#
# 另有兩個本檔管不到的相鄰破口，記為已知、不在本次範圍：
#   * 五條 baseline 標題就寫在下面的迴圈裡，所以把本檔這一段貼進 PR body 即可通過檢查
#     （S5 實測）。design note 說「標題外流等於 contract 外流」對 reviewer-template.md 與
#     ledgers.md 成立——那裡標題連同定義一起帶走；對這個裸字串清單不成立。命中的正是
#     「改這支 hook 並把 diff 貼進 body」那種 PR。改讀 reviewer-template.md 可以堵，但會
#     把剛擺脫的跨 repo 執行期依賴請回來，不划算。
#   * （2026-08-24 已修）`gh pr edit` 帶長形式 body 旗標現在走與 create 同一套檢查。
#     殘留的繞過路徑見上方 dispatch 處的 ceiling 清單。
record=""
[[ "$BODY" =~ [Rr]eviewer ]] || record="reviewer 型別"
[[ "$BODY" =~ [Aa]gent[[:blank:]_-]*[Ii][Dd] ]] || record="${record:+${record}、}agent id"
[[ "$BODY" =~ [Ff]inding ]] || record="${record:+${record}、}finding 摘要"

# baseline 標題用字面比對（`case` 而非 `=~`）：標題含空白，當成 regex 沒有好處只有踩到
# metachar 的風險。要求兩條而不是一條——單一標題（尤其 `Wrong Altitude`）較可能在無關
# 討論裡出現，兩條同時出現則幾乎只可能來自那一節。
baseline_hits=0
for _title in 'Reinvented Stdlib' 'Redundant Dependency' 'Unused Local Reuse' 'Needless Indirection' 'Wrong Altitude'; do
  case "$BODY" in
    *"$_title"*) baseline_hits=$((baseline_hits + 1)) ;;
  esac
done
[ "$baseline_hits" -ge 2 ] || record="${record:+${record}、}over-engineering baseline 五條中至少兩條的逐字標題"

[ -z "$record" ] && exit 0

# 三欄的名稱逐字列出、baseline 五條刻意不列，這個不對稱是有意的：三欄名稱在 ledger 定義裡
# 本來就寫著，藏它只會讓被擋的人不知道要補什麼；baseline 標題本身就是那一項要驗的證據，
# 列出來等於這道檢查自己交出答案（S5 實測前一版印指紋值時即被貼回 body 繞過）。
deny "[S5-1] 兩軸狀態齊了，但 PR body 缺 ${record}。至少一軸非 SKIPPED＝審查真的跑過，reviewer-template.md「審查者 MUST 記錄」要求三欄，缺一不得判 S5 PASS：
  reviewer 型別／agent id（無審查者時此欄填 UNAVAILABLE + probe 指令與失敗理由）／finding 逐條摘要
另需逐字引用該檔 over-engineering baseline 五條中至少兩條的標題（同一行內、大小寫相符），證明那一節真的被讀到。這裡不列出五條是什麼——去讀 ~/.agents/skills/dev-workflow/references/reviewer-template.md 的 reviewer prompt 區塊裡「house over-engineering baseline 五條」那份清單，讀了自然引得出。
兩軸皆 SKIPPED（低風險且沒跑審查）時本檢查不適用。"
