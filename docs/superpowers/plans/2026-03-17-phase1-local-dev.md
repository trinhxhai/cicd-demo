# Phase 1: Local Dev Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold an NX monorepo with 4 services (NestJS, Express, FastAPI, Next.js) forming an echo/ping mesh, fully runnable with `docker compose up`.

**Architecture:** Each service exposes `GET /ping`. NestJS calls Express calls Python, returning a nested JSON chain. Next.js displays the chain. All inter-service URLs are injected via environment variables — never hardcoded. Services are independently testable via unit tests with mocked downstream calls.

**Tech Stack:** NX 20, NestJS, Express, FastAPI (Python 3.12), Next.js 15, Docker Compose, Jest, pytest, supertest

---

## File Map

```
nx.json                              ← NX workspace config
package.json                         ← Root package.json (shared devDeps)
.prettierrc                          ← Prettier config
.gitignore                           ← Ignores .env, __pycache__, dist, .next
.env.example                         ← Committed template with placeholder URLs
.env                                 ← Gitignored local values
CLAUDE.md                            ← Project context for AI assistance
docker-compose.yml                   ← All 4 services wired together

apps/api-python/
  main.py                            ← FastAPI app, GET /ping endpoint
  requirements.txt                   ← fastapi, uvicorn, httpx, pytest, httpx
  project.json                       ← NX targets: serve, test, docker-build
  Dockerfile                         ← Single-stage python:3.12-slim

  tests/
    __init__.py
    test_ping.py                     ← pytest: GET /ping returns correct JSON

apps/api-express/
  src/
    app.ts                           ← Express app, GET /ping (calls Python)
    main.ts                          ← Starts server on PORT env var
    app.spec.ts                      ← Jest + supertest, mocks fetch
  project.json                       ← NX targets: build, serve, test, docker-build
  tsconfig.app.json                  ← TS config for app (extends root)
  Dockerfile                         ← Multi-stage node:22-alpine

apps/api-nest/
  src/
    app.module.ts                    ← Imports HttpModule
    app.controller.ts                ← GET /ping controller
    app.controller.spec.ts           ← Jest, mocks HttpService
    app.service.ts                   ← Calls EXPRESS_URL, builds nested response
    main.ts                          ← Starts on port 3000
  project.json                       ← NX targets: build, serve, test, docker-build
  Dockerfile                         ← Multi-stage node:22-alpine

apps/web/
  app/
    api/
      ping/
        route.ts                     ← Next.js API route, calls NEST_URL/ping
        route.test.ts                ← Jest, mocks fetch
    page.tsx                         ← Homepage, calls /api/ping and displays result
  project.json                       ← NX targets: build, serve, test, docker-build
  Dockerfile                         ← Multi-stage node:22-alpine (Next.js standalone)
```

---

## Task 1: NX Workspace Init + Project Conventions

**Files:**
- Create: `package.json`, `nx.json`, `.prettierrc`, `.gitignore`, `.env.example`, `CLAUDE.md`

- [ ] **Step 1: Initialize NX workspace in the existing repo directory**

```bash
cd /Users/user/Desktop/dev/nx-monorepo-boilerplate
npx create-nx-workspace@latest . --preset=empty --nxCloud=skip --pm=npm --no-interactive
```

Expected: NX scaffolds `nx.json`, `package.json`, `.gitignore`, `.prettierrc` in the current directory. If prompted to overwrite the existing README.md, confirm yes.

- [ ] **Step 2: Verify NX is working**

```bash
npx nx show projects
```

Expected: empty list (no apps yet) — that's correct.

- [ ] **Step 3: Install NX plugins for all services**

```bash
npm install --save-dev @nx/nest @nx/node @nx/next @nx/jest
```

- [ ] **Step 4: Update .gitignore**

Append these lines to `.gitignore`:

```
.env
__pycache__/
*.pyc
.pytest_cache/
```

- [ ] **Step 5: Create .env.example**

```bash
# .env.example — committed to git, safe placeholder values
EXPRESS_URL=http://api-express:3001
PYTHON_URL=http://api-python:8000
NEST_URL=http://api-nest:3000
```

- [ ] **Step 6: Create .env for local development**

```bash
# .env — gitignored, used by docker-compose
EXPRESS_URL=http://api-express:3001
PYTHON_URL=http://api-python:8000
NEST_URL=http://api-nest:3000
```

- [ ] **Step 7: Create CLAUDE.md**

```markdown
# NX Monorepo Boilerplate

NX monorepo with 4 services forming an echo/ping mesh.
Services: api-nest (3000), api-express (3001), api-python (8000), web (4000).
Echo chain: web → api-nest → api-express → api-python.
Inter-service URLs injected via env vars (EXPRESS_URL, PYTHON_URL, NEST_URL).
Local: docker compose up. Cloud: EKS (Phases 2-3).
Spec: docs/superpowers/specs/2026-03-17-nx-monorepo-aws-deployment-design.md
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore: initialize NX workspace with project conventions"
```

---

## Task 2: Python Service (api-python)

Build from the bottom of the chain first — Python has no downstream dependency.

**Files:**
- Create: `apps/api-python/main.py`
- Create: `apps/api-python/requirements.txt`
- Create: `apps/api-python/project.json`
- Create: `apps/api-python/tests/__init__.py`
- Create: `apps/api-python/tests/test_ping.py`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p apps/api-python/tests
```

- [ ] **Step 2: Write the failing test first**

Create `apps/api-python/tests/test_ping.py`:

```python
from fastapi.testclient import TestClient
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from main import app

client = TestClient(app)

def test_ping_returns_service_name_and_status():
    response = client.get("/ping")
    assert response.status_code == 200
    body = response.json()
    assert body["service"] == "python"
    assert body["status"] == "ok"

def test_ping_has_no_downstream_key():
    response = client.get("/ping")
    assert "downstream" not in response.json()
```

Create `apps/api-python/tests/__init__.py` (empty file).

- [ ] **Step 3: Run the test — verify it fails**

```bash
cd apps/api-python
pip install fastapi uvicorn httpx pytest httpx pytest-asyncio 2>/dev/null || true
python -m pytest tests/test_ping.py -v
```

Expected: `ModuleNotFoundError: No module named 'main'` — correct, we haven't written it yet.

- [ ] **Step 4: Create requirements.txt**

```
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
pytest==8.3.3
pytest-asyncio==0.24.0
```

- [ ] **Step 5: Write the minimal implementation**

Create `apps/api-python/main.py`:

```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/ping")
def ping():
    return {"service": "python", "status": "ok"}
```

- [ ] **Step 6: Run the test — verify it passes**

```bash
cd apps/api-python
pip install -r requirements.txt
python -m pytest tests/test_ping.py -v
```

Expected:
```
PASSED tests/test_ping.py::test_ping_returns_service_name_and_status
PASSED tests/test_ping.py::test_ping_has_no_downstream_key
```

- [ ] **Step 7: Create project.json for NX integration**

Create `apps/api-python/project.json`:

```json
{
  "name": "api-python",
  "$schema": "../../node_modules/nx/schemas/project-schema.json",
  "projectType": "application",
  "sourceRoot": "apps/api-python",
  "targets": {
    "serve": {
      "executor": "nx:run-commands",
      "options": {
        "command": "uvicorn main:app --reload --host 0.0.0.0 --port 8000",
        "cwd": "apps/api-python"
      }
    },
    "test": {
      "executor": "nx:run-commands",
      "options": {
        "command": "python -m pytest tests/ -v",
        "cwd": "apps/api-python"
      }
    },
    "docker-build": {
      "executor": "nx:run-commands",
      "options": {
        "command": "docker build -t api-python:latest apps/api-python"
      }
    }
  }
}
```

- [ ] **Step 8: Verify NX can run the test target**

```bash
cd /Users/user/Desktop/dev/nx-monorepo-boilerplate
npx nx test api-python
```

Expected: both tests pass.

- [ ] **Step 9: Commit**

```bash
git add apps/api-python/
git commit -m "feat: add api-python FastAPI service with /ping endpoint"
```

---

## Task 3: Express Service (api-express)

Calls Python downstream. Build second in the chain.

**Files:**
- Create: `apps/api-express/` (via NX generator, then modify)
- Modify: `apps/api-express/src/main.ts`
- Create: `apps/api-express/src/app.ts`
- Create: `apps/api-express/src/app.spec.ts`

- [ ] **Step 1: Generate the NX Node app**

```bash
npx nx generate @nx/node:application api-express --directory=apps/api-express --no-interactive
```

Expected: Creates `apps/api-express/` with `src/main.ts`, `project.json`, `tsconfig.app.json`, etc.

- [ ] **Step 2: Install Express and test dependencies**

```bash
npm install express
npm install --save-dev @types/express supertest @types/supertest
```

- [ ] **Step 3: Write the failing test**

Create `apps/api-express/src/app.spec.ts`:

```typescript
import request from 'supertest';
import app from './app';

const mockPythonResponse = {
  service: 'python',
  status: 'ok',
};

describe('GET /ping', () => {
  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => mockPythonResponse,
    } as Response);
  });

  afterEach(() => {
    jest.resetAllMocks();
  });

  it('returns express service info with python downstream', async () => {
    const res = await request(app).get('/ping');
    expect(res.status).toBe(200);
    expect(res.body.service).toBe('express');
    expect(res.body.status).toBe('ok');
    expect(res.body.downstream).toEqual(mockPythonResponse);
  });

  it('calls PYTHON_URL/ping once', async () => {
    process.env.PYTHON_URL = 'http://fake-python:8000';
    await request(app).get('/ping');
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch).toHaveBeenCalledWith('http://fake-python:8000/ping');
  });
});
```

- [ ] **Step 4: Run the test — verify it fails**

```bash
npx nx test api-express
```

Expected: `Cannot find module './app'` — correct.

- [ ] **Step 5: Write the Express app**

Create `apps/api-express/src/app.ts`:

```typescript
import express, { Request, Response } from 'express';

const app = express();
app.use(express.json());

app.get('/ping', async (_req: Request, res: Response) => {
  const pythonUrl = process.env.PYTHON_URL ?? 'http://localhost:8000';
  const downstream = await fetch(`${pythonUrl}/ping`).then((r) => r.json());
  res.json({ service: 'express', status: 'ok', downstream });
});

export default app;
```

- [ ] **Step 6: Update main.ts to start the server**

Replace the contents of `apps/api-express/src/main.ts`:

```typescript
import app from './app';

const port = process.env.PORT ?? 3001;
app.listen(port, () => {
  console.log(`api-express listening on port ${port}`);
});
```

- [ ] **Step 7: Run the tests — verify they pass**

```bash
npx nx test api-express
```

Expected:
```
PASS  apps/api-express/src/app.spec.ts
  GET /ping
    ✓ returns express service info with python downstream
    ✓ calls PYTHON_URL/ping once
```

- [ ] **Step 8: Add docker-build target to project.json**

Open `apps/api-express/project.json` and add to the `targets` object:

```json
"docker-build": {
  "executor": "nx:run-commands",
  "options": {
    "command": "docker build -t api-express:latest apps/api-express"
  }
}
```

- [ ] **Step 9: Commit**

```bash
git add apps/api-express/
git commit -m "feat: add api-express service with /ping calling Python downstream"
```

---

## Task 4: NestJS Service (api-nest)

Calls Express downstream. The main entry point for all clients.

**Files:**
- Create: `apps/api-nest/` (via NX generator, then modify)
- Modify: `apps/api-nest/src/app.module.ts`
- Modify: `apps/api-nest/src/app.controller.ts`
- Modify: `apps/api-nest/src/app.controller.spec.ts`
- Create: `apps/api-nest/src/app.service.ts`

- [ ] **Step 1: Generate the NestJS app**

```bash
npx nx generate @nx/nest:application api-nest --directory=apps/api-nest --no-interactive
```

Expected: Creates `apps/api-nest/src/` with `app.module.ts`, `app.controller.ts`, `app.controller.spec.ts`, `app.service.ts`, `main.ts`.

- [ ] **Step 2: Install NestJS HTTP module**

```bash
npm install @nestjs/axios axios
```

- [ ] **Step 3: Write the failing test**

Replace `apps/api-nest/src/app.controller.spec.ts`:

```typescript
import { Test, TestingModule } from '@nestjs/testing';
import { AppController } from './app.controller';
import { AppService } from './app.service';

describe('AppController', () => {
  let controller: AppController;
  let service: AppService;

  const mockExpressResponse = {
    service: 'express',
    status: 'ok',
    downstream: { service: 'python', status: 'ok' },
  };

  beforeEach(async () => {
    const app: TestingModule = await Test.createTestingModule({
      controllers: [AppController],
      providers: [
        {
          provide: AppService,
          useValue: { ping: jest.fn().mockResolvedValue(mockExpressResponse) },
        },
      ],
    }).compile();

    controller = app.get(AppController);
    service = app.get(AppService);
  });

  describe('GET /ping', () => {
    it('returns nest service info with express+python downstream', async () => {
      const result = await controller.ping();
      expect(result.service).toBe('nest');
      expect(result.status).toBe('ok');
      expect(result.downstream).toEqual(mockExpressResponse);
    });

    it('delegates to AppService.ping()', async () => {
      await controller.ping();
      expect(service.ping).toHaveBeenCalledTimes(1);
    });
  });
});
```

- [ ] **Step 4: Run the test — verify it fails**

```bash
npx nx test api-nest
```

Expected: failures about missing `ping()` method on controller and service.

- [ ] **Step 5: Implement AppService**

Replace `apps/api-nest/src/app.service.ts`:

```typescript
import { Injectable } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';

@Injectable()
export class AppService {
  constructor(private readonly http: HttpService) {}

  async ping(): Promise<unknown> {
    const expressUrl = process.env.EXPRESS_URL ?? 'http://localhost:3001';
    const { data } = await firstValueFrom(
      this.http.get(`${expressUrl}/ping`)
    );
    return data;
  }
}
```

- [ ] **Step 6: Implement AppController**

Replace `apps/api-nest/src/app.controller.ts`:

```typescript
import { Controller, Get } from '@nestjs/common';
import { AppService } from './app.service';

@Controller()
export class AppController {
  constructor(private readonly appService: AppService) {}

  @Get('ping')
  async ping() {
    const downstream = await this.appService.ping();
    return { service: 'nest', status: 'ok', downstream };
  }
}
```

- [ ] **Step 7: Update AppModule to import HttpModule**

Replace `apps/api-nest/src/app.module.ts`:

```typescript
import { Module } from '@nestjs/common';
import { HttpModule } from '@nestjs/axios';
import { AppController } from './app.controller';
import { AppService } from './app.service';

@Module({
  imports: [HttpModule],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
```

- [ ] **Step 8: Run the tests — verify they pass**

```bash
npx nx test api-nest
```

Expected:
```
PASS  apps/api-nest/src/app.controller.spec.ts
  AppController
    GET /ping
      ✓ returns nest service info with express+python downstream
      ✓ delegates to AppService.ping()
```

- [ ] **Step 9: Add docker-build target to project.json**

Open `apps/api-nest/project.json` and add:

```json
"docker-build": {
  "executor": "nx:run-commands",
  "options": {
    "command": "docker build -t api-nest:latest apps/api-nest"
  }
}
```

- [ ] **Step 10: Commit**

```bash
git add apps/api-nest/
git commit -m "feat: add api-nest service with /ping calling Express downstream"
```

---

## Task 5: Next.js Frontend (web)

Calls NestJS and displays the ping chain.

**Files:**
- Create: `apps/web/` (via NX generator, then modify)
- Create: `apps/web/app/api/ping/route.ts`
- Create: `apps/web/app/api/ping/route.test.ts`
- Modify: `apps/web/app/page.tsx`

- [ ] **Step 1: Generate the Next.js app**

```bash
npx nx generate @nx/next:application web --directory=apps/web --no-interactive
```

Expected: Creates `apps/web/` with Next.js app router structure.

- [ ] **Step 2: Create the API route directory**

```bash
mkdir -p apps/web/app/api/ping
```

- [ ] **Step 3: Write the failing test**

Create `apps/web/app/api/ping/route.test.ts`:

```typescript
// Mock Next.js Response before imports
const mockJson = jest.fn();
jest.mock('next/server', () => ({
  NextResponse: {
    json: (data: unknown) => {
      mockJson(data);
      return { body: data };
    },
  },
}));

describe('GET /api/ping', () => {
  const mockNestResponse = {
    service: 'nest',
    status: 'ok',
    downstream: {
      service: 'express',
      status: 'ok',
      downstream: { service: 'python', status: 'ok' },
    },
  };

  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => mockNestResponse,
    } as Response);
    process.env.NEST_URL = 'http://fake-nest:3000';
  });

  afterEach(() => jest.resetAllMocks());

  it('returns the full chain from NestJS', async () => {
    const { GET } = await import('./route');
    const response = await GET();
    expect(mockJson).toHaveBeenCalledWith(mockNestResponse);
  });

  it('calls NEST_URL/ping', async () => {
    const { GET } = await import('./route');
    await GET();
    expect(global.fetch).toHaveBeenCalledWith('http://fake-nest:3000/ping');
  });
});
```

- [ ] **Step 4: Run the test — verify it fails**

```bash
npx nx test web
```

Expected: `Cannot find module './route'` — correct.

- [ ] **Step 5: Write the API route**

Create `apps/web/app/api/ping/route.ts`:

```typescript
import { NextResponse } from 'next/server';

export async function GET() {
  const nestUrl = process.env.NEST_URL ?? 'http://localhost:3000';
  const data = await fetch(`${nestUrl}/ping`).then((r) => r.json());
  return NextResponse.json(data);
}
```

- [ ] **Step 6: Run the tests — verify they pass**

```bash
npx nx test web
```

Expected:
```
PASS  apps/web/app/api/ping/route.test.ts
  GET /api/ping
    ✓ returns the full chain from NestJS
    ✓ calls NEST_URL/ping
```

- [ ] **Step 7: Update the homepage to display the ping chain**

Replace `apps/web/app/page.tsx`:

```tsx
export default async function Home() {
  const baseUrl = process.env.NEXT_PUBLIC_BASE_URL ?? 'http://localhost:4000';
  let chain: Record<string, unknown> | null = null;
  let error: string | null = null;

  try {
    const res = await fetch(`${baseUrl}/api/ping`, { cache: 'no-store' });
    chain = await res.json();
  } catch (e) {
    error = 'Could not reach backend chain.';
  }

  return (
    <main style={{ fontFamily: 'monospace', padding: '2rem' }}>
      <h1>Echo / Ping Chain</h1>
      {error && <p style={{ color: 'red' }}>{error}</p>}
      {chain && <pre>{JSON.stringify(chain, null, 2)}</pre>}
    </main>
  );
}
```

- [ ] **Step 8: Add docker-build target to project.json**

Open `apps/web/project.json` and add:

```json
"docker-build": {
  "executor": "nx:run-commands",
  "options": {
    "command": "docker build -t web:latest apps/web"
  }
}
```

- [ ] **Step 9: Commit**

```bash
git add apps/web/
git commit -m "feat: add Next.js web app displaying ping chain from NestJS"
```

---

## Task 6: Dockerfiles

All 4 services need a Dockerfile. Node services use multi-stage builds; Python uses single-stage.

**Files:**
- Create: `apps/api-python/Dockerfile`
- Create: `apps/api-express/Dockerfile`
- Create: `apps/api-nest/Dockerfile`
- Create: `apps/web/Dockerfile`

- [ ] **Step 1: Dockerfile for api-python (single-stage)**

Create `apps/api-python/Dockerfile`:

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Dockerfile for api-express (multi-stage)**

Create `apps/api-express/Dockerfile`:

```dockerfile
# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

# Copy workspace root package files for dependency resolution
COPY package.json package-lock.json nx.json ./
RUN npm ci

# Copy NX workspace files needed for build
COPY tsconfig*.json ./
COPY apps/api-express apps/api-express

RUN npx nx build api-express --prod

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

COPY --from=builder /app/dist/apps/api-express .
RUN npm ci --omit=dev

EXPOSE 3001
CMD ["node", "main.js"]
```

- [ ] **Step 3: Dockerfile for api-nest (multi-stage)**

Create `apps/api-nest/Dockerfile`:

```dockerfile
# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/api-nest apps/api-nest

RUN npx nx build api-nest --prod

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

COPY --from=builder /app/dist/apps/api-nest .
RUN npm ci --omit=dev

EXPOSE 3000
CMD ["node", "main.js"]
```

- [ ] **Step 4: Dockerfile for web (Next.js standalone)**

Create `apps/web/Dockerfile`:

```dockerfile
# Stage 1: Build
FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json nx.json ./
RUN npm ci

COPY tsconfig*.json ./
COPY apps/web apps/web

# Enable Next.js standalone output
ENV NEXT_TELEMETRY_DISABLED=1
RUN npx nx build web --prod

# Stage 2: Run
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

COPY --from=builder /app/dist/apps/web/.next/standalone ./
COPY --from=builder /app/dist/apps/web/.next/static ./.next/static
COPY --from=builder /app/dist/apps/web/public ./public

EXPOSE 4000
ENV PORT=4000
CMD ["node", "server.js"]
```

- [ ] **Step 5: Add `output: 'standalone'` to Next.js config**

Open or create `apps/web/next.config.js`:

```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
};

module.exports = nextConfig;
```

- [ ] **Step 6: Verify Python image builds**

```bash
docker build -t api-python:latest apps/api-python
```

Expected: Build succeeds. `docker images | grep api-python` shows the image.

- [ ] **Step 7: Commit**

```bash
git add apps/api-python/Dockerfile apps/api-express/Dockerfile apps/api-nest/Dockerfile apps/web/Dockerfile apps/web/next.config.js
git commit -m "feat: add multi-stage Dockerfiles for all services"
```

---

## Task 7: docker-compose.yml + Environment

Wire all 4 services together with health checks and service discovery via env vars.

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Write docker-compose.yml**

Create `docker-compose.yml` at the repo root:

```yaml
services:
  api-python:
    build:
      context: .
      dockerfile: apps/api-python/Dockerfile
    ports:
      - "8000:8000"
    networks:
      - app-network
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  api-express:
    build:
      context: .
      dockerfile: apps/api-express/Dockerfile
    ports:
      - "3001:3001"
    environment:
      - PYTHON_URL=${PYTHON_URL:-http://api-python:8000}
      - PORT=3001
    networks:
      - app-network
    depends_on:
      api-python:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3001/ping', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s

  api-nest:
    build:
      context: .
      dockerfile: apps/api-nest/Dockerfile
    ports:
      - "3000:3000"
    environment:
      - EXPRESS_URL=${EXPRESS_URL:-http://api-express:3001}
    networks:
      - app-network
    depends_on:
      api-express:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000/ping', (r) => process.exit(r.statusCode === 200 ? 0 : 1))"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s

  web:
    build:
      context: .
      dockerfile: apps/web/Dockerfile
    ports:
      - "4000:4000"
    environment:
      - NEST_URL=${NEST_URL:-http://api-nest:3000}
      - NEXT_PUBLIC_BASE_URL=http://localhost:4000
    networks:
      - app-network
    depends_on:
      api-nest:
        condition: service_healthy

networks:
  app-network:
    driver: bridge
```

- [ ] **Step 2: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add docker-compose wiring all services with health checks"
```

---

## Task 8: Final Verification

Confirm the full echo/ping chain works end-to-end in Docker Compose.

- [ ] **Step 1: Run all unit tests**

```bash
npx nx run-many --target=test --all
```

Expected: all test suites pass.

- [ ] **Step 2: Build all Docker images**

```bash
docker compose build
```

Expected: all 4 images build without error.

- [ ] **Step 3: Start all services**

```bash
docker compose up -d
```

Expected: all 4 containers start and become healthy. Check with:

```bash
docker compose ps
```

All services should show `healthy` status (wait ~60s for health checks to pass).

- [ ] **Step 4: Test the echo chain**

```bash
curl -s http://localhost:3000/ping | jq .
```

Expected:
```json
{
  "service": "nest",
  "status": "ok",
  "downstream": {
    "service": "express",
    "status": "ok",
    "downstream": {
      "service": "python",
      "status": "ok"
    }
  }
}
```

- [ ] **Step 5: Verify the web frontend**

Open `http://localhost:4000` in a browser.

Expected: page displays the nested JSON chain.

- [ ] **Step 6: Tear down**

```bash
docker compose down
```

- [ ] **Step 7: Final commit**

```bash
git add .
git commit -m "chore: verify phase 1 complete — echo chain works in docker compose"
```

---

## Phase 1 Done ✓

**Success criterion met when:** `docker compose up` → `curl localhost:3000/ping` returns the full 3-level nested JSON chain.

**Next:** See `docs/superpowers/plans/2026-03-17-phase2-cicd-eks.md`
