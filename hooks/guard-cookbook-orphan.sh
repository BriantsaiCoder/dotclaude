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

file_path="$(printf '%s' "$input" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" \
  2>/dev/null || true)"

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
cat >&2 <<EOF
[cookbook 守衛] 偵測到要在 docs/cookbook/ 寫內容檔，但 $cookbook_root/MOC.md 不存在。
直接寫入會產生無索引的孤兒檔（cookbook rot，見 ~/.claude/rules/cookbook.md）。
請擇一：
  1) 先建立 docs/cookbook/README.md + MOC.md 三層結構，再寫內容檔並同步 MOC 索引；
  2) 若這次知識量不值得起一套 cookbook，改寫進 memory。
EOF
exit 2
