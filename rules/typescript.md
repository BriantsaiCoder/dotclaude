---
paths:
  - "**/*.{ts,tsx}"
  - "**/tsconfig*.json"
---

# TypeScript 規則

- **MUST** `tsconfig.json` 啟 `strict` + `noUncheckedIndexedAccess` + `verbatimModuleSyntax`
- **NEVER** barrel exports（`index.ts` 重新匯出）
- A11y：`eslint-plugin-jsx-a11y`（React）/ `eslint-plugin-vuejs-accessibility`（Vue）必啟
