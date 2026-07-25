# Global Preferences

<!-- last audited 2026-07-25; next review: 2027-01-03 或主檔 > 150 行（拆 path-scoped rule）；> 200 行重構整體 -->
<!-- 三 tier 正本在 ~/.agents/core（claude,codex,copilot 共用），經 ~/.claude/core symlink @import 常駐載入 -->
<!-- 本檔只放「Claude 專屬且必須常駐」的判斷；細則走 skill / 文末 @import 漸進揭露。routing stamp 由 agents-sync 機械刷新，勿手改 -->
@~/.claude/core/tier0-safety.md
@~/.claude/core/tier1-workflow.md
@~/.claude/core/tier2-style.md

## Defaults
- Package manager：npm（CI 用 `npm ci`）
- Runtime：follow `global.json` / `.nvmrc`；無則取最新 LTS。各棧版本 pin 見對應 `~/.claude/rules/*.md`
- macOS case-insensitive FS：改檔名大小寫用 `git mv`

## Tooling 優先序
- 文件查詢優先 MCP > web search；Microsoft / Azure / .NET → microsoft-learn（Context7 的觸發條件由其 MCP server instructions 自帶，勿再複述）

## Skill Routing（Claude 專屬層；通用路由與 stack →`*-best-practices` 見文末 routing stamp，不重複）
- **Workflow（mp-* 為 escalation 不是 default）**：
  - Bug / debug → default `superpowers:systematic-debugging`；重現率 < 50% / flaky / 效能 regression 找不到根因才 escalate `mp-diagnose`；修復完成後知識沉澱收尾 → `bug-fix-settlement`
  - TDD / red-green-refactor → default `superpowers:test-driven-development`；user 指名 vertical-slice tracer bullet 才升 `mp-tdd`
  - Architecture / refactor / testability 改善 → `mp-improve-codebase-architecture`；變更後收尾 `code-simplifier` agent（注意：依賴專案 CLAUDE.md 的 stack coding standards，缺則會 fallback 內建 JS/React 慣例、對其他 stack 套錯標準且不警告）
  - Code review → 流程走 `superpowers:requesting-code-review`（dispatch 一個 `general-purpose` reviewer subagent + 套 `code-reviewer.md` 模板給乾淨 context，回饋接 `receiving-code-review`）；需 stack 專精深審時改 dispatch 對應 agent（.NET → `dotnet-code-reviewer`，其餘 → `code-reviewer`），與前者擇一非並用。審查優先序 / conventional comments 正本 = dev-workflow `reviewer-template.md`，PR body 自審 = `ledgers.md` Preflight
  - 進陌生 code area 需 system map → `/mp-zoom-out`（無 `CONTEXT.md` / domain glossary 時自動降級為泛用詞彙描述）
  - 架構視覺化：default = `docs/codebase/ARCHITECTURE.md` 內嵌 mermaid（`design-doc-mermaid` 產）；互動 HTML 僅 opt-in 提議（複雜狀態機 / 非技術 stakeholder / 長生命週期才提）；rot 守護與勿手改衍生圖正本見 dev-workflow S6
  - 需求釐清 → 計畫 → 實作 鏈：`mp-grill-with-docs` 拷問細節、邊談邊產出 / 更新 `CONTEXT.md` + ADR（lazily 建，非前提）→ `superpowers:brainstorming` 探索 approach + 產 design spec（`docs/superpowers/specs/`；其 terminal state 強制接 writing-plans，勿 invoke 其他 skill）→ `superpowers:writing-plans` 產實作計畫 doc（`docs/superpowers/plans/`，bite-sized task 已內嵌 TDD 紅綠循環）→ 實作驅動 `superpowers:executing-plans`（inline 批次 + checkpoint）或 `superpowers:subagent-driven-development`（每 task 開新 subagent + 兩段審查）
  - doc 分工互補非重複：`CONTEXT.md` + `docs/adr/` = 領域語言 / 決策；`specs/` = 設計；`plans/` = 執行步驟
- **CI gate**：repo 託管 GitHub 且無 `.github/workflows/` 時，首次開 PR 前主動提議加 CI workflow（至少 build + test，依 stack 與目標平台選 runner / matrix）；同意後加在「會進目標分支的 branch」（既有開著的 PR 須加在其 head 分支才觸發）。既有 CI 不主動重寫。
- **瀏覽器 / E2E 工具分工**（互補不互斥）：探索式互動 + 生成測試骨架 → `agent-browser`；E2E 回歸測試固化進 CI → Playwright；效能 / 偵錯 → Chrome DevTools MCP；前端實作後 UI/UX 視覺品質審查 → `uiux-reviewer` agent

## Security
- Secrets：env var 或 secret manager；提供 `.env.example`（只 key name）；遮罩與禁印規則見 [T0-4]

## Workflow（規則正本在 tier0-2 @import；此處只放 Claude 專屬補充）
- Push back 判準：更簡單做法落在 [T1-7] 層級內才提（附 trade-off）；一般 implementation detail 不擴成選項討論
- 新增外部套件前評估維護狀態、license、版本相容與專案既有 dependency policy（CVE 由 `dependency-security-scan` 把關）
- 非 git repo 既有專案動手前先提議 `git init` + baseline commit（throwaway sandbox / 一次性 script 例外）
- Subagent 平行探索限「單一目標 + 結構化交付物」；跨檔重構別拆
- [R-4] Ponytail（plugin 注入的 lazy prose）只約束「解法規模」（最小可行實作），MUST NOT 凌駕 tier0 / [R-1] / [R-2] gates；review / verify / debug 類 subagent 的徹底性不受其約束。觸發：ponytail prose 與任一 gate 或審查深度衝突。驗證：gate 產物齊全才放行。例外：無。

## Self-Maintenance（Boris 原則：Claude 做錯就加進 CLAUDE.md）
- **MUST** 同錯第二次發生 → 主動提議加進對應 CLAUDE.md / rules（用戶確認後再寫）；只記「為何」+「下次如何避免」
- 學到教訓：專案特定 → `tasks/lessons.md`（隨 git）；跨專案 → auto memory 或本檔
- 沉澱前評估「能否機械化」：預防檢查可寫成 hook / test / lint 者，考慮落地為機械守護（如 hookify）取代 prose；判斷類知識才寫 prose

## Git Preferences（commit 格式 / force-push / reproducible commit 見 [T2-2] [T0-3] [T1-3]）
- PR merge：預設 squash（atomic commits 才用 rebase，需明確指定）；合併後自動刪除該 PR 分支（remote + 已併入的 local），無須再問
- Merge gate：綠 CI + bot review 處理完才 merge（[T0-9]）；完整 triage 流程（異步等待、thread 回覆、全 caller 對抗掃描）見 dev-workflow S6 → review-triage.md
- 套件安裝：package.json + lockfile 同 commit；純設定（lint / 格式化）獨立 commit
- 不 commit：AI 生成 plan / scratch、`.claude/settings.local.json`

## Auto-mode Commit 規則（default mode 維持「請求才 commit」）
- 觸發：完成邏輯單元（feature / fix / refactor / 套件安裝 / 設定變更 / 文件更新）主動 commit 無須問
- 仍需用戶確認：main / master / 受保護分支、revert、邏輯混雜（提議拆）、累積 5+ 未 push 的自動 commit

## Comment Policy（規則正本 [T2-4]）
- 修改既有 code 同步更新註解；註解 rot 視同 bug

## Verification（evidence [T0-2]；baseline [T1-4]）
- 無法跑驗證時明確記錄原因＋事後可執行的補跑指令（含必要 env 前綴）
- 任務轉成可驗證 goal：「修 bug」→「寫 reproduce test 並通過」、「加 validation」→「寫 invalid input test 並通過」、「refactor」→「修改前後 test 全綠」；goal 夠明確 → verify-loop 可獨立跑，模糊 → 回去補 goal
- 不直接覆寫 production config

## 可選載入（按專案語境用 @import 顯式引入）
- .NET：`@~/.claude/rules/dotnet.md`
- TypeScript：`@~/.claude/rules/typescript.md`
- Frontend SPA：`@~/.claude/rules/frontend-spa.md`（含 Web API auth / SPA storage 細則）
- WinForms：`@~/.claude/rules/winforms.md`
- C/C++：`@~/.claude/rules/cpp.md`
- 測試任務：`@~/.claude/rules/testing.md`
- DevOps / 基礎設施：`@~/.claude/rules/infra.md`
- Cookbook 知識庫（專案採用 `docs/cookbook/` 時）：`@~/.claude/rules/cookbook.md`
- /compact 或 cross-session handoff：`@~/.claude/templates/compact.md`

<!-- agents-routing:begin | generated-from: ~/.agents/core/routing.md | last-verified: 2026-07-25 -->
<!-- tier: 1 | consumed-by: claude,codex,copilot | generated-from: core/routing.md | last-verified: 2026-07-13 -->
<!-- FP:ROUTING-2026Q3 -->

# 開發任務路由（薄層；workflow 正本在 dev-workflow skill）

- 任何開發任務：先讀 ~/.agents/skills/dev-workflow/SKILL.md 並照其 S0 決策表路由。描述含錯誤行為 / 測試失敗 / regression 的走 SKILL.md 的 BUGFIX 鏈；單一 target file、≤3 個 actionable tasks 且未命中風險攔截者走 skill sdd。
- 逐名點名 skill（Codex 端 description 被截斷至 2–6 字元，路由靠點名不靠 description）：dev-workflow、sdd、deps-check、mp-grill-with-docs、mp-diagnose、bug-fix-settlement、frontend-release-verification、backend-release-verification、dependency-security-scan、design-doc-mermaid。
- 通用路由（本體皆在 ~/.agents/skills/）：stack 實作 → 同名 `*-best-practices`；Auth → `auth-implementation-patterns`；Docker → `containerization`；Tailwind v4 → `tailwind-v4-shadcn`；新專案初始化 → `init-project-docs`；整庫上手 → `acquire-codebase-knowledge`。
- 工具鏈 / 專項（非 `*-best-practices` 命名，須逐名點名才可路由）：Vite 設定 / 建置 / 打包問題 → `vite`；Vitest 測試撰寫與設定 → `vitest`；安全稽核 / 威脅面盤點 → `security-audit`；PR 級安全審查 → `security-review`；瀏覽器探索式互動 → `agent-browser`。
- Stack 版本 pin / 細則按需讀 `~/.agents/rules/<stack>.md`（dotnet、typescript、frontend-spa、winforms、cpp、testing、infra、cookbook）。

## 最高風險攔截（常駐，防新鮮 skill prose 搶贏路由，尤其 superpowers 終態鏈）

- [R-1] 收尾類 skill（如 finishing-a-development-branch）MUST NOT 在 S4/S5 全綠前 invoke。觸發：任務仍有 FAIL 或未跑的 verify / review gate。驗證：S4 與 S5 四態全 PASS 才放行。例外：無。
- [R-2] fix 之前 MUST 先有 failing regression test（紅→綠）；無可測 seam 須明確標記例外並附替代驗證。觸發：修 bug 的變更無先行紅測。驗證：紅燈輸出存在於證據。例外：無 seam（須標記）。
<!-- agents-routing:end -->
