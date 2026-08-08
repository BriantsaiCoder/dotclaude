#!/usr/bin/env bash
# guard-cookbook-orphan.sh
# PreToolUse(Write|Edit)守衛：禁止在 docs/cookbook/ 下寫「內容檔」卻沒有 MOC.md 索引，
# 以硬擋 bug-fix-settlement 等流程自建無索引的孤兒檔（cookbook rot）。
# 慣例來源見 ~/.claude/rules/cookbook.md。
#
# 行為：
#   - 放行 MOC.md / README.md 本身（這是在建結構）
#   - 放行 MOC.md 已存在的情況（結構完整）
#   - 其餘在 docs/cookbook/ 下、且 MOC.md 不存在 → exit 2 阻擋，把理由回給 Claude
set -euo pipefail

input="$(cat)"

# 解析器健康度：要判的不只是「python3 在不在」，還有「它真的讀得懂這份 payload 嗎」。
# 兩種失效都讓 file_path 變成空字串，而空字串在下面直接 exit 0——於是整支守衛對缺
# python3 的環境、以及對格式異常的 payload，都靜默失效。
#
# 那是 fail-open：守衛存在的理由是擋 cookbook 孤兒檔，卻在讀不懂輸入時選擇放行。
# 同型缺陷 2026-08-02 在 ~/.agents 的 protect-files.sh 找到並修掉（agents-config
# PR #37），修法一致——gate 在「解析是否成功」而非「解析器是否存在」。原寫法的
# `|| true` 正是把前者的失敗吞掉的那一段。
parse_ok=1
file_path=""
if ! command -v python3 >/dev/null 2>&1; then
  parse_ok=0
else
  file_path="$(printf '%s' "$input" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" \
    2>/dev/null)" || parse_ok=0
fi

if [ "$parse_ok" -eq 0 ]; then
  # 沒有 stdin 代表這不是 hook 呼叫，擋它才是誤擋。
  [ -z "$input" ] && exit 0

  # 也不能一律拒絕——這支守衛只管一個目錄慣例，卻會在缺 python3 的環境下讓使用者
  # 任何專案的任何檔案都寫不了。折衷同 guard-git-push.sh:59-67：只對「原始 payload
  # 本身就提到 docs/cookbook」的請求保守拒絕，其餘放行。
  # 代價是 payload 壞到連這個字串都不剩時會漏放，但那類請求本來就不在守備範圍。
  case "$input" in
    *docs/cookbook*) ;;
    *) exit 0 ;;
  esac

  # 不用 here-doc：macOS 的 bash 3.2 把它的暫存檔放在 /tmp（忽略 TMPDIR），/tmp 不可寫
  # 時才退回 cwd；兩者皆不可寫時 redirect 失敗。本檔開了 set -e，於是連 exit 2 都走不到，
  # 改以 rc=1 結束——拒絕的語意還在，但理由不見了，exit code 也不再是契約上的 2。
  # printf 不碰暫存檔。
  printf '%s\n' \
    '[cookbook 守衛] 無法解析 hook payload，無從判斷目標是否在 docs/cookbook/ 下，保守拒絕。' \
    '兩種可能：python3 不可用（確認已安裝且在 PATH 中），或 payload 不是合法 JSON（確認 host 傳入的 stdin 格式）。' >&2
  exit 2
fi

[ -z "$file_path" ] && exit 0

# 只管 docs/cookbook/ 底下（絕對或相對路徑皆可）
case "$file_path" in
  *docs/cookbook/*) ;;
  *) exit 0 ;;
esac

# 結構檔本身放行——允許先建立索引／說明
case "$(basename "$file_path")" in
  MOC.md|README.md) exit 0 ;;
esac

# 推導該檔所屬的 docs/cookbook 根（對絕對與相對路徑都成立）
cookbook_root="${file_path%%docs/cookbook/*}docs/cookbook"

# MOC.md 已存在 → 結構完整，放行
[ -f "$cookbook_root/MOC.md" ] && exit 0

# MOC.md 不存在 → 阻擋
# 同上：不用 here-doc，cwd 唯讀時它會讓整個拒絕路徑走不完。
printf '%s\n' \
  "[cookbook 守衛] 偵測到要在 docs/cookbook/ 寫內容檔，但 $cookbook_root/MOC.md 不存在。" \
  '直接寫入會產生無索引的孤兒檔（cookbook rot，見 ~/.claude/rules/cookbook.md）。' \
  '請擇一：' \
  '  1) 先建立 docs/cookbook/README.md + MOC.md 三層結構，再寫內容檔並同步 MOC 索引；' \
  '  2) 若這次知識量不值得起一套 cookbook，改寫進 memory。' >&2
exit 2
