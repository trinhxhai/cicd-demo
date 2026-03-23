# Local Development Onboarding

Get the full stack running on your machine in minutes.

---

## What You're Running

Four services form an echo/ping mesh. A request from the browser chains through all of them:

```
web (4000) → api-nest (3000) → api-express (3001) → api-python (8000)
```

Each service calls the next downstream and returns a nested JSON response. Hit `/ping` on any service to verify the full chain is healthy.

| Service | Port | Stack |
|---|---|---|
| `web` | 4000 | Next.js |
| `api-nest` | 3000 | NestJS |
| `api-express` | 3001 | Express + TypeScript |
| `api-python` | 8000 | Python (FastAPI/Uvicorn) |

---

## Prerequisites

- **Docker** and **Docker Compose** — required for the recommended path
- **Node.js 20+** and **npm** — required if running services natively
- **Python 3.11+** — required only if running `api-python` natively

---

## Option 1 — Docker Compose (recommended)

Builds and starts all four services in the background:

```bash
docker compose -f docker-compose.dev.yml up --build -d
```

Services start in dependency order (api-python → api-express → api-nest → web).

**Verify it works:**

```bash
curl http://localhost:4000/api/ping
```

You should see a nested JSON response from all four services.

**Stop everything:**

```bash
docker compose -f docker-compose.dev.yml down
```

---

## Option 2 — NX (native, no Docker)

Install dependencies first:

```bash
npm install
```

Run all services in parallel:

```bash
npx nx run-many --target=serve --all
```

Or run a single service:

```bash
npx nx serve api-nest
npx nx serve api-express
npx nx serve web
```

For `api-python`, run it directly:

```bash
cd apps/api-python
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

**Set inter-service URLs** when running natively (the defaults work for local):

| Variable | Default | Used by |
|---|---|---|
| `PYTHON_URL` | `http://localhost:8000` | `api-express` |
| `EXPRESS_URL` | `http://localhost:3001` | `api-nest` |
| `NEST_URL` | `http://localhost:3000` | `web` |

---

## Verify the Echo Chain

Once all services are up, hit the ping endpoints top-to-bottom:

```bash
# Full chain from the web app
curl http://localhost:4000/api/ping

# From api-nest down
curl http://localhost:3000/ping

# From api-express down
curl http://localhost:3001/ping

# api-python only
curl http://localhost:8000/ping
```

A healthy full-chain response looks like:

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

---

## Running Tests

```bash
# All tests
npx nx run-many --target=test --all

# Single service
npx nx test api-nest
npx nx test api-express
npx nx test web

# Python
cd apps/api-python && pytest
```

---

## Project Structure

```
apps/
  api-nest/       NestJS service
  api-express/    Express + TypeScript service
  api-python/     Python service
  web/            Next.js frontend
docker-compose.yml
```

---

## Next Steps

- **System architecture and CI/CD:** `docs/learning/system-overview.md`
- **NX commands and affected builds:** `docs/learning/monorepo-nx.md`
- **Cloud deployment (EKS):** `docs/learning/eks-kubernetes.md`
- **Full setup from scratch:** `docs/learning/set-up-from-zero.md`
