# Claude Code 全域配置

個人版控的 `~/.claude/` 設定，跨機器同步。

## 結構

```
CLAUDE.md            # 全域偏好（thin budget 硬閘／軟閘由 tests/repo-integrity.sh §6 定義）
rules/               # 技術棧細則（載入方式見下）
  cpp.md / dotnet.md / frontend-spa.md / infra.md
  testing.md / typescript.md / winforms.md / cookbook.md
templates/
  compact.md         # /compact 與 cross-session handoff 模板
agents/              # 自訂 subagent 定義
commands/            # 自訂 slash commands
hooks/               # 自訂 hooks（audit-bash / session-time / turn-mode 提示分類 steer，行為見檔頭 / guard-* / mcp 修補）
skills/              # 自訂 skill（多為 symlink 至 ~/.agents/skills/）
settings.json        # Claude Code 設定
statusline-command.sh
playwright-mcp-config.json
```

`rules/` 的載入不是 `@import`：各檔 frontmatter `paths:` 命中時才注入。CLAUDE.md「On-demand stack rules」段的路徑寫在反引號內，官方明定 code span 內的 `@` 不解析，所以那一段只是指標。`cookbook.md` 另有專案端顯式 `@import` 的用法，見該檔檔頭。

## 追蹤範圍

`.gitignore` 採 allowlist 策略，**只追蹤上述設定檔**。執行期狀態（`history.jsonl` / `sessions/` / `projects/` / `cache/` / `agent-memory/` / `plans/` / `tasks/` / `todos/` / `telemetry/` / `*.bak.*`）一律排除，避免敏感對話與快取入庫。

## Review 觸發條件

事件驅動：
- 主檔逼近軟閘 → 先瘦身或搬進 skill（`tests/repo-integrity.sh` 會紅，訊息帶實際 byte 數）
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
