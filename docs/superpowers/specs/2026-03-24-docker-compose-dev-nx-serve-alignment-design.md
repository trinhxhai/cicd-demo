# Docker Compose Dev — Nx Serve Alignment Design

**Date:** 2026-03-24
**Status:** Approved

## Problem

The current `docker-compose.dev.yml` runs Node.js services using `node --watch -r @swc-node/register`, bypassing Nx entirely. This caused a decorator parsing failure in the NestJS container because `@swc-node/register` resolves `.swcrc` from the process CWD (`/app`), not the file's directory — so `apps/api-nest/.swcrc` was never found.

The community standard for Nx monorepos in Docker is to run `npx nx serve <app>` inside containers, delegating transpilation to the same Nx executors used locally.

## Goal

Align `docker-compose.dev.yml` with community patterns: full-root bind mount, named `node_modules` volume, and `nx serve` as the dev command for all Node.js services.

## Out of Scope

- Production Dockerfiles (`apps/*/Dockerfile`) — unchanged
- `api-python` service — unchanged
- `apps/web` Next.js service — already uses `npx next dev`, unchanged
- Local Kubernetes setup — handled separately via Tilt/Skaffold using production Dockerfiles

## Design

### Dockerfile.dev

No changes required. The existing file installs root `node_modules` via `npm ci`, which includes `nx`. The named volume at runtime shadows `/app/node_modules` with a Linux-native install.

### docker-compose.dev.yml — Node.js services

Three changes applied to `api-nest` and `api-express`:

**1. Volumes**

```yaml
# Before
volumes:
  - ./apps:/app/apps
  - ./tsconfig.base.json:/app/tsconfig.base.json

# After
volumes:
  - ./:/app
  - node_modules:/app/node_modules
```

Full monorepo root is bind-mounted so `nx` can resolve workspace config, `tsconfig.base.json`, and all project files. The named `node_modules` volume shadows the bind mount at `/app/node_modules`, ensuring Linux-compiled native binaries are used inside the container (not macOS-compiled ones from the host).

**2. Command**

```yaml
# Before (api-nest)
command: node --watch -r @swc-node/register apps/api-nest/src/main.ts

# After (api-nest)
command: npx nx serve api-nest
```

```yaml
# Before (api-express)
command: node --watch -r @swc-node/register apps/api-express/src/main.ts

# After (api-express)
command: npx nx serve api-express
```

`nx serve` uses the executor defined in each app's `package.json`:
- `api-nest`: `@nx/js:node` → webpack with `tsc` compiler (handles NestJS decorators natively)
- `api-express`: `@nx/js:node` → esbuild (fast, no config needed)

Both executors watch for file changes and rebuild automatically.

**3. Environment**

```yaml
environment:
  - NX_DAEMON=false   # added
  - ...existing vars
```

`NX_DAEMON=false` disables the Nx background daemon, which crashes in Docker containers due to socket/IPC limitations. Without it, `nx serve` may fail or hang on first run.

### Named volumes section

```yaml
volumes:
  node_modules:    # added — shared Linux-native node_modules for Node.js services
  pip-cache:       # existing
```

### Cleanup

- **Delete `apps/api-nest/.swcrc`** — only needed for `@swc-node/register`. Webpack/tsc reads `tsconfig.app.json` directly; `.swcrc` is not consulted.
- **Delete root `.swcrc`** — added as a temporary workaround for the CWD discovery bug. No longer needed.
- **Keep `apps/web/.swcrc`** — used by Next.js build pipeline, unaffected.

## Trade-offs

| Concern | Impact |
|---|---|
| First `docker compose up` is slower | `node_modules` named volume must be populated on first run — same time as before since `npm ci` runs in the image build |
| `nx serve` adds Nx graph resolution overhead | ~1-2s on startup vs raw node; negligible for dev workflow |
| Full-root bind mount on macOS | Slightly larger inotify surface; mitigated by Docker Desktop's VirtioFS |
| No more `.swcrc` for dev | Decorator support comes from `tsconfig.app.json` → webpack tsc, which is the correct path for NestJS |

## Files Changed

| File | Action |
|---|---|
| `docker-compose.dev.yml` | Update `api-nest` and `api-express` services |
| `apps/api-nest/.swcrc` | Delete |
| `.swcrc` (root) | Delete |
| `Dockerfile.dev` | No change |
| `apps/web/.swcrc` | No change |
