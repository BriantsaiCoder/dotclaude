# Global Preferences

<!-- Claude owns this routing/governance file and ~/.claude/core|rules|hooks. Shared workflow methods live only in ~/.agents/skills. -->
@~/.claude/core/tier0-safety.md

## Defaults

- 預設 zh-TW；technical terms 保留 English。
- Package manager：npm（CI 用 `npm ci`）。
- Runtime follow `global.json`／`.nvmrc`；無則取最新 LTS。
- 文件查詢優先 MCP；Microsoft／Azure／.NET 用 microsoft-learn。

## Thin workflow

任何開發任務先讀 `~/.agents/skills/dev-workflow/SKILL.md`；host-local prose 不複製 method。

- 需求／domain：`grilling` + `domain-modeling`。
- Spec／tickets／長期決策：`to-spec`、`to-tickets`、`wayfinder`。
- Implementation／TDD：`implement` + `tdd`；先建 isolated worktree，禁止 current/main commit。
- Diagnosis／review／architecture：`diagnosing-bugs`、`code-review`、`codebase-design`。
- 陌生 repo／小需求：`acquire-codebase-knowledge`、`sdd`。

### Authorization

- 命中 [T0-8] 必須先出 plan 並取得明確核准；模糊且會改檔時依 [T0-5] 停下發問。
- Auth／payment／migration／deployment／destructive change 必須含 rollback。
- Fix 必須先有 failing regression test；無正確 seam 時明標例外與後續 architecture work。
- 未經 user／repo／higher instruction 授權，不使用 subagent；回報必由 main context 重驗。

### S4 VERIFY

Build／test／lint 與 task-specific probes 全跑；中高風險附 before／after evidence。無 evidence 不得宣稱完成。

### S5 REVIEW

用 `code-review` 分開跑 Standards／Spec；各軸標 PASS／FAIL／SKIPPED／UNAVAILABLE，actionable findings 歸零才可前進。

### S6 CLOSEOUT

S4、S5 全綠後才可 commit／push／open PR／merge／final closeout；merge 前 CI 綠且處理 bot review。預設 squash merge，合併後清理已合併 branch。

## Claude adapter

- plan = EnterPlanMode；todo = TodoWrite；子代理 = Task／Agent。
- `code-review` 固定 fan-out 仍受上方 authorization 管理；前端視覺 review 可用 Claude-local `uiux-reviewer`。
- Auto mode 可在已核准的 feature branch 完成單一邏輯單元後 commit；main／master、revert、混雜 diff 仍需確認。
- Secrets 只用 env／secret manager；log／chat 只回報 set／unset。

## On-demand stack rules

- .NET：`@~/.claude/rules/dotnet.md`
- TypeScript：`@~/.claude/rules/typescript.md`
- Frontend SPA：`@~/.claude/rules/frontend-spa.md`
- WinForms：`@~/.claude/rules/winforms.md`
- C/C++：`@~/.claude/rules/cpp.md`
- Testing／infra：`@~/.claude/rules/testing.md`、`@~/.claude/rules/infra.md`
- Cross-session handoff：`@~/.claude/templates/compact.md`
