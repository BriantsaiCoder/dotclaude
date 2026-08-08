#!/usr/bin/env bash
#
# 共用 PreToolUse(Bash) guard — [T0-3] force-push 前置攔截（兩 host 單一實作）
#
# 用法: guard-git-push.sh --format=claude|codex   （由各 host 的薄 wrapper 傳入）
#
# 攔截 command literal 可判定的非 lease force／mirror；lease 只放行 exact token + 明示 remote +
# 單一非保護 refspec 的 canonical 形狀。一般 push（含 main／--all）與非 push 指令放行。
# Ceiling：不解析 Git config 的 remote.*.push／mirror 或 runtime shell expansion；由 repo pre-push、
# Tier 0 與 CI 疊加防護。
# git 可執行檔認 git / */git / git.exe / */git.exe——只認裸 token 會被完整路徑繞過。
# jq 不可用或解析失敗時，對含 git+push 的 payload 保守拒絕（不得靜默放行）。
#
# 輸出契約依 host 分流：
#   claude — {"decision":"block"} → stderr，exit 2
#   codex  — {"hookSpecificOutput":{…permissionDecision:"deny"}} → stdout，exit 0
# 放行路徑兩者相同：無輸出、exit 0。
#
# ⚠️ 已知且刻意的誤擋：比對對象是整個 command 字串，所以「只是提到」危險
# payload 的指令也會被擋（如 commit message 內文引用 --force-with-lease --all）。
# MUST NOT 為消除此誤擋而改成解析 shell 語法區分「真指令 vs 字串」——那會開出
# 引號規避路徑（false negative 對安全閘的代價遠高於 false positive）。
# 遇到誤擋的正解：把該文字移出 command 字串（如 git commit -F <file>）。
set -ufo pipefail

FORMAT=claude   # 未指定時取 exit-2 語意（fail-closed：寧可誤擋不可誤放）
for arg in "$@"; do
  case "$arg" in
    --format=claude) FORMAT=claude ;;
    --format=codex)  FORMAT=codex ;;
    --format=*)      printf 'guard-git-push: 未知 --format=%s，回退 claude\n' "${arg#--format=}" >&2 ;;
  esac
done

# JSON 字串轉義：純 bash 參數展開，不依賴 jq——deny() 必須在 jq 不可用時仍能輸出合法 JSON
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # 反斜線必須先轉，否則會把後面補的反斜線再轉一次
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

deny() {
  case "$FORMAT" in
    codex)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(json_escape "$1")"
      exit 0
      ;;
    *)
      printf '{"decision":"block","reason":%s}\n' "$(json_escape "$1")" >&2
      exit 2
      ;;
  esac
}

JQ="$(command -v jq 2>/dev/null || true)"
INPUT="$(cat)"
SCAN_INPUT=${INPUT//$'\\\n'/}
SCAN_INPUT=${SCAN_INPUT//\"/}
SCAN_INPUT=${SCAN_INPUT//\'/}
SCAN_INPUT=${SCAN_INPUT//\\/}
SCAN_INPUT=${SCAN_INPUT//\$/}
SCAN_INPUT=${SCAN_INPUT//\(/}
SCAN_INPUT=${SCAN_INPUT//\)/}

# jq 不可用或解析失敗時 MUST NOT 靜默放行（那會讓 [T0-3] 在缺 jq 的環境失效）。
# 但也不能一律拒絕——那會擋掉所有 Bash 指令。折衷：只對「原始 payload 就含 git+push」
# 的請求保守拒絕，其餘放行；使用者會看到明確理由而非靜默失去防線。
if [ -z "$JQ" ] || ! CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null); then
  case "$SCAN_INPUT" in
    *[Gg][Ii][Tt]*push*) deny "[T0-3] jq 不可用或 payload 解析失敗，無法判定 push 目標，保守拒絕。請確認 jq 已安裝且在 PATH 中。" ;;
  esac
  exit 0
fi

[ -z "$CMD" ] && exit 0
SCAN_CMD=${CMD//$'\\\n'/}
SCAN_CMD=${SCAN_CMD//\"/}
SCAN_CMD=${SCAN_CMD//\'/}
SCAN_CMD=${SCAN_CMD//\$/}
SCAN_CMD=${SCAN_CMD//\(/}
SCAN_CMD=${SCAN_CMD//\)/}
SCAN_CMD=${SCAN_CMD//[\{\},]/ }
SCAN_WIN=${SCAN_CMD//\\/\/}
SCAN_CMD=${SCAN_CMD//\\/}
check_target() {
  case "$1" in
    :|*\**) deny "[T0-3] --force-with-lease 搭配 matching／wildcard refspec 無法排除保護分支，已保守拒絕。" ;;
  esac
  local target="${1##*:}"          # refspec 可能是 src:dst，取 dst
  target="${target#refs/heads/}"
  [ -n "$target" ] || deny "[T0-3] --force-with-lease 的 refspec target 為空，無法排除保護分支，已保守拒絕。"
  if [ "$target" = @ ] || ! git check-ref-format --branch "$target" >/dev/null 2>&1; then
    deny "[T0-3] --force-with-lease 必須使用明確 branch ref，不接受 HEAD／@／revision shorthand。"
  fi
  case "$target" in
    main|master) deny "[T0-3] 禁止 force push（含 --force-with-lease）到 main/master。" ;;
  esac
}

check_seg() {
  local seg="$1" win_seg="$2" t win_t
  local IFS=$' \t\n'
  local -a toks=() win_toks=() args=()
  # 不用 here-string 切詞。macOS 的 bash 3.2 把 `<<<` 的暫存檔放在 /tmp（**忽略**
  # TMPDIR），/tmp 不可寫時才退回 cwd；兩者皆不可寫時 redirect 失敗 → 陣列留空 →
  # 下面的迴圈一次都不跑 → 落到檔尾 exit 0＝放行。這是 [T0-3] 的 fail-open，而且
  # 完全無聲——守衛的錯誤訊息進 stderr，host 只看 exit code。
  #
  # 2026-08-08 實測，同一個 `git push --force origin main` payload：
  #   sandbox 內（/tmp 被擋、cwd=~/.claude 唯讀）  rc=0 放行
  #   sandbox 外（/tmp 可寫）                       rc=2 攔截，cwd 權限無關
  # 所以「chmod 一個目錄當 cwd」重現不了它——條件是 /tmp 與 cwd 同時不可寫。
  #
  # 純參數展開沒有暫存檔。本檔已 `set -f`（見檔頭 set -ufo），故未加引號的展開不會被 glob。
  toks=($seg)
  win_toks=($win_seg)
  local i seen_git=0 seen_push=0 has_force=0 has_lease=0 lease_exact=0 other_option=0
  for ((i = 0; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    win_t=${win_toks[i]:-}
    if (( ! seen_push )); then
      # 只認裸 token `git` 會被完整路徑繞過（/usr/bin/git push --force …）。
      # Scan variants 已移除引號，並分別處理 shell escape 與 Windows path separator。
      case "$t" in [Gg][Ii][Tt]|*/[Gg][Ii][Tt]|[Gg][Ii][Tt].[Ee][Xx][Ee]|*/[Gg][Ii][Tt].[Ee][Xx][Ee]) seen_git=1 ;; esac
      case "$win_t" in [Gg][Ii][Tt]|*/[Gg][Ii][Tt]|[Gg][Ii][Tt].[Ee][Xx][Ee]|*/[Gg][Ii][Tt].[Ee][Xx][Ee]) seen_git=1 ;; esac
      [[ $seen_git -eq 1 && "$t" == push ]] && seen_push=1
      continue
    fi
    case "$t" in
      --force-with-lease)                                 has_lease=1; lease_exact=1 ;;
      --force-with-lease=*|--force-w*)                    has_lease=1 ;;
      -f|--force|--force=*|--forc|--m|--mi|--mir|--mirr|--mirro|--mirror) has_force=1 ;;
      # 短旗標捆綁（git push -fu origin main）——單獨比對 -f 會漏
      -[a-zA-Z0-9]*)                           if [[ "$t" == *f* ]]; then has_force=1; else other_option=1; fi ;;
      --*)                                     other_option=1 ;;
      +*)                                      has_force=1; args+=("${t#+}") ;;
      *)                                       args+=("$t") ;;
    esac
  done
  (( seen_push )) || return 0
  (( has_force )) && deny "[T0-3] 禁用非 lease force push（--force / -f / +refspec / --mirror）。非保護分支請改用 --force-with-lease。"
  (( has_lease )) || return 0
  (( lease_exact )) || deny "[T0-3] --force-with-lease 只接受不帶值的 exact token；拒絕縮寫與 = 變體。"
  (( other_option )) && deny "[T0-3] --force-with-lease 只允許 canonical 形狀，不得混用其他 option。"
  (( ${#args[@]} == 2 )) || deny "[T0-3] --force-with-lease 必須明示 remote 與單一 refspec。"
  check_target "${args[1]}"
  return 0
}

# 複合命令切段（; | & 與 newline 皆為段界），再逐 token 合併兩種 scan 視圖。
SEP=$'\034'
CMD_SEGMENTS=${SCAN_CMD//[\;\|\&]/$SEP}
CMD_SEGMENTS=${CMD_SEGMENTS//$'\n'/$SEP}
WIN_SEGMENTS=${SCAN_WIN//[\;\|\&]/$SEP}
WIN_SEGMENTS=${WIN_SEGMENTS//$'\n'/$SEP}
cmd_segments=()
win_segments=()
# 同 check_seg：不用 here-string，避免 cwd 唯讀時切段失敗而整段掃描被跳過（fail-open）。
saved_ifs=$IFS
IFS="$SEP"
cmd_segments=($CMD_SEGMENTS)
win_segments=($WIN_SEGMENTS)
IFS=$saved_ifs
# 這裡刻意不加「陣列為空就 deny」的備援：實測那條走不到。`[ -z "$CMD" ] && exit 0` 已擋掉
# 空指令，而 bash 對非空白 IFS 的切詞會為連續分隔字元產生**空欄位**，所以 `;;;` 這種
# 全分隔字元的輸入也會得到非空陣列。加了只會是「看起來有防護」的死碼。
for ((seg_i = 0; seg_i < ${#cmd_segments[@]}; seg_i++)); do
  check_seg "${cmd_segments[seg_i]}" "${win_segments[seg_i]:-}"
done
exit 0
