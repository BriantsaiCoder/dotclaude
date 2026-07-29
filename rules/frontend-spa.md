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
