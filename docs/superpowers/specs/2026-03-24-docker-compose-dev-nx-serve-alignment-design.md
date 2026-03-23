# Docker Compose Dev — Nx Serve Alignment Design

**Date:** 2026-03-24
**Status:** Approved

## Problem

The original `docker-compose.dev.yml` ran Node.js services using `node --watch -r @swc-node/register`, bypassing Nx. This caused a decorator parsing failure in the NestJS container because `@swc-node/register` resolves `.swcrc` from the process CWD (`/app`), not the file's directory — so `apps/api-nest/.swcrc` was never found.

The commands and `NX_DAEMON=false` have already been updated to use `npm exec nx serve`. The remaining work is aligning the **volume strategy** with community patterns and cleaning up now-redundant `.swcrc` files.

## Current State (as of this spec)

| Concern | Current | Target |
|---|---|---|
| Command (`api-nest`) | `npm exec nx serve api-nest` ✓ | no change |
| Command (`api-express`) | `npm exec nx serve @org/api-express` ✓ | no change |
| `NX_DAEMON=false` | present ✓ | no change |
| Volumes | partial mount `./apps` + `tsconfig.base.json` | full-root + named `node_modules` |
| `apps/api-nest/.swcrc` | present | delete |
| root `.swcrc` | present | delete |

## Goal

1. Update volumes for `api-nest` and `api-express` to mount the full monorepo root and isolate `node_modules` with a named volume.
2. Delete the two `.swcrc` files that are no longer needed.

## Out of Scope

- Production Dockerfiles (`apps/*/Dockerfile`) — unchanged
- `api-python` service — unchanged
- `web` (Next.js) service — already uses `npx next dev`, unchanged
- `depends_on` health checks — `depends_on` only waits for container start, not port readiness. With `nx serve`, backends take 10–20 s to compile before accepting connections, so early requests from dependent services may fail on first boot. This is acceptable for a dev environment where services are reached via browser manually. Health checks are deferred.
- Local Kubernetes — handled separately via Tilt/Skaffold using production Dockerfiles

## Design

### 1. Volumes — `api-nest` and `api-express`

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

**Full-root bind mount (`./:/app`):** mounts the entire monorepo so `nx` can resolve workspace config, `tsconfig.base.json`, `nx.json`, and all project files. The files in the image layer (copied during `docker build`) are overridden by the bind mount at runtime — the image-layer copies exist solely to seed the named `node_modules` volume during build.

**Named `node_modules` volume:** shadows `/app/node_modules` with a Linux-native install, preventing macOS-compiled native binaries from the host from leaking into the container. On first `docker compose up`, Docker populates this volume from the image layer (where `npm ci` ran). Subsequent starts reuse the populated volume.

### 2. Named volumes section

```yaml
volumes:
  node_modules:    # Linux-native node_modules for Node.js services
  pip-cache:       # existing
```

### 3. Cleanup

- **Delete `apps/api-nest/.swcrc`** — only needed for `@swc-node/register`. The `api-nest` webpack config uses `NxAppWebpackPlugin` with `compiler: 'tsc'`, which reads `tsconfig.app.json` for decorator flags (`experimentalDecorators`, `emitDecoratorMetadata`). `.swcrc` is not consulted on this path.
- **Delete root `.swcrc`** — added as a workaround for the CWD-based `.swcrc` discovery bug. No longer needed.
- **Keep `apps/web/.swcrc`** — Next.js uses SWC as its compiler and reads this file via its own pipeline.

### Command style

All `nx` invocations use `npm exec nx` (already established in the file). `npx nx` is equivalent but `npm exec nx` is consistent with the existing style and avoids `npx`'s download fallback behavior.

## Trade-offs

| Concern | Impact |
|---|---|
| First `docker compose up` is slower | `node_modules` named volume must be populated on first run — same time as before |
| Full-root bind mount on macOS | Slightly larger inotify surface; mitigated by Docker Desktop's VirtioFS |
| No `depends_on` health checks | Dependent services may see connection errors on cold start; resolved by waiting a few seconds |
| Decorator support | Comes from `tsconfig.app.json` → webpack tsc, which is the correct path for NestJS |

## Files Changed

| File | Action |
|---|---|
| `docker-compose.dev.yml` | Update volumes for `api-nest` and `api-express`; add `node_modules` to top-level `volumes` |
| `apps/api-nest/.swcrc` | Delete |
| `.swcrc` (root) | Delete |
| `Dockerfile.dev` | No change |
| `apps/web/.swcrc` | No change |
