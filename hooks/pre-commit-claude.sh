#!/bin/bash
# Pre-commit 守門：阻止誤 commit 敏感檔、明文 secret、超大檔。
# 安裝：bash hooks/install-pre-commit.sh
# 繞過（謹慎）：git commit --no-verify

# -f（noglob）是 load-bearing：下方 staged_files 的切詞靠未加引號的展開，沒有它時
# staged 一個名為 pre*.md 的檔會展開成 cwd 裡所有 pre*.md（實測 1 個變 4 個）。
# 放檔頭而不是中途 set -f，與 hooks/guard-git-push.sh 的 `set -ufo pipefail` 同形狀——
# 中途改全域 shell state 是留給未來編輯的陷阱。
set -efuo pipefail

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

# core.quotePath=false 不可省：預設 true 時 git 會把含非 ASCII 的路徑輸出成
# `"projects/\346\270\254..."`（含前導雙引號與八進位跳脫），於是 `^projects/` 不匹配、
# `[[ -f "$f" ]]` 也是 false → 黑名單／大小／secret 三項對該檔全數靜默跳過。
# 使用者本機是 false 所以現在不咬人，換一台機器或 CI 就會（2026-08-26 實測）。
# 仍不涵蓋檔名本身含 `"`／`\`／控制字元者——那類無論此旗標為何都會被引號化。
staged=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR)
[[ -z "$staged" ]] && exit 0

# 不用 here-string 切行。macOS 的 bash 3.2 把 `<<<` 的暫存檔放在 /tmp（**忽略** TMPDIR），
# /tmp 不可寫時才退回 cwd；沙箱下兩者皆不可寫 → redirect 失敗 → 迴圈體一次都不跑。
# set -e 攔不住：重導向失敗只讓該複合命令失敗，腳本繼續，於是檢查靜默跳過而 commit 照過。
# 這在 ~/.claude 上每次 commit 都會發生（git hook 的 cwd 是 repo root，落在 denyWrite 內），
# 而在 scratchpad 的 clone 裡永遠不會——所以「我這邊重現不了」不構成反證。
# 改用 IFS 切詞的參數展開：無暫存檔、無 subshell（errors 的累加必須留在當前 shell）。
# noglob 已在檔頭 set -efuo 開啟，未加引號的展開不會被 glob 展開——與 guard-git-push.sh
# 同一個解法。`${IFS-}` 而非 `$IFS`：IFS 未設時 set -u 會直接 abort（實務不可達，git 是
# 直接 exec hook、bash 啟動必定設好 IFS，但不留這個形狀）。
_oldifs=${IFS-}
IFS=$'\n'
# shellcheck disable=SC2206 # 刻意的未加引號展開：靠 set -f + IFS=$'\n' 切行，見上方註解
staged_files=( $staged )
IFS=$_oldifs
unset _oldifs

# 陣列為空就中止。在 bash 3.2 上這條**走不到**：`staged=$(...)` 會剝掉所有 trailing
# newline，所以 $staged 非空即含至少一個非 newline 字元，IFS=$'\n' 切詞必得 >=1 個 word；
# 而且該平台 set -u 對空陣列展開 "${arr[@]}" 本來就會噴 unbound variable 而 fail-closed。
# 保留的理由只有一個：bash >= 4.4 的 "${arr[@]}" 對空陣列**不**報錯，屆時這裡是唯一防線。
# 這與 guard-git-push.sh:165-167 拒絕同型備援的裁決不衝突——該處用非空白的 IFS=$'\034'，
# 連續分隔字元會產生空欄位故必然非空；本處 IFS=$'\n' 是 IFS whitespace，會塌縮。
if (( ${#staged_files[@]} == 0 )); then
  fail "內部錯誤：staged 非空但切詞結果為空，黑名單／大小／secret 檢查都會被跳過。中止。"
  exit 1
fi

for f in "${staged_files[@]}"; do
  for p in "${BLOCKED_PATTERNS[@]}"; do
    if [[ "$f" =~ $p ]]; then
      fail "黑名單檔案: ${f}（match: ${p}）"
      errors=$((errors + 1))
      break
    fi
  done
done

# 2. 單檔 > 1 MB
for f in "${staged_files[@]}"; do
  [[ -f "$f" ]] || continue
  size=$(wc -c < "$f" | tr -d ' ')
  if (( size > 1048576 )); then
    fail "檔案過大 ($((size / 1024)) KB > 1 MB): $f"
    errors=$((errors + 1))
  fi
done

# 3. 明文 secret 偵測（key=value / "key": "value" 形式）
SECRET_REGEX='(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer[_-]?token|password|client[_-]?secret|private[_-]?key)["'"'"' ]*[:=][ ]*["'"'"']?[A-Za-z0-9/_+=.-]{16,}'
HIGH_ENTROPY_HINTS='(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{32,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

# 只印檔名:行號＋pattern 類別，不印命中行內容（避免 secret 值進 terminal / scrollback，[T0-4]）
locate_hits() {
  local regex="$1" label="$2" f gf hits raw rc
  for f in "${staged_files[@]}"; do
    [[ -f "$f" ]] || continue
    # grep 的 rc 要分三態，且必須拿到 **grep 自己的** rc——所以它不能待在 pipeline 裡
    # （pipefail 下 pipeline 的 rc 是最右邊的非零值，分不出是誰失敗的）。
    #   rc=0   有命中
    #   rc=1   無命中——正常，靜默跳過
    #   rc>=2  grep 本身失敗（檔案不可讀、I/O error、grep 不存在回 127…）——**必須出聲**。
    # 先前寫成 `... | ... || true`，把 rc>=2 一起吞掉：命中位置在真正出錯時也靜默消失，
    # 排障訊號歸零。這與 tests/repo-integrity.sh 的 _no_tempfile_redirect() 對 grep rc、
    # 以及該檔 parity 斷言對 cmp rc 的處置是同一條教訓。
    # 檔名前的 `--` 同樣不可省：路徑以 `-` 開頭時 grep 會當成 option
    #（2026-08-08 agents-config #71 review 已為同一個坑落過字）。
    # `--` 擋得住 `-foo` 被當 option，**擋不住單一 `-`**：它在 `--` 之後仍是 stdin 的意思
    # （實測：printf '' | grep -inE -- 'x' -  → rc=1，看起來像「無命中」，定位靜默消失；
    #  改成 ./- 則 rc=0 正確掃到檔案）。所以以 `-` 開頭的路徑一律加 ./ 前綴再餵給 grep。
    # 顯示仍用原始 ${f}，不讓使用者看到被改寫過的路徑。
    gf="$f"
    [[ "$gf" == -* ]] && gf="./$gf"
    # -m 5 在 grep 端就停：命中很多的檔不必把全部行讀進 shell 變數再截斷。
    # 實測 rc 三態不受影響（有命中 0／無命中 1／檔案不存在 2），所以下方判斷照舊，
    # 而 `head -5` 因此成為冗餘、已移除。
    rc=0
    raw=$(grep -inE -m 5 -- "$regex" "$gf" 2>/dev/null) || rc=$?
    if [[ "$rc" -ge 2 ]]; then
      echo "  $f: 無法定位命中行（grep rc=${rc}）——檔案可讀嗎？" >&2
      continue
    fi
    [[ "$rc" -eq 0 ]] || continue
    hits=$(printf '%s\n' "$raw" | cut -d: -f1 | paste -sd, -)
    [[ -n "$hits" ]] && echo "  $f:${hits} (pattern: $label)" >&2
  done
  return 0  # 無命中時勿讓迴圈尾狀態 1 觸發 set -e
}

# git diff 必須拆出 pipeline 並單獨判 rc。原本寫成
#   diff_added=$(git diff ... | grep ... | grep ... || true)
# 那個 `|| true` 是為了「沒有新增行時 grep rc=1 屬正常」，但它同時吞掉 **git diff 自己的
# 失敗**——於是 secret 偵測整段靜默跳過而 commit 照過。這是本 commit 反覆在修的同一個病
# 的第四種拼法（here-string 失敗、`|| true` 吞 grep rc>=2、`|| echo` 兜底路徑、這一個）。
# secret gate 失去依據時 MUST fail-closed。
_gdrc=0
diff_raw="$(git diff --cached --diff-filter=ACMR -U0)" || _gdrc=$?
if (( _gdrc != 0 )); then
  fail "git diff --cached 失敗（rc=${_gdrc}）——secret 偵測無法執行，不靜默略過。中止。"
  exit 1
fi
# 這裡的 `|| true` 才是對的：兩個 grep 在「沒有新增行」時回 rc=1，屬正常。
diff_added=$(printf '%s\n' "$diff_raw" | grep -E '^\+' | grep -vE '^\+\+\+') || true
if [[ -n "$diff_added" ]]; then
  if echo "$diff_added" | grep -iE "$SECRET_REGEX" > /dev/null; then
    fail "疑似明文 secret（key=value 形式）— 檢查 staged 變更"
    locate_hits "$SECRET_REGEX" "SECRET_REGEX"
    errors=$((errors + 1))
  fi
  if echo "$diff_added" | grep -E "$HIGH_ENTROPY_HINTS" > /dev/null; then
    fail "疑似高熵 token / 私鑰"
    locate_hits "$HIGH_ENTROPY_HINTS" "HIGH_ENTROPY_HINTS"
    errors=$((errors + 1))
  fi
fi

if (( errors > 0 )); then
  fail "$errors 項問題，commit 中止。確認無誤可用 git commit --no-verify 繞過"
  exit 1
fi

exit 0
