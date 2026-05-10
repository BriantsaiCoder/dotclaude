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
- Vite + React / Vue 3 + TS（Composition API + `<script setup>`）
- Tailwind；React → shadcn/ui，Vue → Naive UI
- State 共用 > 3 處才引入 Zustand / Pinia（不預設 Redux）
- TanStack Query + Axios（統一 interceptor）
- React Hook Form / VeeValidate + Zod
- React Router v7 / Vue Router；pino
- SSR / SEO 才升 Next.js（App Router）/ Nuxt 3

## Web API Auth
- JWT 放 httpOnly cookie 為優先；public endpoint 須明確標註
- **NEVER** 把 token / 敏感資料放 frontend `localStorage` / `sessionStorage`（同 Hard Rules）
