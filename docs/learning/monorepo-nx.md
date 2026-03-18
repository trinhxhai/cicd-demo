# NX — Deep Dive

This document explains NX from scratch: why it exists, what it does, how it works internally, and exactly how it is used in this project. Read `docs/learning/system-overview.md` first if you haven't.

---

## 1. The Problem: Why Monorepos Exist

Imagine you have 4 services: `api-nest`, `api-express`, `api-python`, `web`. The natural first instinct is to put them in 4 separate git repos — one repo per service. This feels clean at first, but it creates real pain:

**Shared code is a nightmare.** If you have a shared type (e.g., `PingResponse`) that both `api-nest` and `web` use, you have two choices: copy-paste it into both repos (now you have two sources of truth that will drift), or publish it as an npm package (now every small change requires a publish cycle before any consumer can use it).

**Cross-service changes are slow.** A single logical change — like renaming a field in a shared interface — requires: open repo 1, make change, PR, merge. Open repo 2, update the import, PR, merge. Repeat for all consumers. These 4 repos need to be coordinated but have no mechanism to enforce it.

**CI is wasteful.** Each repo runs its full test suite on every push, regardless of what changed.

A **monorepo** solves this: one git repository holds all services. Shared code is a real local import — no publish cycle, no copy-paste, no drift. A single PR can change a shared type and all its consumers atomically. The git history is unified.

But monorepos introduce their own problem. Without tooling, running `npm test` in a monorepo runs tests for all 4 services every time — even if you only changed one line in `api-express`. As the repo grows, this becomes slow. You need a tool that understands the structure and only runs what needs to run.

That tool is NX.

---

## 2. What NX Is

NX is a **monorepo orchestrator**. Its job is to:

1. Know what changed (compared to a previous git commit)
2. Know what depends on what (the project dependency graph)
3. Run only what needs to run, in the right order, with caching

NX is **not** a framework and not a build tool in the traditional sense. It doesn't compile TypeScript — `tsc` does. It doesn't run tests — Jest does. It doesn't bundle code — webpack or esbuild does. NX sits on top of all of these and decides *when* to invoke them and *for which projects*.

Think of NX as a smart task runner that understands your repo's structure.

---

## 3. The Project Graph — NX's Core Concept

The most important thing to understand about NX is the **project graph**.

NX scans the entire workspace and builds a directed graph where:
- Every **project** (app or library) is a node
- Every **dependency** between projects is an edge

In this project, the graph looks like this:

```
web  ──────────────────────────────────────────────────┐
                                                        │
api-nest ──────────────────────────────────────────────►│
                                                        │
api-express ───────────────────────────────────────────►│  (no shared libs yet)
                                                        │
api-python ────────────────────────────────────────────►│
```

Right now there are no shared `libs/` in this workspace, so each app is an independent node. If a `libs/shared-types` library were added, and `api-nest` imported from it, the graph would become:

```
libs/shared-types
       │
       ▼
  api-nest ──► (consumers of api-nest's output)
  web     ──► (if web also imports from shared-types)
```

When you run `nx affected`, NX:
1. Diffs the current commit against the base (e.g., `origin/main~1`)
2. Finds which projects own the changed files
3. Walks the graph forward — any project that depends on a changed project is also affected
4. Returns the affected set

This is why changing `libs/shared-types` automatically marks `api-nest` and `web` as affected, even if their own source files didn't change.

You can visualize the graph at any time:
```
npx nx graph
```
This opens a browser with an interactive diagram of all projects and their dependencies.

---

## 4. Targets and Executors

### Targets

A **target** is a named task you can run on a project. Common targets: `build`, `test`, `serve`, `lint`, `typecheck`, `docker-build`.

You run a target like this:
```
npx nx run api-express:test      # run the "test" target on api-express
npx nx run api-nest:build        # run the "build" target on api-nest
```

Or the shorthand:
```
npx nx test api-express
npx nx build api-nest
```

### Executors

An **executor** is the implementation behind a target — the code that actually runs when you invoke a target. Executors come from NX plugins (e.g., `@nx/esbuild:esbuild`, `@nx/js:node`) or from NX's built-in executors:

- **`nx:run-commands`** — runs any shell command. The Swiss Army knife. Most custom targets use this.
- **`nx:noop`** — does nothing. Used as a grouping target that just depends on other targets.
- **`@nx/esbuild:esbuild`** — compiles TypeScript with esbuild.
- **`@nx/js:node`** — runs a Node.js process with live reload (for `serve`).
- **`@nx/js:prune-lockfile`** — strips unused deps from the lockfile for a minimal Docker image.

### Where targets are defined

There are two places targets can live in this project:

**Option A — `project.json` file** (used by `api-python`):
```json
// apps/api-python/project.json
{
  "name": "api-python",
  "projectType": "application",
  "targets": {
    "test": {
      "executor": "nx:run-commands",
      "options": { "command": "python -m pytest tests/ -v", "cwd": "apps/api-python" }
    },
    "docker-build": {
      "executor": "nx:run-commands",
      "options": { "command": "docker build -t api-python:latest apps/api-python" }
    }
  }
}
```

**Option B — `"nx"` key inside `package.json`** (used by `api-nest`, `api-express`, `web`):
```json
// apps/api-express/package.json
{
  "name": "@org/api-express",
  "nx": {
    "targets": {
      "build": { "executor": "@nx/esbuild:esbuild", ... },
      "test": { "executor": "nx:run-commands", ... },
      "docker-build": { "executor": "nx:run-commands", ... }
    }
  }
}
```

Both approaches are equivalent — NX reads both. The `"nx"` key in `package.json` is the newer pattern; `project.json` is the classic. `api-python` uses `project.json` because it has no `package.json` (it's a Python project).

### Plugin-inferred targets

Some targets aren't defined anywhere explicitly — NX **infers** them from the plugins configured in `nx.json`. For example:

- `@nx/next/plugin` scans for `next.config.*` files and auto-creates `build`, `dev`, `start`, `serve-static` targets for the `web` app — no manual definition needed.
- `@nx/webpack/plugin` auto-creates `build` and `serve` targets for any project with a `webpack.config.*`.
- `@nx/playwright/plugin` auto-creates an `e2e` target for any project with a `playwright.config.*`.

This is why you can run `nx dev web` without seeing a `dev` target in `web/package.json` — the Next.js plugin created it automatically.

---

## 5. Caching

NX caches the output of every target run. The mechanism:

1. Before running a target, NX computes a **hash** of all inputs:
   - Source files of the project (and its dependencies)
   - The target's configuration
   - Environment variables marked as inputs
   - The NX version itself

2. NX checks if it has a cached result for that hash.

3. If yes → **cache hit**: NX replays the output instantly without running anything. You'll see `[local cache]` in the terminal.

4. If no → **cache miss**: NX runs the target, stores the output (stdout, artifacts) keyed to the hash.

**What this means in practice:** If you run `nx test api-express` and nothing has changed since the last run, it completes in milliseconds. If you change one file in `api-express`, the hash changes, it's a miss, and the tests actually run.

**`namedInputs` in `nx.json`** controls what counts as an input:
```json
"namedInputs": {
  "default": ["{projectRoot}/**/*", "sharedGlobals"],
  "production": ["default"],
  "sharedGlobals": []
}
```
`default` includes all files in the project root. `sharedGlobals` is currently empty — if you added a global config file here, changing it would invalidate the cache for all projects.

**Cache location:** By default, the cache lives in `.nx/cache/` (gitignored). NX also supports a **remote cache** (Nx Cloud) where cache hits are shared across all machines — your CI gets a hit from what you ran locally, and vice versa. This project doesn't use Nx Cloud, so cache is local only.

**`cache: false`** on `docker-build` targets: Docker builds are explicitly marked `cache: false` in this project because the Dockerfile and build context aren't fully tracked as NX inputs — it's safer to always rebuild when explicitly requested.

---

## 6. Key Commands

These are the commands actually used in this project, with what they do:

### Run a target on all projects
```bash
npx nx run-many -t test
npx nx run-many -t lint test build typecheck   # multiple targets
npx nx run-many -t test --parallel=3           # run up to 3 in parallel
```
Used in CI (`.github/workflows/ci.yml`) to run lint, test, build, and typecheck across all projects on every PR.

### Run a target on affected projects only
```bash
npx nx affected --target=test
npx nx affected --target=test --base=origin/main~1 --head=HEAD
```
`--base` and `--head` define the git range to compare. Anything changed between those two commits is "affected". Used in the deploy workflow to run tests only on changed services before building Docker images.

### List affected projects (no run — just the names)
```bash
npx nx show projects --affected --base=origin/main~1 --head=HEAD
```
Returns a newline-separated list of affected project names. Used in the deploy workflow to decide which Docker images to build:
```bash
AFFECTED=$(npx nx show projects --affected --base=$BASE --head=HEAD)
if echo "$AFFECTED" | grep -q "api-express"; then
  # build and push api-express image
fi
```

### Run a target on a single project
```bash
npx nx test api-express
npx nx build api-nest
npx nx serve web
npx nx docker-build api-python
```

### Visualize the project graph
```bash
npx nx graph
```
Opens a browser with an interactive project graph. Useful for understanding how projects relate, and for verifying that `nx affected` will behave as expected.

### Generate a new app or library
```bash
npx nx generate @nx/nest:app api-new-service
npx nx generate @nx/node:app api-go
npx nx generate @nx/js:library shared-types
```
Generators scaffold the correct file structure, `project.json`/`package.json` with NX targets, `tsconfig`, and test config — all following NX conventions. You don't write boilerplate by hand.

---

## 7. NX in This Project — In Detail

This section walks through every NX-related file in the repo and explains exactly what it does and why.

### `nx.json` — workspace-wide configuration

```json
{
  "namedInputs": {
    "default": ["{projectRoot}/**/*", "sharedGlobals"],
    "production": ["default"],
    "sharedGlobals": []
  },
  "plugins": [...],
  "targetDefaults": {...},
  "generators": {...}
}
```

**`namedInputs`:** Defines reusable input sets for caching. `default` means "all files in the project directory". `sharedGlobals` is empty — nothing global invalidates cache across all projects (yet). `production` is an alias for `default` (could be narrowed to exclude test files in a larger repo).

**`plugins`:** Four plugins are registered:

| Plugin | What it auto-infers |
|---|---|
| `@nx/js/typescript` | `typecheck` and `build` targets from `tsconfig.lib.json` |
| `@nx/webpack/plugin` | `build`, `serve`, `preview` from `webpack.config.*` |
| `@nx/next/plugin` | `build`, `dev`, `start`, `serve-static` from `next.config.*` |
| `@nx/playwright/plugin` | `e2e` from `playwright.config.*` |

These plugins mean that `web` gets a `build` and `dev` target automatically (from the Next.js plugin reading `apps/web/next.config.ts`), without needing to manually define them in `package.json`.

**`targetDefaults`:** Currently sets `cache: true` and `dependsOn: ["^build"]` for `@nx/esbuild:esbuild` — meaning any esbuild target will cache its results and will first build all dependencies (`^` means "upstream projects"). This is what makes `api-express:build` safe to run even if it depends on other built artifacts.

**`generators`:** Sets defaults for `@nx/next` generators — style: CSS, no linter. These defaults apply when you run `nx generate @nx/next:app`.

---

### `apps/api-python/project.json` — standalone project config

```json
{
  "name": "api-python",
  "projectType": "application",
  "sourceRoot": "apps/api-python",
  "targets": {
    "serve": { "executor": "nx:run-commands", "options": { "command": "uvicorn main:app --reload ..." } },
    "test":  { "executor": "nx:run-commands", "options": { "command": "python -m pytest tests/ -v", "cwd": "apps/api-python" } },
    "docker-build": { "executor": "nx:run-commands", "options": { "command": "docker build -t api-python:latest apps/api-python" } }
  }
}
```

`api-python` uses a `project.json` file (not `package.json`) because it's a Python project — there's no `package.json`. NX recognises `project.json` as a project root marker. All three targets use `nx:run-commands` — NX just shells out to the underlying Python tooling (`uvicorn`, `pytest`, `docker`). NX doesn't need to understand Python; it just needs to know the command to run and which directory is the project root.

**`cwd: "apps/api-python"`** on the test target: pytest needs to be run from inside the project directory to find the correct `tests/` folder and Python path.

---

### `apps/api-nest/package.json` — targets via `"nx"` key

```json
{
  "name": "@org/api-nest",
  "nx": {
    "targets": {
      "build": {
        "executor": "nx:run-commands",
        "options": { "command": "webpack-cli build", "args": ["--node-env=production"], "cwd": "apps/api-nest" },
        "configurations": {
          "development": { "args": ["--node-env=development"] }
        }
      },
      "serve":        { "executor": "@nx/js:node", "dependsOn": ["build"], ... },
      "test":         { "executor": "nx:run-commands", "options": { "command": "npx jest --config apps/api-nest/jest.config.js" } },
      "docker-build": { "executor": "nx:run-commands", "cache": false, "options": { "command": "docker build -t api-nest:latest apps/api-nest" } },
      "prune":        { "executor": "nx:noop", "dependsOn": ["prune-lockfile", "copy-workspace-modules"] },
      "prune-lockfile":        { "executor": "@nx/js:prune-lockfile", "dependsOn": ["build"] },
      "copy-workspace-modules": { "executor": "@nx/js:copy-workspace-modules", "dependsOn": ["build"] }
    }
  }
}
```

Key points:

- **`build` uses webpack** (via `webpack-cli build`). The `configurations` block means you can run `nx build api-nest:development` or `nx build api-nest:production` — NX passes the right `--node-env` flag. Default configuration is `production`.
- **`serve` depends on `build`** (`"dependsOn": ["build"]`). NX ensures the project is built before the serve process starts. `@nx/js:node` then runs the built output and watches for rebuilds.
- **`prune` + `prune-lockfile` + `copy-workspace-modules`**: These targets prepare a minimal Docker-friendly output — stripping unused lockfile entries and copying only needed workspace modules into `dist/`. This makes the Docker image smaller by only including production dependencies.
- **`docker-build` has `cache: false`**: Docker builds are always re-run when explicitly triggered, never served from NX cache.

---

### `apps/api-express/package.json` — targets via `"nx"` key

```json
{
  "name": "@org/api-express",
  "nx": {
    "targets": {
      "build": {
        "executor": "@nx/esbuild:esbuild",
        "options": {
          "platform": "node",
          "outputPath": "apps/api-express/dist",
          "format": ["cjs"],
          "main": "apps/api-express/src/main.ts",
          "tsConfig": "apps/api-express/tsconfig.app.json"
        }
      },
      "serve":        { "executor": "@nx/js:node", "dependsOn": ["build"], ... },
      "test":         { "executor": "nx:run-commands", "options": { "command": "npx jest --config apps/api-express/jest.config.js" } },
      "docker-build": { "executor": "nx:run-commands", "cache": false, ... }
    }
  }
}
```

Key differences from `api-nest`:

- **`build` uses `@nx/esbuild:esbuild`** instead of webpack. esbuild is significantly faster than webpack for simple Node.js services. The output is CommonJS (`"format": ["cjs"]`), placed in `apps/api-express/dist/`.
- **`targetDefaults` in `nx.json` applies here**: because this target uses `@nx/esbuild:esbuild`, it automatically gets `cache: true` and `dependsOn: ["^build"]` from `nx.json`'s `targetDefaults` — without those needing to be written in this file.
- The `serve` target uses `@nx/js:node` which watches the output directory and restarts the process when esbuild rebuilds.

---

### `apps/web/package.json` — minimal targets + plugin inference

```json
{
  "name": "@org/web",
  "nx": {
    "targets": {
      "test":         { "executor": "nx:run-commands", "options": { "command": "npx jest --config apps/web/jest.config.js" } },
      "docker-build": { "executor": "nx:run-commands", "cache": false, "options": { "command": "docker build -t web:latest apps/web" } }
    }
  }
}
```

Notice `web` only defines `test` and `docker-build` manually. The `build`, `dev`, `start` targets are **not here** — they are inferred by the `@nx/next/plugin` in `nx.json`, which detects `apps/web/next.config.ts` and generates those targets automatically. This is why:

```bash
npx nx build web   # works — target comes from the Next.js plugin
npx nx dev web     # works — target comes from the Next.js plugin
```

---

### `tsconfig.base.json` — the shared TypeScript anchor

```json
{
  "compilerOptions": {
    "strict": true,
    "target": "es2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "composite": true,
    "declarationMap": true,
    "customConditions": ["@org/source"]
  }
}
```

Every TypeScript project in this workspace (`apps/api-nest/tsconfig.json`, `apps/api-express/tsconfig.json`, etc.) extends this file via `"extends": "../../tsconfig.base.json"`. This means:

- All TypeScript compiler settings are centralised. Change `strict` here and it applies everywhere.
- `composite: true` enables TypeScript project references — required for NX's TypeScript plugin to do incremental builds correctly.
- `"@org/source"` is a custom module condition. When `apps/*` reference each other or any `libs/*`, this condition tells TypeScript to resolve to the source files (`.ts`) rather than compiled output (`.js`/`.d.ts`) during development, for accurate type checking.

---

### How NX fits into CI and deploy

**CI workflow (`.github/workflows/ci.yml`):**
```yaml
- run: npx nx run-many -t lint test build typecheck
```
Runs all four targets on all projects in parallel. No `--affected` here — CI always checks everything on PRs to guarantee the full repo is healthy. NX's local cache means repeated runs (e.g., retrying a failed CI) are fast because unchanged projects are replayed from cache.

**Deploy workflow (`.github/workflows/deploy.yml`):**
```yaml
# Step 1 — test only affected services
- run: npx nx affected --base=$BASE --head=HEAD --target=test --parallel=3

# Step 2 — get affected list for Docker build decisions
- run: AFFECTED=$(npx nx show projects --affected --base=$BASE --head=HEAD)

# Step 3 — for each service, only build+push Docker image if it's in the affected list
- run: |
    for svc in api-python api-express api-nest web; do
      if echo "$AFFECTED" | grep -q "$svc"; then
        docker build ...
        docker push ...
      fi
    done
```

NX is the decision-maker for what gets deployed. Docker and kubectl handle the execution — but NX determines which services are in scope.

**Why `--base=origin/main~1 --head=HEAD` in deploy (not `origin/main`)?**

The deploy workflow runs on pushes to `main` — meaning the current HEAD *is* `main`. Comparing `HEAD` against `origin/main` would compare a commit to itself, finding nothing affected. `origin/main~1` is the previous commit on main, which is the correct base to diff against.

---

## Summary

| Concept | What it is |
|---|---|
| Project graph | NX's map of all projects and their dependencies |
| `nx affected` | Runs a target only on projects touched by recent changes |
| Target | A named task (`build`, `test`, `docker-build`, etc.) |
| Executor | The implementation that runs when a target is invoked |
| `project.json` / `"nx"` in `package.json` | Where targets are explicitly defined per project |
| Plugin-inferred targets | Targets NX creates automatically from framework config files |
| Caching | NX hashes inputs and replays cached output when nothing changed |
| `nx.json` | Workspace-wide NX config: plugins, input sets, target defaults |
| `tsconfig.base.json` | Shared TypeScript settings extended by all apps |
