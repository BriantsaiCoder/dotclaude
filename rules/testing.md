---
paths:
  - "**/*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs}"
  - "**/*Tests.cs"
  - "**/*Spec.cs"
  - "**/*.Tests/**"
  - "**/__tests__/**"
  - "**/tests/**"
  - "**/test/**"
  - "**/playwright.config.*"
  - "**/vitest.config.*"
  - "**/jest.config.*"
  - "**/e2e/**"
---

# Testing 行為錨

> Stack 工具選擇（xUnit / Vitest / GoogleTest / Playwright config 細則）+ Deployment Gate 細則 → 對應 `*-best-practices` / `*-release-verification` skill。

- E2E 工具分工：**Playwright MCP**（headed）跑 user journey；**Chrome DevTools MCP** 用於 HTML / CSS / Mermaid 視覺問題與 perf / network / Web Vitals 除錯，不替代 E2E
- E2E 義務：frontend UI / user-facing 變更後 **MUST** 跑 Playwright MCP（headed）；缺 GUI 環境（CI / 遠端 / Docker）明確回報 fallback headless，不靜默降級
- RWD viewport：mobile（375）+ desktop（1280）baseline；critical flow（auth / 結帳 / 表單 / 資料變更 / 路由）加 tablet（768）
- **MUST** 每 viewport 截圖 + console / page error log；缺一視同未驗證
- 瀏覽器清理：MCP `--isolated`（已配置 `~/.claude/playwright-mcp-config.json`）+ 顯式關 page / context；session 結束不應殘留 chromium
- Selector 優先序：getByRole / getByLabel / visible text / getByTestId；CSS selector avoid（third-party 元件無 a11y 等明確理由除外）
- Naming：`MethodName_Scenario_ExpectedResult`（.NET）、`describe/it` 自然語言（frontend）
- Integration tests 涵蓋 critical paths（auth / payment / 持久化 / 外部整合）
- Timing / concurrency bug 的 regression test 須針對 race 條件（重複執行 / stress），單次通過不算證據
- 設計面優先以 idempotency / transaction boundary 消除 race，不以 sleep / retry 掩蓋
