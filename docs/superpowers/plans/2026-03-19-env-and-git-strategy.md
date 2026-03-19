# Environment Management & Git Branch Strategy

**Date:** 2026-03-19
**Status:** Brainstorm / Plan
**Scope:** Dev + Prod environment separation, branch strategy, secrets, CI/CD routing

---

## 1. Current State

| What exists today | Gap |
|---|---|
| One Kustomize overlay: `k8s/overlays/prod/` | No `dev` overlay |
| CI deploys to prod on every push to `main` | No staging/dev deployment target |
| `.env.example` with K8s DNS URLs | No per-environment env var management |
| GitHub Actions OIDC auth | Single IAM role, no env-scoped permissions |
| Trivy scan gates on CRITICAL only | Same threshold for dev and prod |

---

## 2. Recommended Git Branch Strategy: Trunk-Based with Long-Lived `develop`

### Branch Model

```
main          ─── protected, always deployable, maps to PROD
  │
develop       ─── integration branch, maps to DEV/staging
  │
feature/*     ─── short-lived, open PRs against develop
hotfix/*      ─── branch from main, PR to main + back-merge to develop
```

### Rules

| Branch | Who merges | Protection rules | Triggers CI/CD |
|---|---|---|---|
| `main` | Squash merge from `develop` only | Required review + status checks | Deploy → **prod** EKS namespace |
| `develop` | Squash merge from `feature/*` | Required status checks | Deploy → **dev** EKS namespace |
| `feature/*` | Author | None | Run lint/test/build only |
| `hotfix/*` | Author | Required review | Deploy → prod on merge to main |

### Why trunk-based over GitFlow?

- NX `nx affected` already does incremental builds — no need for long release branches
- Short-lived feature branches (1–3 days) keep diffs small and conflicts minimal
- A single `develop` integration branch gives a stable dev environment to test against
- Avoids GitFlow's `release/` branch overhead — promote directly `develop → main`

---

## 3. Environment Separation

### 3.1 Kubernetes Namespaces

Create two namespaces instead of deploying everything to `default`:

```
k8s/
  overlays/
    dev/          ← new
    prod/         ← already exists
```

| Attribute | dev | prod |
|---|---|---|
| K8s namespace | `dev` | `prod` |
| Replicas | 1 | 2 (HPA-managed) |
| CPU request/limit | 50m / 200m | 100m / 500m |
| Memory request/limit | 64Mi / 128Mi | 128Mi / 256Mi |
| Image tag strategy | `:dev-<sha7>` | `:prod-<sha7>` |
| Ingress hostname | `dev.internal` or node port | `app.yourdomain.com` |

### 3.2 `k8s/overlays/dev/kustomization.yaml` (new file)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev

resources:
  - ../../base

# Patch replicas down for dev
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
    target:
      kind: Deployment

# Image tags injected by CI (dev-<sha7>)
images:
  - name: api-nest
    newName: <ECR_REGISTRY>/api-nest
    newTag: dev-latest
  - name: api-express
    newName: <ECR_REGISTRY>/api-express
    newTag: dev-latest
  - name: api-python
    newName: <ECR_REGISTRY>/api-python
    newTag: dev-latest
  - name: web
    newName: <ECR_REGISTRY>/web
    newTag: dev-latest
```

### 3.3 Service Discovery URLs per Environment

**Local (docker-compose):**
Uses container hostnames — already working via `.env.example`.

**Dev (EKS `dev` namespace):**
```
EXPRESS_URL=http://api-express.dev.svc.cluster.local:3001
PYTHON_URL=http://api-python.dev.svc.cluster.local:8000
NEST_URL=http://api-nest.dev.svc.cluster.local:3000
```

**Prod (EKS `prod` namespace):**
```
EXPRESS_URL=http://api-express.prod.svc.cluster.local:3001
PYTHON_URL=http://api-python.prod.svc.cluster.local:8000
NEST_URL=http://api-nest.prod.svc.cluster.local:3000
```

These are injected via Kustomize `configMapGenerator` or deployment env patches — not stored in application code.

---

## 4. Secrets & Environment Variables Management

### 4.1 What Belongs Where

| Category | Tool | Rationale |
|---|---|---|
| Service discovery URLs | Kustomize overlay patches | K8s-native, no secrets needed |
| AWS credentials for CI | GitHub OIDC → IAM role | Already implemented |
| App secrets (API keys, DB passwords) | AWS Secrets Manager + K8s External Secrets Operator | Avoids secrets in git |
| Non-secret config (feature flags, log levels) | ConfigMap per namespace | Easy to diff and audit |
| Local dev overrides | `.env.local` (gitignored) | Developer freedom |

### 4.2 Secrets Hierarchy

```
AWS Secrets Manager
  /dev/api-nest/...
  /prod/api-nest/...

External Secrets Operator (in-cluster)
  ExternalSecret → pulls from ASM → creates K8s Secret
  Deployment → mounts K8s Secret as env vars
```

This keeps secrets out of git entirely while keeping K8s manifests auditable.

### 4.3 `.env` File Strategy

```
.env.example          ← committed, safe placeholder values (already exists)
.env.local            ← gitignored, developer local overrides
.env.test             ← committed, values safe for CI test runs
```

Never commit `.env`, `.env.dev`, or `.env.prod` — use Secrets Manager for those values.

---

## 5. CI/CD Pipeline Changes

### 5.1 Workflow Routing by Branch

```yaml
# .github/workflows/ci-cd.yml additions

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  ci:
    # Always run: lint, test, build (nx affected)

  deploy-dev:
    if: github.ref == 'refs/heads/develop'
    needs: ci
    # kubectl apply k8s/overlays/dev
    # image tag: dev-<sha7>
    # namespace: dev

  deploy-prod:
    if: github.ref == 'refs/heads/main'
    needs: ci
    # kubectl apply k8s/overlays/prod
    # image tag: prod-<sha7>
    # namespace: prod
    # Require manual approval via GitHub Environment protection rule
```

### 5.2 Image Tagging Convention

| Environment | Tag format | Example |
|---|---|---|
| dev | `dev-<sha7>` | `dev-a1b2c3d` |
| prod | `prod-<sha7>` | `prod-a1b2c3d` |

Both tags pushed to the same ECR repository per service. This allows tracing any running image back to its exact commit.

### 5.3 GitHub Environment Protection (for prod)

In GitHub repo settings → Environments:
- Create `production` environment
- Add required reviewers (1+ approvals before deploy)
- Restrict to `main` branch only
- Set environment secrets (AWS role ARN for prod)

For `development` environment: no approval gate, deploys automatically on merge to `develop`.

### 5.4 Separate IAM Roles per Environment

```
GitHubActions-Dev-Role   → ECR push, EKS access to `dev` namespace only
GitHubActions-Prod-Role  → ECR push, EKS access to `prod` namespace only
```

Scope K8s RBAC with a `ClusterRole`/`RoleBinding` per namespace so the CI role for dev cannot touch prod resources.

---

## 6. Developer Workflow

### Day-to-day

```bash
# 1. Start from develop
git checkout develop && git pull origin develop

# 2. Create feature branch
git checkout -b feature/my-feature

# 3. Develop & commit
git add . && git commit -m "feat: add X"

# 4. Push and open PR → develop
git push -u origin feature/my-feature
# CI runs: lint + test + build (nx affected)

# 5. PR merged to develop
# CI auto-deploys to dev EKS namespace
# QA / smoke test on dev environment

# 6. When develop is stable, open PR: develop → main
# Requires approval (GitHub Environment protection)
# On merge: CI deploys to prod
```

### Hotfix Workflow

```bash
# 1. Branch from main
git checkout main && git pull
git checkout -b hotfix/critical-bug

# 2. Fix, commit, push
git push -u origin hotfix/critical-bug

# 3. PR → main (fast review, small diff)
# On merge: deploy to prod

# 4. Back-merge to develop immediately
git checkout develop
git merge --no-ff main
git push
```

---

## 7. Implementation Checklist

### Phase A — Branch Setup (Day 1)
- [ ] Protect `main` branch: require PR, 1 approver, status checks
- [ ] Create `develop` branch from `main`
- [ ] Protect `develop` branch: require status checks
- [ ] Update `on.push.branches` in `ci-cd.yml` to include `develop`

### Phase B — Kubernetes Dev Overlay (Day 1–2)
- [ ] Create `k8s/overlays/dev/kustomization.yaml`
- [ ] Create `dev` namespace in EKS (`kubectl create namespace dev`)
- [ ] Add namespace-scoped RBAC for CI dev role
- [ ] Test: `kubectl apply -k k8s/overlays/dev` locally

### Phase C — CI/CD Routing (Day 2–3)
- [ ] Add `deploy-dev` job gated on `github.ref == 'refs/heads/develop'`
- [ ] Add `deploy-prod` job gated on `github.ref == 'refs/heads/main'`
- [ ] Create `production` GitHub Environment with approval gate
- [ ] Create `development` GitHub Environment (no gate)
- [ ] Separate IAM roles for dev/prod in `infra/terraform/iam.tf`
- [ ] Store role ARNs as GitHub Environment secrets (not repo secrets)

### Phase D — Secrets Management (Day 3–5)
- [ ] Create AWS Secrets Manager paths `/dev/*` and `/prod/*`
- [ ] Install External Secrets Operator via Helm in EKS
- [ ] Define `ExternalSecret` CRDs per service per namespace
- [ ] Remove any plaintext secrets from ConfigMaps

### Phase E — Dev Environment Validation (Day 5)
- [ ] Merge a test feature branch to `develop`
- [ ] Verify dev deploy triggers correctly
- [ ] Verify prod deploy does NOT trigger
- [ ] Verify images tagged correctly in ECR
- [ ] Run smoke test: `curl http://dev.internal/api/nest/ping`

---

## 8. Trade-offs & Alternatives Considered

| Decision | Chosen | Alternative | Why not |
|---|---|---|---|
| Branch model | Trunk + `develop` | Full GitFlow | GitFlow release branches add overhead without benefit at this scale |
| Environment namespaces | K8s namespaces | Separate EKS clusters | Separate clusters cost ~$73/mo each; namespaces are free and sufficient |
| Secrets | AWS Secrets Manager + ESO | Sealed Secrets | ASM integrates with existing AWS setup; ESO is well-maintained |
| Image tagging | `env-<sha7>` prefix | Separate ECR repos per env | Single repo simpler; tag prefix gives clear traceability |
| Prod gate | GitHub Environment approval | Manual workflow trigger | Environment protection is auditable and integrates with GitHub UI |
| IAM scoping | Separate roles per env | Single role | Least-privilege: dev CI cannot accidentally modify prod |

---

## 9. Future Considerations

- **Preview environments:** Deploy feature branches to ephemeral namespaces (`feature-<branch>`) with auto-cleanup on PR close
- **ArgoCD / Flux:** Replace `kubectl apply` in CI with GitOps operator for drift detection and self-healing
- **Semantic versioning:** Add release tags (`v1.2.3`) alongside `prod-<sha>` for change management
- **Environment parity:** Use same Kustomize base to keep dev/prod as close as possible — avoid environment-specific code paths
- **Canary releases:** Route 10% of prod traffic to new image before full rollout (requires Ingress weight annotations or Flagger)
