# Claude Code 全域配置

個人版控的 `~/.claude/` 設定，跨機器同步、月度審查。

## 結構

```
CLAUDE.md            # 全域偏好（< 200 行；超過 150 行觸發 review）
rules/               # 技術棧細則，由 CLAUDE.md 用 @import 顯式載入
  cpp.md / dotnet.md / frontend-spa.md / infra.md
  testing.md / typescript.md / winforms.md
templates/
  compact.md         # /compact 與 cross-session handoff 模板
agents/              # 自訂 subagent 定義
commands/            # 自訂 slash commands
hooks/               # 自訂 hooks（audit-bash / session-time / turn-mode 問題型單代理／開發型視同 Workflow opt-in steer / guard-* / mcp 修補）
skills/              # 自訂 skill（多為 symlink 至 ~/.agents/skills/）
settings.json        # Claude Code 設定
statusline-command.sh
playwright-mcp-config.json
```

## 追蹤範圍

`.gitignore` 採 allowlist 策略，**只追蹤上述設定檔**。執行期狀態（`history.jsonl` / `sessions/` / `projects/` / `cache/` / `agent-memory/` / `plans/` / `tasks/` / `todos/` / `telemetry/` / `*.bak.*`）一律排除，避免敏感對話與快取入庫。

## 月度 review

CLAUDE.md 行 3 註明 `last audited` 與 `next review`；觸發條件：
- 主檔逼近 150 行 → 拆規則進 `rules/`
- 主檔逼近 200 行 → 重構
- 同錯第二次發生 → 加進對應檔（Boris 原則）

## Pre-commit 守門

`.git/hooks/pre-commit` 阻擋誤 commit：
- 包含「token / api[_-]?key / secret / password」明文的 staged 內容
- `history.jsonl` / `*.bak` / `settings.local.json`
- 體積異常大的單檔（> 1 MB）

繞過（謹慎）：`git commit --no-verify`

## 還原到新機器

```bash
cd ~ && git clone <repo-url> .claude-tmp
mv .claude-tmp/.git .claude/.git
cd .claude && git reset --hard HEAD
```

> 直接 clone 蓋掉現有 `~/.claude/` 會毀損 runtime state；採上面 detach-head 法只接管版控部分。
