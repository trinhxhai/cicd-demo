# NX Monorepo AWS Deployment Design

**Date:** 2026-03-17
**Status:** Approved

---

## Goals

- Learn how AWS deployment works end-to-end (CI/CD, autoscaling)
- Produce a reusable boilerplate template for future projects
- Understand how each piece works by building it step by step

---

## Section 1 — Overall Architecture

### Stack

| Layer | Technology |
|---|---|
| Monorepo | NX |
| Main backend | NestJS (port 3000) |
| Scalable service | Express (port 3001) |
| Python service | FastAPI (port 8000) |
| Frontend | Next.js (port 4000) |
| Local orchestration | Docker Compose |
| Cloud orchestration | EKS (Kubernetes on EC2) |
| CI/CD | GitHub Actions only |
| Container registry | Amazon ECR |
| Ingress | Nginx Ingress Controller |

### Monorepo Structure

```
nx-monorepo-boilerplate/
├── apps/
│   ├── api-nest/         ← NestJS main backend (port 3000)
│   ├── api-express/      ← Express scalable service (port 3001)
│   ├── api-python/       ← Python FastAPI service (port 8000)
│   └── web/              ← Next.js frontend (port 4000)
├── libs/                 ← Shared types / utils
├── docker-compose.yml    ← Local dev orchestration
├── .env.example          ← Service URLs and config (committed)
├── .env                  ← Local values (gitignored)
├── k8s/                  ← Kubernetes manifests
│   ├── base/             ← Deployments, Services, Ingress
│   └── overlays/         ← dev / prod (Kustomize)
├── .github/workflows/    ← GitHub Actions CI/CD
└── infra/                ← eksctl cluster config + scripts
    ├── cluster.yaml      ← eksctl cluster definition
    ├── setup.sh          ← One-time AWS setup (ECR repos, OIDC, IAM)
    └── teardown.sh       ← Full teardown including ALB + ECR cleanup
```

### Echo/Ping Mesh (App Logic)

Each service exposes `GET /ping`. The call chain is linear — each service calls the next, aggregates the response, and returns the full chain back up:

```
Request:   Next.js → NestJS → Express → Python
Response:  Next.js ← NestJS ← Express ← Python
```

- `web` calls `GET {NEST_URL}/ping`
- `api-nest` calls `GET {EXPRESS_URL}/ping`, wraps the response, returns to web
- `api-express` calls `GET {PYTHON_URL}/ping`, wraps the response, returns to nest
- `api-python` returns `{ "service": "python", "status": "ok" }`

Final response seen by the browser:
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

### Service Discovery (inter-service URLs)

URLs are injected via environment variables — never hardcoded:

| Env var | Local (docker-compose) | EKS (k8s) |
|---|---|---|
| `EXPRESS_URL` | `http://api-express:3001` | `http://api-express.default.svc.cluster.local:3001` |
| `PYTHON_URL` | `http://api-python:8000` | `http://api-python.default.svc.cluster.local:8000` |
| `NEST_URL` | `http://api-nest:3000` | `http://api-nest.default.svc.cluster.local:3000` |

### 3-Phase Roadmap

| Phase | Goal | Done When |
|---|---|---|
| 1 | Local Dev | `docker compose up` → `curl localhost:3000/ping` returns full nested chain |
| 2 | CI/CD + EKS | Push to `main` → GitHub Actions deploys to EKS → public URL returns chain |
| 3 | Autoscaling | k6 load test → HPA scales Express pods → Cluster Autoscaler adds EC2 nodes |

---

## Section 2 — CI/CD Pipeline + AWS Services

### GitHub Actions Flow

```
push to main
    │
    ▼
1. nx affected --base=origin/main --head=HEAD --target=test
2. nx affected --base=origin/main --head=HEAD --target=docker-build
3. docker push → ECR  (one repo per changed service, tagged with $GITHUB_SHA)
4. kustomize edit set image <service>=<ecr-url>:$GITHUB_SHA  (inject new image tag into overlay)
5. kubectl apply -k k8s/overlays/prod  (rolling deploy to EKS)
```

> **Note:** `nx affected` requires `--base` and `--head` flags in CI to compare against the correct commit range. The workflow sets `NX_BASE=origin/main` and `NX_HEAD=$GITHUB_SHA`. On the very first push to a new repo, `nx affected` will treat all projects as changed — this is expected and safe.

### AWS Services

| Service | Role |
|---|---|
| ECR | Container image registry — one repo per service |
| EKS | Managed Kubernetes control plane |
| EC2 | Worker nodes (Node Group, t3.medium) |
| NLB | Network Load Balancer fronting Nginx Ingress (auto-provisioned) |
| IAM | OIDC role for GitHub Actions, node instance profiles |

> **Ingress strategy:** Nginx Ingress Controller is installed inside the cluster. Its Service of type `LoadBalancer` causes AWS to provision an NLB automatically. Nginx handles all routing rules inside the cluster. This is simpler and more portable than the AWS Load Balancer Controller.

### Key Design Decisions

- **GitHub Actions only** — no AWS CodePipeline. GitHub Actions handles the full pipeline (test → build → push → deploy).
- **OIDC auth** — GitHub Actions authenticates to AWS via OIDC federation. No long-lived access keys in GitHub secrets.
- **`nx affected`** — only changed services are rebuilt and redeployed.
- **Kustomize overlays** — `k8s/base/` has shared manifests. `k8s/overlays/dev` and `k8s/overlays/prod` patch replicas, resource limits, and image tags.
- **Nginx Ingress** — routes traffic: `/` → web, `/api/nest/*` → NestJS, `/api/express/*` → Express, `/api/python/*` → Python.

### Phase 2 Prerequisites (one-time AWS setup)

Before Phase 2 work begins, `infra/setup.sh` handles:

1. AWS account with CLI configured (`aws configure`)
2. `eksctl` installed
3. `kubectl` installed
4. Create ECR repositories (one per service)
5. Create EKS cluster via `eksctl create cluster -f infra/cluster.yaml`
   > eksctl automatically updates your kubeconfig. Verify with `kubectl get nodes` before proceeding.
6. Install Nginx Ingress Controller on the cluster
7. Configure GitHub OIDC trust policy + IAM role for GitHub Actions
8. Add AWS credentials (role ARN, region, ECR URL) to GitHub repository secrets

### K8s Manifest Structure

```
k8s/base/
├── api-nest/
│   ├── deployment.yaml   ← image, env vars, resources, readiness probe
│   └── service.yaml      ← ClusterIP
├── api-express/
│   ├── deployment.yaml
│   └── service.yaml
├── api-python/
│   ├── deployment.yaml
│   └── service.yaml
├── web/
│   ├── deployment.yaml
│   └── service.yaml
└── ingress.yaml          ← Nginx routing rules for all services

k8s/overlays/
├── dev/
│   └── kustomization.yaml  ← patch: 1 replica, lower resource limits
└── prod/
    └── kustomization.yaml  ← patch: image tags, resource limits
```

---

## Section 3 — Autoscaling (Phase 3)

### Two Levels Working Together

**Level 1 — Pod Scaling (HPA on `api-express` only)**
- Metrics Server feeds CPU data to HPA
- HPA watches `api-express` deployment
- CPU > 70% → add pods (up to 10)
- CPU back to normal → scale pods down (min 1)

**Level 2 — Node Scaling (Cluster Autoscaler)**
- Watches for pods stuck in `Pending` (no room on existing nodes)
- Triggers EC2 Auto Scaling Group to add a new node
- When load drops → drains and terminates underused nodes

```
k6 load test → api-express CPU spikes
    │
    ▼
HPA: 1 pod → 3 pods → 5 pods (no room on 2 nodes)
    │
    ▼
Cluster Autoscaler: 2 EC2 nodes → 4 EC2 nodes
    │ (load drops)
    ▼
Scale back: pods → 1, nodes → 2
```

### Components Added in Phase 3

| Component | Purpose |
|---|---|
| Metrics Server | Feeds CPU/memory data to HPA |
| HPA (`api-express` only) | `minReplicas: 1, maxReplicas: 10, targetCPU: 70%` |
| Cluster Autoscaler | Watches ASG, adds/removes EC2 nodes |
| PodDisruptionBudget | Ensures at least 1 Express pod stays up during scale-down |
| k6 | Load testing tool to trigger and observe autoscaling |

---

## Section 4 — Dockerfiles + Local Dev

### Dockerfile Strategy

All Node services use multi-stage builds (smaller images, no build tools in production).
Python uses a single-stage build — multi-stage adds no meaningful size benefit for pure Python.

| Service | Build stage | Run stage |
|---|---|---|
| api-nest | `node:22-alpine` — `nx build api-nest` | `node:22-alpine` — copy `dist/` only |
| api-express | `node:22-alpine` — `nx build api-express` | `node:22-alpine` — copy `dist/` only |
| api-python | — | `python:3.12-slim` — `pip install` + copy source |
| web | `node:22-alpine` — `nx build web` (Next.js standalone) | `node:22-alpine` — copy `.next/standalone/` |

### docker-compose.yml

- All 4 services on a shared `app-network`
- Host volume mounts for live reload in dev
- Environment variables via `.env` (service discovery URLs, ports)
- Health checks: each service waits for its upstream dependency before starting

### NX Integration

- `nx run-many --target=docker-build` — builds all images
- `nx affected --target=docker-build` — only rebuilds changed services
- Each `apps/*/project.json` includes a `docker-build` target

### Phase 1 — Ordered Setup Steps

1. Install prerequisites: Node 22, Docker, NX CLI (`npm i -g nx`), Python 3.12
2. `npx create-nx-workspace@latest` — scaffold the NX workspace
3. Generate each app (`nx generate @nx/nest:app api-nest`, etc.)
4. Add minimal `/ping` endpoint to each service (no DB, no auth)
5. Wire inter-service calls via `EXPRESS_URL` / `PYTHON_URL` env vars
6. Write `Dockerfile` per service
7. Write `docker-compose.yml` wiring all services
8. Copy `.env.example` to `.env`, fill in local URLs
9. Add `docker-build` target to each `project.json`
10. **Done when:** `docker compose up` → `curl localhost:3000/ping` returns full nested chain

### Project Conventions (pre-Phase-1)

Before writing any service code, establish:
- ESLint + Prettier config (NX provides defaults)
- Conventional commits (`feat:`, `fix:`, `chore:`)
- `.gitignore` including `.env`, `node_modules/`, `.next/`, `__pycache__/`
- `CLAUDE.md` with project context for AI-assisted development

---

## Cost + Safety

### Running Costs

| Resource | Monthly cost |
|---|---|
| EKS control plane | ~$73 |
| 2x t3.medium nodes (base) | ~$60 |
| NLB | ~$18 |
| ECR storage | ~$1 |
| **Total (active)** | **~$150/month** |

Phase 3 Cluster Autoscaler may add nodes temporarily (billed by hour).

### What Survives `eksctl delete cluster`

These resources persist and continue billing after the cluster is deleted — `infra/teardown.sh` handles all of them:

- ECR repositories + stored images
- NLB (if not deleted before cluster teardown)
- IAM roles created for the cluster
- Any Route53 hosted zones (if added)

**Always run `infra/teardown.sh` not just `eksctl delete cluster`.**

---

## Decisions Summary

| Decision | Choice | Reason |
|---|---|---|
| Orchestration | EKS (raw manifests) | Learn real K8s, no abstraction layer |
| CI/CD | GitHub Actions only | Simpler than adding CodePipeline, same result |
| Auth to AWS | OIDC (no static keys) | Security best practice |
| Ingress | Nginx Ingress Controller | Portable, simpler than AWS LB Controller |
| Multi-env config | Kustomize overlays | Standard, no extra tooling |
| Scalable service | `api-express` only | Focused learning target |
| App logic | Echo/ping mesh | Minimal logic, inter-service comms visible |
| Helm | Not in scope | Keep Phase 2 simple, can add later |
| Service discovery | Environment variables | Same pattern works locally and in K8s |
