---
paths:
  - "**/Dockerfile*"
  - "**/docker-compose*.yml"
  - "**/docker-compose*.yaml"
  - "**/.dockerignore"
  - "**/k8s/**"
  - "**/*.k8s.yaml"
---

# Infra 規則

- Docker + `docker-compose.yml`
- npm workspaces（`apps/` + `services/` + `packages/`）
- Self-hosted（Windows Server / Linux VM）
- Production secrets：env var（orchestrator 注入）
- Docker-dependent 專案啟動前：`docker compose up -d`
