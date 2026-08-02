---
paths:
  - "**/*.{vue,jsx,tsx}"
  - "**/vite.config.*"
  - "**/package.json"
  - "**/.nvmrc"
  - "**/nuxt.config.*"
  - "**/next.config.*"
---

# Frontend SPA 規則

## 新專案預設
- Node 24（LTS → 2028-04）；無 `.nvmrc` 時採此版
- Vite + React / Vue 3 + TS（Composition API + `<script setup>`）
- Tailwind；React → shadcn/ui，Vue SPA → Naive UI，Nuxt → Nuxt UI v3
- 複雜表格 / 圖表 → PrimeVue；Icon → Iconify（unplugin-icons）
- 禁用：Vuetify、Element Plus、Bootstrap、CSS-in-JS
- State 共用 > 3 處才引入 Zustand / Pinia（不預設 Redux）
- TanStack Query + Axios（統一 interceptor）
- React Hook Form / VeeValidate + Zod
- React Router v7 / Vue Router；pino
- SSR / SEO 才升 Next.js（App Router）/ Nuxt 3

## Web API Auth
- JWT 放 httpOnly cookie 為優先；public endpoint 須明確標註
- token 不放 `localStorage` / `sessionStorage`（全域 Hard Rules 已常駐此紅線）

## 效能稽核（瀏覽器工具分工）

本機效能／記憶體／a11y 診斷一律走 chrome-devtools MCP（`claude:chrome-devtools-mcp`-only），不用 playwright 硬幹：

| 症狀 | 入口 |
|------|------|
| LCP／CLS／INP 退化 | `chrome-devtools-mcp:debug-optimize-lcp` |
| 記憶體洩漏、heap 成長 | `chrome-devtools-mcp:memory-leak-debugging` |
| a11y 稽核 | `chrome-devtools-mcp:a11y-debugging` |
| 不明的載入／渲染問題 | `chrome-devtools-mcp:troubleshooting` |

- 分工：**MCP 負責診斷、CI 負責把關**。CI gate 仍是 `@lhci/cli`（LCP ≤ 2.5s、CLS ≤ 0.1、INP ≤ 200ms，見 `frontend-release-verification`）；本機 profiling 不取代 CI。
- 功能測試／E2E／表單流程走 playwright；視覺回歸與 rendered-page 修復走 `web-design-reviewer`。不要用 chrome-devtools 做這兩類事。
- 提效能結論必附 trace 或 Lighthouse 實測數據，禁憑讀 code 推斷（[T0-2]）。
