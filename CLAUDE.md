# Global Preferences

<!-- last audited 2026-05-10; next review: 2026-11-10 或主檔 > 150 行 -->
<!-- 技術棧細則於 ~/.claude/rules/*.md，需要時用 @import 顯式載入（見文末附錄） -->

## 優先序
衝突時：專案 CLAUDE.md > 全域 > Skills 通用規則。Skill 規則與用戶明確偏好衝突時以用戶偏好為準。

## Hard Rules
非 negotiable，違反屬 bug。
- **NEVER** 假設未驗證 file paths / APIs / config keys
- **NEVER** 無 evidence 標 task done
- **NEVER** force-push 到 `main` / `master`
- **NEVER** 把 token / 敏感資料放 frontend `localStorage` / `sessionStorage`
- **MUST** 模糊時停下發問，不靜默推進
- **MUST** auth / payment / migration / crypto 等高風險變更附 rollback 策略
- **MUST** 非 trivial 任務（3+ 步 / 多檔 / 架構性）進 plan mode；auto mode 雖減確認，仍 MUST plan
- **MUST** frontend UI 變更交付前以 Playwright MCP（headed）驗證；缺 GUI 環境（CI / 遠端 / Docker）明確回報 fallback headless

## Defaults
- Package manager：npm（CI 用 `npm ci`）
- Runtime：follow `global.json` / `.nvmrc`；無則取最新 LTS
- Fallback（過期前可直接用；過期後先以 Context7 / microsoft-learn / web search 確認當前 LTS 再 inline 更新）：.NET 10（→ 2028-11）、Node 24（→ 2028-04）、.NET Framework 4.8.1、C++20、C17
- macOS case-insensitive FS：改檔名大小寫用 `git mv`

## Tooling 優先序
- Library / framework 文件：Context7 MCP > web search
- Microsoft / Azure / .NET 文件：microsoft-learn MCP > web search

## Skill Routing
- **Stack 實作 MUST invoke 對應 skill**（即使你以為知道；不要在主檔重複該 skill 規則）：
  - 後端：.NET / EF / Dapper / SQL / Node → `*-best-practices`
  - 前端：React / Vue / TS / CSS → `*-best-practices`；React Router → `react-router-framework-mode`；Tailwind v4 + shadcn → `tailwind-v4-shadcn`；Pinia / VueUse / Nuxt → 對應 skill
  - 跨棧：Auth（JWT/OAuth/session）→ `auth-implementation-patterns`；Docker → `containerization`；Vitest / Jest / Playwright / Vite → 對應 skill；C/C++ → `c-cpp-best-practices`
- **Workflow（mp-* 為 escalation 不是 default）**：
  - Bug / debug → default `superpowers:systematic-debugging`；重現率 < 50% / flaky / 效能 regression 找不到根因才 escalate `mp-diagnose`
  - TDD / red-green-refactor → default `superpowers:test-driven-development`；user 指名 vertical-slice tracer bullet 才升 `mp-tdd`
  - Architecture / refactor / testability 改善 → `mp-improve-codebase-architecture`；變更後收尾 `simplify`
  - 進陌生 code area 需 system map → `/mp-zoom-out`
  - Conversation context → PRD：`mp-to-prd`
  - 需 `CONTEXT.md` / ADR alignment grilling → `/mp-grill-with-docs`；無 CONTEXT.md 退 `superpowers:brainstorming`
- **Verification gate**：部署前 → `frontend-release-verification` / `backend-release-verification` / `dependency-security-scan`
- **新專案初始化** → `init-project-docs`

## Security
- Secrets：env var 或 secret manager；提供 `.env.example`（只 key name）
- Web API auth 與 frontend SPA storage 細則：進 SPA 專案時用 `@~/.claude/rules/frontend-spa.md` 顯式載入

## Workflow
Plan first, code second. Verify before claim.
- **MUST** Plan mode 輸出編號步驟、影響檔案、預期結果，等用戶確認再動手
- Bug fix flow：reproduce → root cause → fix → regression test → verify
- 生成程式碼前先確認目標 runtime 版本與既有 dependency
- Ambiguous requirement：列選項 + 推薦方案 + trade-off，不自己猜
- Push back：用戶需求有更簡單做法 → 直說並建議，不盲從複雜實作。Trigger：(a) 標準函式庫已有卻引新依賴；(b) 50+ 行可由 10 行內建函式取代；(c) 抽象層只有單一使用點
- 自我簡化只動「自己當前正在寫的新 code」，不動既有 code；交付前自問「資深工程師會覺得 overcomplicated 嗎」（典型訊號：可壓縮 ≥ 50% 行數、抽象層只有單一 caller、提早泛型化），是則 rewrite
- **MUST** 修改既有 code 沿用該檔風格（縮排 / 命名 / 註解寫法 / pattern）即使個人偏好不同；不順手改不相關格式 / 命名 / 註解（發現另開 task）
- **MUST** 自己變更造成的 dead code（unused imports / variables / functions）必清；pre-existing dead code 提及但不刪，等 user 確認
- 非 git repo 既有專案動手前先提議 `git init` + baseline commit（throwaway sandbox / 一次性 script 例外）
- Subagent 平行探索限「單一目標 + 結構化交付物」；跨檔重構別拆
- /compact 或 cross-session handoff：用 `@~/.claude/templates/compact.md` 顯式載入

## Self-Maintenance（Boris 原則：Claude 做錯就加進 CLAUDE.md）
- **MUST** 同錯第二次發生 → 主動提議加進對應 CLAUDE.md / rules（用戶確認後再寫）；只記「為何」+「下次如何避免」
- 學到教訓：專案特定 → `tasks/lessons.md`（隨 git）；跨專案 → auto memory 或本檔
- 月度 review 觸發：主檔逼近 100 行 → 拆 `~/.claude/rules/`；逼近 200 行 → 重構

## Git Preferences
- Conventional Commits zh-TW（commit & PR title 皆 zh-TW）：`feat(api): 新增 xxx`、`fix(ui): 修正 xxx`、`chore(deps): 更新 xxx`
- Branch：`feat/`、`fix/`、`chore/`、`refactor/`
- PR merge：預設 squash；atomic commits 用 rebase
- Force push 只用 `--force-with-lease`（main / master 禁止見 Hard Rules）
- Commit 訊息第一行字數限制：英 ≤ 72 / 中 ≤ 30
- Reproducible commit：每個 commit 須能獨立 checkout build 通過；寧可大 commit 也別留 transient broken state
- 套件安裝：package.json + lockfile 同 commit；純設定（lint / 格式化）獨立 commit
- WIP：失敗探索 commit 訊息加 `[wip]` 限 feature branch；PR 前 interactive rebase / squash 整理
- 不 commit：AI 生成 plan / scratch、`.claude/settings.local.json`

## Auto-mode Commit 規則（default mode 維持「請求才 commit」）
- 觸發：完成邏輯單元（feature / fix / refactor / 套件安裝 / 設定變更 / 文件更新）主動 commit 無須問
- 仍需用戶確認：main / master / 受保護分支、revert、邏輯混雜（提議拆）、累積 5+ 未 push 的自動 commit

## Comment Policy（system override：覆蓋系統 default no-comments）
- **NEVER** 寫 what-paraphrase / 對話 context（例：「fixed in PR X」、「used by Y flow」、「added for the Z flow」）
- Public API（exported function / class / type）必寫 docstring：.NET XML doc / TS JSDoc，含用途、param、return、throws
- WHY 註解判準放寬到「兩年經驗工程師可能困惑」即寫（業務規則來源、踩過的坑、不變條件、為何選 A 不選 B）
- 修改既有 code 同步更新註解；註解 rot 視同 bug

## Code Review
- 優先序：breaking changes → security → performance regression → correctness
- Conventional comments：`suggestion:`、`nitpick:`、`issue:`、`question:`
- PR 描述需含：變更目的、影響範圍、測試方式
- Diff 自審：每行變更可對應原始需求；無法追溯的順手改 → 移除或另開 task

## Verification
- Evidence 形式：test / build / lint pass 紀錄；無法跑時明確記錄原因
- 任務轉成可驗證 goal：「修 bug」→「寫 reproduce test 並通過」、「加 validation」→「寫 invalid input test 並通過」、「refactor」→「修改前後 test 全綠」
- Goal 夠明確 → verify-loop 可獨立跑；模糊 → 回去補 goal
- 修改前確認 git status clean；不直接覆寫 production config

## Communication
- 口語化；speculation OK 但要標記
- 該問就問（ambiguity / 多種解讀 / 不確定影響面 → 停下、明確說出困惑點再問）；問時含推薦預設 + 答案如何影響結果；已決事項不畫蛇添足建議 alternatives

## 可選載入（按專案語境用 @import 顯式引入）
- .NET：`@~/.claude/rules/dotnet.md`
- TypeScript：`@~/.claude/rules/typescript.md`
- Frontend SPA：`@~/.claude/rules/frontend-spa.md`
- WinForms：`@~/.claude/rules/winforms.md`
- C/C++：`@~/.claude/rules/cpp.md`
- 測試任務：`@~/.claude/rules/testing.md`
- DevOps / 基礎設施：`@~/.claude/rules/infra.md`
