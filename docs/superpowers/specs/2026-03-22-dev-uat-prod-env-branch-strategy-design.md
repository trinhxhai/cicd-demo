# Dev / UAT / Prod Environment & Branch Strategy Design

**Date:** 2026-03-22
**Status:** Approved

---

## Goals

- Separate dev (local), UAT (EKS), and prod (EKS) environments with clear promotion gates
- Define a professional git branch strategy that maps 1:1 to environments
- Keep infrastructure isolated between UAT and prod (separate EKS clusters)
- Share ECR images across environments — build once, promote the same artifact
- Provide a manual approval gate before any prod deployment

---

## Section 1 — Branch Strategy

### Long-lived branches

Three long-lived branches, each mapped to exactly one environment:

```
feature/xyz  ──PR──▶  main  ──PR──▶  uat  ──PR──▶  prod
                       │              │              │
                    (local dev)    (UAT EKS)    (Prod EKS)
```

| Branch | Environment | Deployment trigger |
|--------|-------------|-------------------|
| `main` | Local / dev (Docker Compose) | None — devs run locally |
| `uat`  | UAT EKS cluster | Auto on merge to `uat` |
| `prod` | Prod EKS cluster | Auto on merge to `prod` + manual approval gate |

### Developer workflow

1. Branch from `main`: `git checkout -b feature/my-feature`
2. Open PR to `main` — CI runs lint / test / build / typecheck, peer review required, then merge
3. **Promote to UAT**: open PR `main → uat`, merge triggers auto-deploy to UAT EKS
4. **Promote to prod**: open PR `uat → prod`, merge triggers prod pipeline which pauses for manual approval click in GitHub Actions before deploying

### Branch protection rules

| Branch | Rules |
|--------|-------|
| `main` | Require PR + CI passing; no direct push |
| `uat`  | Require PR; source must be `main` (no feature branches skip to UAT) |
| `prod` | Require PR; source must be `uat` (UAT cannot be bypassed) |

### Hotfix workflow

For urgent prod fixes that cannot wait for the full promotion cycle:

1. Branch from `prod`: `git checkout -b hotfix/critical-fix`
2. PR to `prod` (with approval) — deploys immediately
3. Back-merge `prod → uat → main` to keep branches in sync

---

## Section 2 — Infrastructure (Terraform)

Current `infra/terraform/` is renamed to `infra/terraform/prod/`. A new `infra/terraform/uat/` directory mirrors it with UAT-specific values.

### Directory structure

```
infra/
└── terraform/
    ├── uat/
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── vpc.tf
    │   ├── eks.tf
    │   ├── ecr.tf
    │   ├── iam.tf
    │   ├── outputs.tf
    │   ├── terraform.tfvars.example
    │   └── terraform.tfvars          ← gitignored, real values
    └── prod/                         ← current infra/terraform/ renamed
        └── (existing files unchanged)
```

### Key differences between UAT and prod tfvars

| Variable | UAT | Prod |
|----------|-----|------|
| `cluster_name` | `nx-monorepo-uat` | `nx-monorepo-prod` |
| EC2 instance type | `t3.medium` | `t3.large` (or current) |
| Node count | min 1 / max 2 | min 2 / max 4 (or current) |

### ECR strategy

UAT and prod share the same ECR repositories. The same Docker image built from a commit SHA is deployed to UAT first, then promoted to prod without rebuilding. This guarantees prod runs the exact same artifact that passed UAT.

---

## Section 3 — Kubernetes Overlays

```
k8s/
├── base/               ← unchanged
└── overlays/
    ├── uat/            ← new
    │   └── kustomization.yaml
    └── prod/           ← existing, unchanged
        └── kustomization.yaml
```

The UAT overlay is structurally identical to the prod overlay. It points to `../../base` and has its image tags patched by the UAT deploy pipeline. UAT may use lighter resource requests (lower CPU/memory limits) to reduce cost on smaller nodes.

---

## Section 4 — CI/CD Pipelines

The current `ci-cd.yml` is split into three focused workflow files:

```
.github/workflows/
├── ci.yml              ← lint, test, build, typecheck — runs on all PRs and push to main
├── deploy-uat.yml      ← triggered on push to `uat` branch; auto-deploys to UAT EKS
└── deploy-prod.yml     ← triggered on push to `prod` branch; manual approval gate then prod EKS
```

### ci.yml

- Triggers: `push` to `main`, `pull_request` to any branch
- Steps: checkout, setup Node + Python, `npm ci`, `pip install`, `nx run-many -t lint test build typecheck`
- No AWS credentials, no Docker, no deploy

### deploy-uat.yml

- Triggers: `push` to `uat` branch
- Steps (same logic as current deploy job):
  1. Configure AWS credentials using `UAT_AWS_ROLE_ARN`
  2. Log in to ECR
  3. Resolve affected base SHA (last successful UAT deploy)
  4. Build + push affected Docker images (tagged with commit SHA)
  5. Trivy vulnerability scan
  6. Patch `k8s/overlays/uat/kustomization.yaml` with new image tags
  7. `kubectl apply -k k8s/overlays/uat`
  8. `kubectl rollout status` for all deployments

### deploy-prod.yml

- Triggers: `push` to `prod` branch
- Adds `environment: production` block — GitHub pauses execution until a configured reviewer approves in the Actions UI
- Steps identical to deploy-uat.yml but uses prod secrets and `k8s/overlays/prod`

### GitHub secrets

| Secret | Workflow |
|--------|----------|
| `AWS_REGION` | both deploy workflows (shared) |
| `UAT_AWS_ROLE_ARN` | deploy-uat.yml |
| `UAT_ECR_REGISTRY` | deploy-uat.yml |
| `UAT_EKS_CLUSTER_NAME` | deploy-uat.yml |
| `PROD_AWS_ROLE_ARN` | deploy-prod.yml |
| `PROD_ECR_REGISTRY` | deploy-prod.yml |
| `PROD_EKS_CLUSTER_NAME` | deploy-prod.yml |

### GitHub environments

Two GitHub environments must be created in repo Settings → Environments:

| Environment | Protection rules |
|-------------|-----------------|
| `uat` | None (auto-deploys) |
| `production` | Required reviewers: at least 1 approver before prod job proceeds |

---

## Section 5 — Phase Scope

This design is implemented as a new phase in the project roadmap. It covers:

1. Rename `infra/terraform/` → `infra/terraform/prod/`
2. Create `infra/terraform/uat/` (copy of prod with UAT tfvars)
3. Create `k8s/overlays/uat/kustomization.yaml`
4. Split `ci-cd.yml` into `ci.yml`, `deploy-uat.yml`, `deploy-prod.yml`
5. Create `uat` and `prod` branches in the GitHub repository
6. Document branch protection rule setup and GitHub environment configuration

---

## Non-Goals

- No dev EKS cluster — local Docker Compose is sufficient for day-to-day development
- No Terragrunt — separate directories are explicit and sufficient at this team size
- No staging environment beyond UAT
- No blue/green or canary deployments (out of scope for this boilerplate phase)
