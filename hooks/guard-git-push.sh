#!/usr/bin/env bash
#
# 共用 PreToolUse(Bash) guard — [T0-3] force-push 前置攔截（兩 host 單一實作）
#
# 用法: guard-git-push.sh --format=claude|codex   （由各 host 的薄 wrapper 傳入）
#
# 攔截：任何非 lease force push（--force / -f / 短旗標捆綁如 -fu / +refspec）；
#       任何 force 變體推 main/master；--force-with-lease 搭 --all/--mirror。
# 放行：非保護分支的 --force-with-lease、一般 push（含 push origin main）、非 push 指令。
# 無明示 refspec 時以 payload cwd 解析當前分支；解析失敗保守拒絕（fail-closed）。
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
set -uf

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

# jq 不可用或解析失敗時 MUST NOT 靜默放行（那會讓 [T0-3] 在缺 jq 的環境失效）。
# 但也不能一律拒絕——那會擋掉所有 Bash 指令。折衷：只對「原始 payload 就含 git+push」
# 的請求保守拒絕，其餘放行；使用者會看到明確理由而非靜默失去防線。
if [ -z "$JQ" ] || ! CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null); then
  case "$INPUT" in
    *git*push*) deny "[T0-3] jq 不可用或 payload 解析失敗，無法判定 push 目標，保守拒絕。請確認 jq 已安裝且在 PATH 中。" ;;
  esac
  exit 0
fi

[ -z "$CMD" ] && exit 0
case "$CMD" in *git*push*) ;; *) exit 0 ;; esac
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null) || CWD=""

check_target() {
  local target="${1##*:}"          # refspec 可能是 src:dst，取 dst
  target="${target#refs/heads/}"
  case "$target" in
    main|master) deny "[T0-3] 禁止 force push（含 --force-with-lease）到 main/master。" ;;
  esac
}

check_seg() {
  local seg="$1" t target
  local IFS=$' \t\n'
  local -a toks=($seg) args=()
  local i seen_git=0 seen_push=0 has_force=0 has_lease=0 broad_refset=0
  for ((i = 0; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if (( ! seen_push )); then
      # 只認裸 token `git` 會被完整路徑繞過（/usr/bin/git push --force …）。
      # 去掉外層引號後，比對 git 可執行檔的常見型態。
      local bare="${t%\"}"; bare="${bare#\"}"; bare="${bare%\'}"; bare="${bare#\'}"
      case "$bare" in git|*/git|git.exe|*/git.exe) seen_git=1 ;; esac
      [[ $seen_git -eq 1 && "$t" == push ]] && seen_push=1
      continue
    fi
    case "$t" in
      --force-with-lease|--force-with-lease=*) has_lease=1 ;;
      -f|--force)                              has_force=1 ;;
      --all|--mirror)                          broad_refset=1 ;;
      # 短旗標捆綁（git push -fu origin main）——單獨比對 -f 會漏
      -[a-zA-Z]*)                              [[ "$t" == *f* ]] && has_force=1 ;;
      --*)                                     : ;;
      +*)                                      has_force=1; args+=("${t#+}") ;;
      *)                                       args+=("$t") ;;
    esac
  done
  (( seen_push )) || return 0
  (( has_force )) && deny "[T0-3] 禁用非 lease force push（--force / -f / +refspec）。非保護分支請改用 --force-with-lease。"
  (( has_lease )) || return 0
  (( broad_refset )) && deny "[T0-3] --force-with-lease 搭配 --all/--mirror 無法排除保護分支，已保守拒絕。"
  if (( ${#args[@]} >= 2 )); then
    # args[0] 是 remote，其餘每個 refspec 都要查——只查第一個是舊版的破口
    for ((i = 1; i < ${#args[@]}; i++)); do
      check_target "${args[i]}"
    done
  else
    target=$(git -C "${CWD:-.}" symbolic-ref --short HEAD 2>/dev/null || true)
    [[ -z "$target" ]] && deny "[T0-3] --force-with-lease 未明示 refspec 且無法解析當前分支，保守拒絕（請明示 origin <branch>）。"
    check_target "$target"
  fi
  return 0
}

# 複合命令切段（; | & 皆為段界），只檢查含 git push 的段
IFS=$'\n'
for seg in $(printf '%s' "$CMD" | tr ';|&' '\n\n\n'); do
  case "$seg" in *git*push*) check_seg "$seg" ;; esac
done
exit 0
