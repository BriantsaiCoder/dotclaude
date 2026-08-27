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
  # deny 理由一律拿 jq 解碼後的 .reason 比對，不對 raw JSON 做子字串。理由裡若出現
  # 引號或反斜線，raw JSON 會是跳脫後的形式，子字串比對就會無故落空。
  # 這一層兩個 helper 都用；fixture 有效性檢查則各寫各的——runraw 要比對逐字相符，
  # run 只需要「gate 可執行且有輸出」，抽成共用函式反而是只有一個呼叫端的多餘一層。
  reason_has() { # 1=hook 的 stderr  2=必含片語
    printf '%s' "$1" | jq -e --arg want "$2" '.reason | index($want) != null' >/dev/null 2>&1
  }
  run() { # 1=desc 2=command 3=state 4=expect 5=額外欄位（選填，接在 head=abc 之後）6=理由必含片語（選填）
    # fake gate 只對 PR 42 回報指定的 STATE，其他編號一律 PASS。這讓「PR 編號抓錯」
    # 表現為誤放行（exit 0），才會被 expect=2 的案例抓到；若不分編號一律回同一個
    # STATE，抓錯編號的 bug 在 selftest 裡完全不可見。
    if [ -n "$3" ]; then
      # shellcheck disable=SC2016 # $1 要原樣寫進 fake gate 腳本，此處不得展開
      printf '#!/bin/sh\nif [ "$1" = 42 ]; then printf "STATE=%s pr=42 head=abc%s\\n"; else printf "STATE=PASS pr=%%s head=abc\\n" "$1"; fi\n' "$3" "${5:-}" > "$d/gate"
    else
      printf '#!/bin/sh\nexit 1\n' > "$d/gate"
    fi
    chmod +x "$d/gate"
    # fixture 有效性：fake gate 不可執行或印不出東西時，hook 走「找不到 pr-review-gate」
    # 那條路——那也是 exit 2，於是所有 expect=2 的案例會**假 PASS**。實測把這裡的 fixture
    # chmod -x，補這道檢查之前仍有 8 條 gate-dependent 的 expect=2 案例保持綠，而那 8 條
    # 正是本檔存在的理由（STATE 到決策的對應）。
    # state 為空的案例刻意用一個 exit 1 的 gate（測「gate 執行失敗時擋」），
    # 它本來就印不出東西，所以那條跳過這道檢查。
    if [ -n "$3" ] && { [ ! -x "$d/gate" ] || [ -z "$("$d/gate" 42)" ]; }; then
      printf '  FAIL  %s（fixture 無效：fake gate 不可執行或無輸出）\n' "$1"; f=$((f+1)); return
    fi
    r=$(jq -cn --arg cmd "$2" --arg cwd "$d/repo" '{tool_input:{command:$cmd},cwd:$cwd}' |
      PR_REVIEW_GATE="$d/gate" "$0" 2>&1 >/dev/null)
    g=$?
    case "$r" in
      *'找不到可執行的 pr-review-gate'*)
        printf '  FAIL  %s（hook 沒讀到 fixture gate）\n' "$1"; f=$((f+1)); return ;;
    esac
    if [ "$g" != "$4" ]; then
      printf '  FAIL  %s（期望 exit=%s 實得 %s）\n' "$1" "$4" "$g"; f=$((f+1)); return
    fi
    # 只驗 exit code 分不出「擋對了」與「因為別的理由擋住」。三個 deny 分支的 exit code
    # 完全相同，理由卻必須讓人看出是政策拒絕、格式漂移、還是 gate 根本不通過——
    # 2026-08-27 S5 round 1 兩軸都指出：舊版斷言只驗 rc，於是 ci= 落在行尾時
    # BILLING_QUOTA 被誤擋、ABSENT 拿到「找不到 ci= 欄」的假理由，兩者在 selftest 裡全綠。
    if [ -n "${6:-}" ] && ! reason_has "$r" "$6"; then
      printf '  FAIL  %s（理由未含 %s，實得：%s）\n' "$1" "$6" "$r"; f=$((f+1)); return
    fi
    printf '  PASS  %s\n' "$1"; p=$((p+1))
  }

  # runraw：run() 的 fake gate 形狀固定為 STATE=X pr=42 head=abc<額外欄位>，測不到
  # 「ci= 緊接 STATE」「tab 分隔」「第二行噪音」這些整行形狀。runraw 直接指定 gate 要印
  # 的整段內容。兩者並存不是重複——run() 的 gate 依 PR 編號分流（抓錯編號會表現為誤放行），
  # runraw 的不分流，換來對輸出形狀的完全控制。
  runraw() { # 1=desc 2=gate 印的內容 3=expect 4=理由必含片語（選填）
    # 用 %b 不用把 $2 當格式字串：後者會讓內容裡的 % 被當成轉換規格，
    # url=https://x/y%2Fz 這種再平常不過的 fixture 會被靜默改寫成 y0.000000z，
    # 而「非空」檢查看不出來。%b 讓 % 保持字面、\n 仍被解釋。
    printf '#!/bin/sh\nprintf %%b %s\n' "'$2'" > "$d/gate"
    chmod +x "$d/gate"
    # 有效性不只驗「非空」，而是驗**逐字等於預期**——這才擋得住上面那種靜默改寫。
    gate_want=$(printf '%b' "$2")
    gate_got=$("$d/gate" 42 2>/dev/null || true)
    if [ ! -x "$d/gate" ] || [ "$gate_got" != "$gate_want" ]; then
      printf '  FAIL  %s（fixture 無效：fake gate 的輸出與預期不符）\n' "$1"; f=$((f+1)); return
    fi
    r=$(jq -cn --arg cmd 'gh pr merge 42' --arg cwd "$d/repo" '{tool_input:{command:$cmd},cwd:$cwd}' |
      PR_REVIEW_GATE="$d/gate" "$0" 2>&1 >/dev/null)
    g=$?
    case "$r" in
      *'找不到可執行的 pr-review-gate'*)
        printf '  FAIL  %s（hook 沒讀到 fixture gate）\n' "$1"; f=$((f+1)); return ;;
    esac
    if [ "$g" != "$3" ]; then
      printf '  FAIL  %s（期望 exit=%s 實得 %s）\n' "$1" "$3" "$g"; f=$((f+1)); return
    fi
    if [ -n "${4:-}" ] && ! reason_has "$r" "$4"; then
      printf '  FAIL  %s（理由未含 %s，實得：%s）\n' "$1" "$4" "$r"; f=$((f+1)); return
    fi
    printf '  PASS  %s\n' "$1"; p=$((p+1))
  }
  run 'STATE=PASS 放行'          'gh pr merge 42'                 PASS        0
  # 降級狀態依 ci= 分流（hard_deny[1]：三者中只有 BILLING_QUOTA 授權合併）。
  # 下面這一組（含本段之後所有帶 ci= 的 run／runraw）是本檔唯一驗到「哪一種降級可以
  # 合併」的地方——舊版三者一律 exit 0，分辨完全交給 classifier prose，也就是沒有任何
  # 機械攔截。這裡刻意不寫死項數：2026-08-27 S5 round 1 兩軸都指出前一版寫「五項」而
  # 實際是六項，註解一複述可枚舉的數量就會漂移。要知道有幾項就自己數 ci= 開頭的 run。
  run 'ci=BILLING_QUOTA 放行'    'gh pr merge 42'                 PASS_NO_CI  0 ' ci=BILLING_QUOTA review=CURRENT unresolved=0'
  # gate 有兩條路徑印 ci=BILLING_QUOTA，另一條帶 review=UNAVAILABLE；兩者都該放行，
  # hard_deny[1] 不區分它們。只測一條會讓另一條的迴歸看不見。
  run 'ci=BILLING_QUOTA(review=UNAVAILABLE) 放行' 'gh pr merge 42' PASS_NO_CI 0 ' ci=BILLING_QUOTA review=UNAVAILABLE reason=actions_billing_or_quota'
  run 'ci=ABSENT 擋'             'gh pr merge 42'                 PASS_NO_CI  2 ' ci=ABSENT review=CURRENT unresolved=0' '不授權合併的降級狀態'
  run 'ci=CANCELLED 擋'          'gh pr merge 42'                 PASS_NO_CI  2 ' ci=CANCELLED review=CURRENT unresolved=0' '不授權合併的降級狀態'
  # 無 ci= 欄位保守拒絕。舊版對這個形狀是 exit 0——放行一個連自己都分不出是哪種
  # 降級的狀態。deny 理由必須指名缺 ci=，見下方專屬斷言。
  run 'PASS_NO_CI 無 ci= 欄位擋'  'gh pr merge 42'                 PASS_NO_CI  2 '' '沒有可辨識的 ci= 欄位'
  # 這項守的是比對時前後帶空白。若寫成 *ci=BILLING_QUOTA* 不帶空白，url 裡的子字串
  # 就會讓一個根本沒有 ci= 欄位的輸出被誤放行——那是靜默的 fail-open，期望 exit=0
  # 才抓得到。輸出刻意不含真正的 ci= 欄，只在 url 裡藏該字串。
  run 'url 裡的 ci= 子字串不誤放行' 'gh pr merge 42'               PASS_NO_CI  2 ' review=CURRENT url=https://x/y?ci=BILLING_QUOTA' '沒有可辨識的 ci= 欄位'
  # 上一項只有「左側無空白」這一種形狀。單獨拿掉比對式左邊那個空白時它會紅，但單獨拿掉
  # **右邊**那個空白時它照樣綠——因為該 fixture 的子字串剛好落在行尾，右邊本來就沒有空白。
  # 2026-08-27 S5 round 1 Spec 軸實測到這個缺口（九個定向突變只有兩個變紅）。補上右側形狀：
  # 值是授權值的前綴，左側有空白、右側沒有。
  # 前綴命中的診斷是「ci= 欄在、值不認得」，不是「找不到 ci= 欄」——欄位明明在。
  run '值是授權值的前綴不誤放行' 'gh pr merge 42'                 PASS_NO_CI  2 ' ci=BILLING_QUOTA_PENDING review=CURRENT' '值不是 ABSENT'
  run '值是政策值的前綴不誤命中' 'gh pr merge 42'                 PASS_NO_CI  2 ' ci=ABSENT_SOON review=CURRENT' '值不是 ABSENT'
  # gate 若新增第四個降級理由，未知值一律不授權合併。
  run '未知 ci 值不授權合併'     'gh pr merge 42'                 PASS_NO_CI  2 ' ci=RUNNER_OUTAGE review=CURRENT' '值不是 ABSENT'
  # ci= 落在行尾。這是 2026-08-27 S5 round 1 兩軸獨立命中的主症狀：舊版比對式要求 ci 值
  # 右邊有空白，於是 ci= 是最後一欄時 BILLING_QUOTA 被擋——那是 Actions 額度用盡時唯一
  # 合法的合併路徑，而「讓 CI 跑起來」正是當下做不到的事。ABSENT 同形狀則拿到「找不到
  # ci= 欄」這個與事實相反的理由。gate 今天把 url= 放最後所以不可達，但 arm 的理由文案
  # 自稱就是要接格式漂移。
  run 'ci=BILLING_QUOTA 在行尾仍放行' 'gh pr merge 42'            PASS_NO_CI  0 ' review=CURRENT ci=BILLING_QUOTA'
  run 'ci=ABSENT 在行尾擋且理由講政策' 'gh pr merge 42'           PASS_NO_CI  2 ' review=CURRENT ci=ABSENT' '不授權合併的降級狀態'
  # 以下三組驗的是**整行形狀**，run() 的固定 gate 形狀表達不了，改用 runraw。
  #
  # (1) ci= 緊接 STATE：欄位之間只有一個空白，若把狀態與 ci= 寫成同一層 case pattern，
  #     狀態那半會把分隔空白吃掉，ci= 就沒有前導空白可比對。實測此形狀在一層寫法下被
  #     誤擋，而它正是 review-triage.md 第 2 節記載給維護者照抄的形狀。
  runraw 'ci= 緊接 STATE 仍放行' 'STATE=PASS_NO_CI ci=BILLING_QUOTA\n' 0
  runraw 'ci= 緊接 STATE 且為政策值時擋' 'STATE=PASS_NO_CI ci=ABSENT\n' 2 '不授權合併的降級狀態'
  #
  # (2) tab：**刻意不正規化**，這兩條釘住那個決定。曾經有一版把 tab 換成空白，好處是
  #     gate 哪天改用 tab 分隔時 deny 訊息比較好看；代價是值裡面的 tab 會憑空製造出
  #     欄位邊界——第三條就是那個代價，它在做正規化的版本裡是 exit 0。今天 gate 只用
  #     空白，所以好處不可達而代價是真的，於是不做。tab 分隔的行落到最後那條 arm，
  #     訊息附整行原文，維護者看得到分隔字元變了。
  runraw 'tab 分隔的行 fail-closed' 'STATE=PASS_NO_CI\tpr=42\tci=BILLING_QUOTA\treview=CURRENT\n' 2 'merge gate 未通過'
  runraw 'tab 分隔的政策值也 fail-closed' 'STATE=PASS_NO_CI\tpr=42\tci=ABSENT\n' 2 'merge gate 未通過'
  runraw '值裡面的 tab 不得製造出 ci= 欄' \
    'STATE=PASS_NO_CI pr=42 head=abc note=see\tci=BILLING_QUOTA\n' 2 '第一行混用了 tab'
  # 混用 tab 與空白：真的有 ci=ABSENT 但它以 tab 相連，只認空白的比對看不到它，
  # 同行以空白相連的 ci=BILLING_QUOTA 就會贏。這條在加 tab 守衛之前實測是 exit 0。
  runraw '混用 tab 與空白時不得繞過政策值' \
    'STATE=PASS_NO_CI pr=42 x=1\tci=ABSENT ci=BILLING_QUOTA\n' 2 '第一行混用了 tab'
  #
  # (2b) CRLF：命令替換只吃掉結尾的 LF，\\r 會留在 LINE1 尾端。不剝掉的話，ci= 是最後
  #      一欄時唯一被授權的狀態被擋、政策值拿到相反的理由、連裸 STATE=PASS 都變成
  #      「gate 未通過」。三個方向各釘一條。
  runraw 'CRLF 下 ci=BILLING_QUOTA 在行尾仍放行' \
    'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT ci=BILLING_QUOTA\r\n' 0
  runraw 'CRLF 下 ci=ABSENT 在行尾仍講政策' \
    'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT ci=ABSENT\r\n' 2 '不授權合併的降級狀態'
  runraw 'CRLF 下裸 STATE=PASS 仍放行' 'STATE=PASS\r\n' 0
  #
  # (2c) 值裡有空白 → 整行不再是純 KEY=VALUE，此時「ci=X 兩側有空白」不等於「有 ci= 欄」。
  #      下面這行**根本沒有 ci= 欄**，子字串卻剛好落在行尾被補上的那格空白之前。
  #      前後補空白修好了合法的行尾欄，同時打開了這個非法的——所以要有良構前提。
  runraw '值含空白時子字串不得冒充 ci= 欄' \
    'STATE=PASS_NO_CI pr=42 head=abc reason=fell back to ci=BILLING_QUOTA\n' 2 '不是純 KEY=VALUE'
  #
  # (3) 跨行：case 的 glob 會跨換行比對，而 gate 的輸出是連 stderr 一起收的。不切出第一行
  #     的話，第一行沒有 ci=、第二行的噪音帶著被空白包夾的 ci=BILLING_QUOTA 就會選到放行
  #     分支。deny 理由本來就只印第一行，比對面與證據面必須是同一個東西——否則放行的依據
  #     不會出現在任何輸出裡。2026-08-27 S5 round 1 兩軸獨立命中。
  runraw '次行噪音不得讓無 ci= 的首行放行' \
    'STATE=PASS_NO_CI pr=42 head=abc review=CURRENT\nhint: ci=BILLING_QUOTA path\n' 2 '沒有可辨識的 ci= 欄位'
  runraw '次行噪音不得覆蓋首行的政策值' \
    'STATE=PASS_NO_CI pr=42 head=abc ci=ABSENT\nwarn: ci=BILLING_QUOTA was considered\n' 2 '不授權合併的降級狀態'
  #
  # (4) 同一行出現兩個 ci= 時，保守的那一邊必須贏。這由 case 的 arm 順序決定：政策 arm
  #     排在放行 arm 之前。少了這兩條，把兩個 arm 對調（放行的 ci=BILLING_QUOTA 那條
  #     移到政策的 ci=ABSENT|ci=CANCELLED 之前）不會被任何斷言抓到——2026-08-27 實測該
  #     突變下整份 selftest 全綠。兩個順序都測，因為只測一個的話對調後仍有一半會過。
  # fixture 必須是良構的（每個 token 都是 KEY=VALUE），否則會先被上面的良構檢查攔下，
  # 測到的是那道檢查而不是 arm 順序。
  runraw '兩個 ci= 時政策值優先（政策值在前）' \
    'STATE=PASS_NO_CI pr=42 ci=ABSENT ci=BILLING_QUOTA review=CURRENT\n' 2 '不授權合併的降級狀態'
  runraw '兩個 ci= 時政策值優先（政策值在後）' \
    'STATE=PASS_NO_CI pr=42 ci=BILLING_QUOTA ci=ABSENT review=CURRENT\n' 2 '不授權合併的降級狀態'
  # 授權值與**未知**值同行：政策 arm 不命中，若沒有「多個 ci= 欄」那條就會走放行。
  # 兩個順序都測，理由同上。
  runraw '授權值與未知值同行時保守拒絕（授權值在前）' \
    'STATE=PASS_NO_CI pr=42 ci=BILLING_QUOTA ci=RUNNER_OUTAGE review=CURRENT\n' 2 '一個以上的 ci= 欄位'
  runraw '授權值與未知值同行時保守拒絕（授權值在後）' \
    'STATE=PASS_NO_CI pr=42 ci=RUNNER_OUTAGE ci=BILLING_QUOTA review=CURRENT\n' 2 '一個以上的 ci= 欄位'

  # 這項守的是「明示」本身：舊版寫 STATE=PASS* 前綴 glob，gate 那邊新增任何以 PASS 開頭
  # 的狀態都會被無聲放行，沒有人需要同意。收緊成精確比對後，未列入的一律擋。
  run '未列入的 PASS_ 前綴仍擋'  'gh pr merge 42'                 PASS_FUTURE 2
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
  # 上一項的 fixture 是空白分隔的，測不到真實 payload 的形狀：JSON 裡 gh 黏在 command:
  # 後面，normalize 不動 : , { }，token 化切出 `{tool_input:{command:gh` 而不是 `gh`。
  # 這項用真實 JSON 形狀（缺結尾大括號讓 jq 解析失敗），且 command 值經 normalize 後不含
  # 字面 merge，所以只能靠 has_gh_pr 攔——正是 2026-08-06 實測 exit=0 的那條漏擋路徑。
  # shellcheck disable=SC2016 # $( ) 是測試字面，不得展開
  if printf '%s' '{"tool_input":{"command":"gh pr m$(printf er)ge 42"},"cwd":"/tmp"' |
       PR_REVIEW_GATE="$d/gate" "$0" >/dev/null 2>&1; then
    printf '  FAIL  jq fallback 未還原 JSON 的 token 邊界（fail-open）\n'; f=$((f+1))
  else
    printf '  PASS  jq fallback 還原 JSON token 邊界後仍保守拒絕\n'; p=$((p+1))
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

  # 輸出格式解耦 canary：gate 目前每一行都帶 pr= 等欄位，只比對「STATE=X 後面接空白」也會過。
  # 但那是把 hook 綁在 gate 現在的格式上——gate 哪天改成只印 STATE，就會被誤擋，而且是
  # 沉默的：merge 停住，理由看起來像 gate 不通過。用只印 STATE 的 fake gate 守住這件事。
  #
  # 2026-08-27 起 PASS_NO_CI 不再列入本迴圈：依 ci= 分流後，一個沒有 ci= 欄的
  # PASS_NO_CI 無從分辨是三種降級的哪一種，放行它等於放行未知形狀。改為 fail-closed，
  # 但 canary 的原意（不要沉默地壞掉）以下方那條「deny 理由必須指名缺 ci=」承接——
  # 要防的是理由說不清楚，不是 deny 本身。
  # PASS_NO_CI 移出後只剩一個放行狀態，迴圈就地展開成一條 runraw。
  runraw 'STATE=PASS 無尾隨欄位仍放行' 'STATE=PASS\n' 0

  # 承接上方 canary 的原意：PASS_NO_CI 少了 ci= 欄時擋下來是對的，但理由必須讓人
  # 一眼看出是「gate 輸出格式變了」而不是「gate 判定不通過」。只驗 exit code 分不出
  # 這兩者——那正是原 canary 說的沉默壞掉。所以這裡直接驗 deny 理由的字面。
  printf '#!/bin/sh\nprintf "STATE=PASS_NO_CI pr=42 head=abc review=CURRENT\\n"\n' > "$d/gate"
  chmod +x "$d/gate"
  noci_out=$(jq -cn --arg cmd 'gh pr merge 42' --arg cwd "$d/repo" '{tool_input:{command:$cmd},cwd:$cwd}' |
    PR_REVIEW_GATE="$d/gate" "$0" 2>&1 >/dev/null)
  # 釘的是**這個 arm 獨有**的片語，不是裸的 ci=。前一版寫 index("ci=")，而三個 deny
  # 分支的理由全都含字面 ci=（arm 2 的政策文案、arm 4 的格式文案、arm 5 夾帶的 gate 原文），
  # 於是這條斷言分不出「指名了正確欄位」與「講了完全相反的理由」。2026-08-27 S5 round 1
  # 兩軸實測：把理由換成聽起來像政策拒絕的文字，這條照樣綠。
  if printf '%s' "$noci_out" | jq -e --arg want '沒有可辨識的 ci= 欄位' '.decision == "block" and (.reason | index($want) != null)' >/dev/null 2>&1; then
    printf '  PASS  PASS_NO_CI 缺 ci= 欄時 deny 理由指名該欄位\n'; p=$((p+1))
  else
    printf '  FAIL  PASS_NO_CI 缺 ci= 欄時 deny 理由未指名該欄位（沉默誤擋）：%s\n' "$noci_out"; f=$((f+1))
  fi
  # 「政策拒絕必須講政策」這條原本在這裡另寫一塊，與上方 run 'ci=ABSENT 擋' 同一個
  # fixture、同一個片語。run() 有了理由參數之後它就是重複，已刪除；覆蓋由那條 run 承接
  # （實測刪掉政策 arm 仍讓套件變紅，所以不是靠這塊撐著）。

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
  # 這裡的 SCAN_INPUT 是**整段 JSON**，不是單獨的 command 字串。normalize 不動 : , { }，
  # 所以 `"command":"gh pr ..."` 到這裡是 `command:gh pr ...`——gh 黏在 command: 後面，
  # token 化切出來的是 `{tool_input:{command:gh`，既不等於 gh 也不匹配 */gh，帶
  # substitution 的合併指令會被漏擋。那是 fail-open，而且正好落在最該保守的路徑。
  # 2026-08-06 Copilot 於 PR #15 指出，實測 exit=0 確認。
  #
  # 把 JSON 結構字元換成空白還原 token 邊界。`/` 刻意不換：換掉的話
  # /opt/homebrew/bin/gh 會被拆成好幾段，*/gh 這條完整路徑比對就失效了。
  if has_subst "$INPUT" && has_gh_pr "${SCAN_INPUT//[\{\}\[\]:,]/ }"; then
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
# 不用 here-string 切段。macOS 的 bash 3.2 把 `<<<` 的暫存檔放在 /tmp（**忽略** TMPDIR），
# /tmp 不可寫時才退回 cwd；兩者皆不可寫時 redirect 失敗 → 陣列留空 → 下面找不到目標段
# → exit 0＝放行。同型缺陷 2026-08-08 在 guard-git-push.sh 實測確認（agents-config #70）。
# 純參數展開沒有暫存檔；本檔已 set -f（檔頭 set -ufo），未加引號的展開不會被 glob。
saved_ifs=$IFS
IFS="$SEP"
segments=($CMD_SEGMENTS)
IFS=$saved_ifs

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
  seg_toks=($seg)   # 同上：不用 here-string，避免 cwd 唯讀時切詞失敗
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

# 放行狀態逐一列出，不用 `STATE=PASS*` 這種前綴 glob。前綴 glob 會自動吃掉未來任何以
# PASS 開頭的新狀態——gate 那邊新增一個 STATE=PASS_ANYTHING，這裡就無聲放行了，沒有人
# 需要同意。降級路徑正是這種形狀，所以它必須是**明寫的一條**，不是 glob 順便涵蓋到的。
#
# 這條規則原本寫的是「每個狀態兩個 pattern：後面接空白／就是行尾」，理由是 gate 哪天
# 改成只印 STATE 就會被誤擋，而誤擋雖然 fail-closed 卻是**沉默的**壞掉——merge 停住而
# 理由看起來像 gate 不通過。理由仍然成立，作法已由下方的前後補空白取代：補了之後
# 「行尾」與「行中」是同一件事，不再有第二個 pattern 可以忘記寫。
# 2026-08-06 Copilot 於 PR #16 指出；2026-08-27 S5 round 1 兩軸實測「只寫接空白那個」
# 的實際後果不只誤擋——ci= 落在行尾時被擋掉的正是 ci=BILLING_QUOTA，也就是唯一被
# hard_deny[1] 授權的那一個。改為補空白後這整類位置相依性消失。
# 前綴 glob 的禁令不受補空白影響：`" STATE=PASS "*` 仍要求 STATE=PASS 後面緊接空白，
# 未來的 STATE=PASS_ANYTHING 一樣不會被順便放行。
#
# PASS_NO_CI 是 gate 拿不到 CI 結論時的降級狀態（不是「還在跑」——那仍是 WAIT_CI）。
# 它放寬的只有「CI 必須驗過」這一項；unresolved 必須為 0、review 必須對到 current head 這些
# 條件在 gate 那邊一項都沒鬆。
#
# **這道 case 曾經看不到 ci=**（2026-08-27 更正；同日稍晚已改為分流，見本段末）。
# 原註解寫「接受它是三層明示
# 的其中一層，另外兩層是 gate 自己回報 ci=ABSENT，以及 settings.json 的 hard_deny 也必須明寫
# 接受。任何一層沒改就不會放行」——那句話**不成立**，而且是把不存在的一層算進來：
#   * gate 對 **三種** ci 值都印同一個 STATE=PASS_NO_CI（pr-review-gate:453 的
#     ci=BILLING_QUOTA 分支，以及 :480 的 ABSENT|CANCELLED|BILLING_QUOTA 分支）。
#   * 下面的 case 只比對 STATE= 前綴，ci= 落在 "STATE=PASS_NO_CI "* 的萬用字元裡，
#     三者一律 exit 0。所謂「gate 自己回報 ci=ABSENT」從來沒有被任何程式碼讀取過。
# 在分流之前，唯一能區分三者的只剩 settings.json 的 hard_deny[1]——那是 classifier
# prose，不是機械攔截。ci=ABSENT 與 ci=CANCELLED 不授權合併、ci=BILLING_QUOTA 需要
# 的額外 local evidence，都寫在那裡；現在下面的 case 對前半段做了機械攔截，後半段
# （補償證據是否真的成立、suppressed=N 是否逐條處置過）本 hook 仍查不到，依舊由
# classifier 與人承擔。放行 ci=BILLING_QUOTA 不等於那些條件已經滿足。
#
# 以下是分流之前「為什麼不在這裡比對 ci=」的理由，及其邊界（2026-08-27 S5 round 2 更正）：
# 前一版寫的是「那會把 review-triage.md 第 2 節整套 fallback 條件搬進本 hook，而其中沒有
# 一項是 hook 查得到的」。那句話對「驗證補償證據」成立，但被拿來否定另一件不同的事——
# **分辨三個狀態**。ci= 就印在 hook 已經讀到的同一行裡，分辨它不需要驗證任何東西。
# S5 round 2 用一份會動的 patch 示範：四行 case 依 ci= 分流（ABSENT 放行、CANCELLED 與
# BILLING_QUOTA deny），重跑 hooks.sha256 後 85 PASS / 0 FAIL、本檔 selftest 45 PASS / 0 FAIL。
# 所以選項有三個不是兩個，而第三個嚴格強於現況的無條件 exit 0。
#
# 上面兩段描述的是 2026-08-27 之前的狀態，保留是因為它記錄了洞怎麼來的。使用者已於
# 該日指名此改動，下面的 case 現在依 ci= 分流。**但那份草案的方向是相反的**——它寫
# ABSENT 放行、CANCELLED 與 BILLING_QUOTA deny。照草案實作會同時放行政策禁止的狀態、
# 並擋掉唯一被授權的那個，也就是 Actions 額度用盡時連合法路徑都沒了。實作採用的是
# 與草案相反的正確方向。
# 草案與政策的先後：兩者**同在 53de575（PR #38）**落地——該 commit 既加進本檔這段
# 草案註解，也把 hard_deny[1] 改成「只有 BILLING_QUOTA 授權」。本段前一版寫「那份
# 草案早於 PR #38」，是假的，2026-08-27 S5 round 1 Spec 軸指出並經 git show 逐檔核對
# （50b92b7 兩者皆無、53de575 兩者皆有）。PR #38 自己出的就是這對自相矛盾的東西。
OUT=$("$GATE" "$PR" 2>&1) || true
# 比對前只做三件事：取第一行、剝掉行尾一個 CR、前後各補一格空白。
#
#   * 只取第一行——case 的 glob 會跨換行比對，而 OUT 併了 stderr。第一行沒有 ci=、
#     第二行的噪音帶著被空白包夾的 ci=BILLING_QUOTA，就會選到放行分支 exit 0。
#     deny 理由本來就只印第一行，比對面與證據面必須是同一個東西，否則放行的依據
#     不會出現在任何輸出裡。
#   * 剝行尾 CR——命令替換只吃掉結尾的 LF，CRLF 會在 LINE1 尾端留下 \r。留著的話
#     ci= 是最後一欄時 BILLING_QUOTA 被擋（那是額度用盡時唯一合法的合併路徑）、
#     ci=ABSENT 拿到「找不到 ci= 欄」這個相反的理由、裸 STATE=PASS 直接變成
#     「gate 未通過」。CR 只會出現在行尾，剝它不會改變任何欄位邊界。
#   * 前後補空白——讓行首欄與行尾欄不必各寫一個 pattern。少了這層，ci= 落在行尾時
#     BILLING_QUOTA 會被擋掉，ci=ABSENT 落在行尾會拿到與事實相反的理由。
#
# **不做 tab 正規化**，而且這是本檔唯一一處刻意不做的正規化，理由要記清楚：把 tab
# 換成空白會讓「值裡面的 tab」憑空製造出欄位邊界。實測 `note=see<TAB>ci=BILLING_QUOTA`
# 這種**根本沒有 ci= 欄**的行在做了 tab 正規化的版本裡是 exit 0，不做就是 exit 2。
# 買到的好處只是「gate 哪天改用 tab 分隔時 deny 訊息比較好看」——那個形狀今天不可
# 達；付出的代價是一道 [T0-9] 守衛上的 fail-open 面。方向不對等，所以不做。
# tab 分隔的行今天會落到最後那條 arm，訊息是「gate 未通過」並附上整行原文，維護者
# 看得到分隔字元變了。那是刻意接受的、fail-closed 方向的代價。
LINE1=${OUT%%$'\n'*}
LINE1=${LINE1%$'\r'}
PAD=" $LINE1 "
# 狀態與 ci= 分成兩層比對，不寫成 `" STATE=X "*" ci=Y "*` 這種一層的形式：欄位之間
# 只有**一個**空白，一層寫法會讓 STATE 的 pattern 把那個空白吃掉，ci= 就沒有前導空白
# 可比對。實測 `STATE=PASS_NO_CI ci=BILLING_QUOTA`（ci= 緊接 STATE，也是
# review-triage.md 第 2 節記載的形狀）在一層寫法下被誤擋。內層對整個 PAD 重新比對，
# 分隔空白不再被兩個 token 爭用。
case "$PAD" in
  " STATE=PASS "*) exit 0 ;;
  " STATE=PASS_NO_CI "*)
    # 含 tab 的行先擋掉，而且必須在良構迴圈**之前**。迴圈用 IFS 切詞（空白**加** tab），
    # 所以 `x=1<TAB>ci=ABSENT` 會被切成兩個都含等號的 token 而取得「良構」資格；但下面的
    # ci= 比對只認空白，看不到那個以 tab 相連的 ci=ABSENT，於是同一行以空白相連的
    # ci=BILLING_QUOTA 就贏了——實測 exit 0，一個真的政策拒絕被繞過。
    # 根因是迴圈與比對對「什麼算分隔」不一致，迴圈的 tab 切詞反而替只認空白的比對背書。
    # 整行統一用 tab 的情況不會走到這裡（外層 pattern 要求 STATE 後面緊接空白，那種行落到
    # 最後那條 arm）；這條接的是**混用**。
    case $LINE1 in
      *$'\t'*)
        deny "[T0-9] gate 回報 PASS_NO_CI，但第一行混用了 tab 與空白。ci= 欄位邊界只認單一空白，混用時無法可靠判定哪個 ci= 才是真正的欄位，保守拒絕。pr-review-gate #$PR 回報：$LINE1" ;;
    esac
    # 先確認整行是純 KEY=VALUE。gate 的每一條 printf 都是這個形狀（reason= 的值以
    # 底線相連，不含空白）。一旦出現不含 = 的 token，就代表某個欄位的值裡有空白，
    # 而此時「ci=X 兩側有空白」不再等於「有一個 ci= 欄位」——
    # `reason=fell back to ci=BILLING_QUOTA` 這種行根本沒有 ci= 欄，卻會讓補空白
    # 之後的子字串比對放行。認不得的格式一律保守拒絕，這是本分支的前提條件。
    # **這是收窄，不是關閉**，界線要講準。本檢查驗的是「每個 token 都含等號」，而程式碼
    # 真正需要的是「沒有任何欄位的值裡含空白」——後者推得出前者，反過來不成立。值裡有
    # 空白、而切出來的每一段又碰巧都帶等號時，檢查就過了。實測皆放行：
    #     reason=quota= ci=BILLING_QUOTA
    #     url=h://x?a=b c=d ci=BILLING_QUOTA
    #     note=a=1 ci=BILLING_QUOTA
    # 三行都沒有真正的 ci= 欄，那個字串是別的欄位的值的一部分。
    # 改成逐 token 取 ci= 的值也擋不住——切出來的 `ci=BILLING_QUOTA` 與一個真欄位逐字
    # 相同，任何以空白為界的方法都分不出來。要真正關閉需要 gate 端把值引號化，那不在
    # 本 hook 這一側，也不在本次改動的範圍。今天 gate 的 PASS_NO_CI 兩條 printf 的欄位
    # 值不含空白（reason= 是底線相連的字面），所以不可達。
    # 只在這個分支檢查：STATE=PASS 是行首精確比對騙不過，其餘狀態本來就一律 deny，
    # 對它們額外報「格式不對」只會把「gate 判定不通過」講成別的事。
    # shellcheck disable=SC2086 # 刻意 word-split；set -f 已關 glob
    for tok in $LINE1; do
      case $tok in
        *=*) ;;
        *) deny "[T0-9] gate 回報 PASS_NO_CI，但第一行不是純 KEY=VALUE（出現不含等號的 token「${tok}」），代表某個欄位的值裡有空白。這種形狀下無法可靠地認出 ci= 欄位，保守拒絕。pr-review-gate #$PR 回報：$LINE1" ;;
      esac
    done
    # deny 分支排在放行分支之前：同一行同時出現真的 ci=ABSENT 與某個欄位值裡的
    # ci=BILLING_QUOTA 時，保守的那一邊要贏。實測兩種排列順序都由這條先命中。
    case "$PAD" in
      *" ci=ABSENT "*|*" ci=CANCELLED "*)
        deny "[T0-9] gate 回報 PASS_NO_CI，但 ci= 是不授權合併的降級狀態。ABSENT 與 CANCELLED 代表 CI 該跑而沒跑，不是不適用；三者中只有 ci=BILLING_QUOTA 授權合併。請讓 CI 跑起來，不要繞過它。pr-review-gate #$PR 回報：$LINE1" ;;
      # 一行出現一個以上的 ci= 欄位就無從判定以哪個為準。政策值那條排在更前面，
      # 所以「政策值 vs 其他任何值」仍由政策值先命中（保守的一邊贏）；這條接的是
      # 「授權值 vs 未知值」——少了它，ci=BILLING_QUOTA 與一個本規則沒涵蓋的值同行
      # 時會走放行，與本檔自述的保守優先不一致。
      *" ci="*" ci="*)
        deny "[T0-9] gate 回報 PASS_NO_CI，但第一行有一個以上的 ci= 欄位，無法判定以哪個為準，保守拒絕。pr-review-gate #$PR 回報：$LINE1" ;;
      *" ci=BILLING_QUOTA "*) exit 0 ;;
      # ci= 欄在、值不是已知三者之一。與下面那條的差別是**診斷**：這裡欄位好好的，
      # 是 gate 多了一個本規則沒涵蓋的降級理由；下面那條才是欄位不見了。兩者都 deny，
      # 但叫維護者去查的東西不同。
      *" ci="*)
        deny "[T0-9] gate 回報 PASS_NO_CI，ci= 欄位在，但值不是 ABSENT／CANCELLED／BILLING_QUOTA 三者之一。這代表 pr-review-gate 新增了本規則沒涵蓋的降級理由——未知的降級一律不授權合併，要放行必須先在 settings.json 的 hard_deny 明寫接受。pr-review-gate #$PR 回報：$LINE1" ;;
      *)
        deny "[T0-9] gate 回報 PASS_NO_CI，但第一行沒有可辨識的 ci= 欄位，無法分辨三種降級狀態中的哪一種，保守拒絕。這通常代表 pr-review-gate 的輸出格式變了——請確認 ci= 欄是否仍以單一空白分隔。pr-review-gate #$PR 回報：$LINE1" ;;
    esac ;;
  *) deny "[T0-9] merge gate 未通過，禁止 merge。pr-review-gate #$PR 回報：$LINE1" ;;
esac
