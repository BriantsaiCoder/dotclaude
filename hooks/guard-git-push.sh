#!/usr/bin/env bash
# PreToolUse(Bash) guard — [T0-3] force-push 前置攔截（async:false，可 block）
# 攔截：任何非 lease force push（--force / -f / +refspec）；任何 force 變體
#（含 --force-with-lease）推 main/master。放行：非保護分支 --force-with-lease、一般 push。
# 無明示 refspec 時以 payload cwd 解析當前分支；解析失敗保守拒絕（fail-closed）。
set -uf
JQ="$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
INPUT="$(cat)"
CMD=$(printf '%s' "$INPUT" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
[ -z "$CMD" ] && exit 0
case "$CMD" in *git*push*) ;; *) exit 0 ;; esac
CWD=$(printf '%s' "$INPUT" | "$JQ" -r '.cwd // empty' 2>/dev/null) || CWD=""

block() { printf '{"decision":"block","reason":"%s"}\n' "$1" >&2; exit 2; }

check_seg() {
  local seg="$1" t target
  local -a toks=($seg) args=()
  local i seen_git=0 seen_push=0 has_force=0 has_lease=0
  for ((i = 0; i < ${#toks[@]}; i++)); do
    t=${toks[i]}
    if (( ! seen_push )); then
      [[ "$t" == git ]] && seen_git=1
      [[ $seen_git -eq 1 && "$t" == push ]] && seen_push=1
      continue
    fi
    case "$t" in
      --force-with-lease|--force-with-lease=*) has_lease=1 ;;
      -f|--force)                              has_force=1 ;;
      --*|-*)                                  : ;;
      +*)                                      has_force=1; args+=("${t#+}") ;;
      *)                                       args+=("$t") ;;
    esac
  done
  (( seen_push )) || return 0
  (( has_force )) && block "[T0-3] 禁用非 lease force push（--force / -f / +refspec）。非保護分支請改用 --force-with-lease。"
  (( has_lease )) || return 0
  if (( ${#args[@]} >= 2 )); then
    target="${args[1]##*:}"      # refspec 可能是 src:dst，取 dst
  else
    target=$(git -C "${CWD:-.}" symbolic-ref --short HEAD 2>/dev/null || true)
    [[ -z "$target" ]] && block "[T0-3] --force-with-lease 未明示 refspec 且無法解析當前分支，保守拒絕（請明示 origin <branch>）。"
  fi
  case "${target#refs/heads/}" in
    main|master) block "[T0-3] 禁止 force push（含 --force-with-lease）到 main/master。" ;;
  esac
  return 0
}

# 複合命令切段（; | & 皆為段界），只檢查含 git push 的段
while IFS= read -r seg; do
  [[ -n "$seg" ]] && check_seg "$seg"
done <<< "$(printf '%s' "$CMD" | tr ';|&' '\n')"

exit 0
