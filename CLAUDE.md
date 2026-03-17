# NX Monorepo Boilerplate

NX monorepo with 4 services forming an echo/ping mesh.
Services: api-nest (3000), api-express (3001), api-python (8000), web (4000).
Echo chain: web → api-nest → api-express → api-python.
Inter-service URLs injected via env vars (EXPRESS_URL, PYTHON_URL, NEST_URL).
Local: docker compose up. Cloud: EKS (Phases 2-3).
Spec: docs/superpowers/specs/2026-03-17-nx-monorepo-aws-deployment-design.md
