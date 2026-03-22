# Dev / UAT / Prod Environment & Branch Strategy Design

**Date:** 2026-03-22
**Status:** Approved

---

## Goals

- Separate dev (local), UAT (EKS), and prod (EKS) environments with clear promotion gates
- Define a professional git branch strategy that maps 1:1 to environments
- Keep infrastructure isolated between UAT and prod (separate EKS clusters)
- Share ECR images across environments — build once on UAT deploy, promote the same image SHA to prod
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
3. **Promote to UAT**: open PR `main → uat`, merge triggers auto-deploy to UAT EKS (images are built here)
4. **Promote to prod**: open PR `uat → prod`, merge triggers prod pipeline which pauses for manual approval click in GitHub Actions before deploying (no rebuild — same image SHA from UAT is reused)

### Branch protection rules

| Branch | Rules |
|--------|-------|
| `main` | Require PR + CI passing; no direct push |
| `uat`  | Require PR; source must be `main` (no feature branches skip to UAT) |
| `prod` | Require PR; source must be `uat` (UAT cannot be bypassed) |

> **Important — GitHub Actions bypass:** The deploy workflows commit updated `kustomization.yaml` image tags back to the branch. With branch protection enabled, this push will be rejected unless the `github-actions[bot]` service account is added as a **bypass actor** in the branch protection settings for `uat` and `prod`. Both deploy workflow files must also include `contents: write` in their permissions block. See: repo Settings → Branches → Edit rule → Bypass list.

### Hotfix workflow

For urgent prod fixes that cannot wait for the full promotion cycle:

1. Branch from `prod`: `git checkout -b hotfix/critical-fix`
2. PR to `prod` (with approval) — deploys immediately to prod
3. **Back-merge via cherry-pick** to keep branches in sync — do NOT open a PR `prod → uat` (this would violate the branch protection rule requiring `uat` source to be `main`):
   - Cherry-pick the hotfix commit(s) onto `main`
   - Open PR `main → uat` to sync UAT
   - UAT auto-deploys — confirms the fix is stable
   - The next regular `uat → prod` PR will include the cherry-pick

---

## Section 2 — Infrastructure (Terraform)

Current `infra/terraform/` is renamed to `infra/terraform/prod/`. A new `infra/terraform/uat/` directory is created for the UAT cluster.

### Directory structure

```
infra/
└── terraform/
    ├── uat/
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── vpc.tf
    │   ├── eks.tf
    │   ├── iam.tf             ← OIDC + deploy role for UAT
    │   ├── outputs.tf
    │   ├── terraform.tfvars.example
    │   └── terraform.tfvars          ← gitignored, real values
    └── prod/                         ← current infra/terraform/ renamed
        └── (existing files unchanged)
```

> **ECR is NOT duplicated in UAT Terraform.** ECR repositories are managed exclusively by `prod/ecr.tf`. The `uat/` directory does not contain an `ecr.tf` — both environments push/pull from the same ECR repos. If UAT needs to reference ECR repo URLs, use Terraform data sources (`data "aws_ecr_repository"`), not resource blocks.

### Terraform state isolation

Each directory uses a **separate S3 backend key** to prevent state files from overwriting each other:

- `prod`: `terraform/prod/terraform.tfstate`
- `uat`:  `terraform/uat/terraform.tfstate`

Both can share the same S3 bucket and DynamoDB lock table, but the keys must differ. This must be configured in each directory's `backend.tf` (or added to `versions.tf`).

### Key differences between UAT and prod tfvars

| Variable | UAT | Prod |
|----------|-----|------|
| `cluster_name` | `nx-monorepo-uat` | `nx-monorepo-prod` |
| EC2 instance type | `t3.medium` | `t3.large` (or current) |
| Node count | min 1 / max 2 | min 2 / max 4 (or current) |

### ECR strategy — build once, promote

Docker images are built exactly once: during the UAT deploy. The prod deploy reads the image tag that was written to `k8s/overlays/uat/kustomization.yaml` by the UAT pipeline and writes those same tags into `k8s/overlays/prod/kustomization.yaml` — no Docker build step in `deploy-prod.yml`. This guarantees prod runs the identical binary that passed UAT validation.

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

The UAT overlay points to `../../base` and has its image tags patched by the UAT deploy pipeline. UAT may use lighter resource requests (lower CPU/memory limits) to reduce cost on smaller nodes.

---

## Section 4 — CI/CD Pipelines

The current `ci-cd.yml` is **deleted** and replaced by three focused workflow files:

```
.github/workflows/
├── ci.yml              ← lint, test, build, typecheck — runs on PRs and push to main ONLY
├── deploy-uat.yml      ← triggered on push to `uat` branch; builds images, auto-deploys to UAT EKS
└── deploy-prod.yml     ← triggered on push to `prod` branch; promotes UAT image tags, manual approval, deploys to prod EKS
```

### ci.yml

- Triggers: `push` to `main` only; `pull_request` to any branch
- The `push` trigger is explicitly limited to `main` — pushes to `uat` and `prod` are handled exclusively by their respective deploy workflows (adding those branches here would cause duplicate CI runs)
- Steps: checkout, setup Node + Python, `npm ci`, `pip install`, `nx run-many -t lint test build typecheck`
- No AWS credentials, no Docker, no deploy

### deploy-uat.yml

- Triggers: `push` to `uat` branch
- Permissions: `id-token: write`, `contents: write`, `actions: read`
- Steps:
  1. Configure AWS credentials using `UAT_AWS_ROLE_ARN`
  2. Log in to ECR
  3. Resolve affected base SHA (last successful UAT deploy run)
  4. Build + push affected Docker images (tagged with commit SHA) to shared ECR
  5. Trivy vulnerability scan
  6. Patch `k8s/overlays/uat/kustomization.yaml` with new image tags and commit back to `uat` branch
  7. `kubectl apply -k k8s/overlays/uat`
  8. `kubectl rollout status` for all deployments

### deploy-prod.yml

- Triggers: `push` to `prod` branch
- Permissions: `id-token: write`, `contents: write`, `actions: read`
- Adds `environment: production` block — GitHub pauses execution until a configured reviewer approves in the Actions UI
- **No Docker build step** — reads image tags from `k8s/overlays/uat/kustomization.yaml` and writes them directly into `k8s/overlays/prod/kustomization.yaml`. This file is committed to the `uat` branch by the UAT pipeline and is carried to `prod` via the merge PR, so a standard checkout of `prod` is sufficient — no cross-branch checkout needed.
- Steps:
  1. Configure AWS credentials using `PROD_AWS_ROLE_ARN`
  2. Read image tags from `k8s/overlays/uat/kustomization.yaml`
  3. Patch `k8s/overlays/prod/kustomization.yaml` with those same tags and commit back to `prod` branch
  4. `kubectl apply -k k8s/overlays/prod`
  5. `kubectl rollout status` for all deployments

### GitHub secrets — migration from current setup

**Delete these old secrets** (used by the old `ci-cd.yml`, no longer referenced):
- `AWS_ROLE_ARN`
- `ECR_REGISTRY`
- `EKS_CLUSTER_NAME`

**Create these new secrets:**

| Secret | Workflow |
|--------|----------|
| `AWS_REGION` | both deploy workflows (shared; may already exist) |
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
2. Create `infra/terraform/uat/` with all files except `ecr.tf`; add separate S3 backend key for UAT state; set UAT-specific tfvars
3. Create `k8s/overlays/uat/kustomization.yaml`
4. Delete `ci-cd.yml`; create `ci.yml`, `deploy-uat.yml`, `deploy-prod.yml`
5. Create `uat` and `prod` long-lived branches in the GitHub repository
6. Configure branch protection rules (including `github-actions[bot]` as bypass actor on `uat` and `prod`)
7. Create GitHub environments (`uat` and `production`) with appropriate protection rules
8. Migrate GitHub secrets (delete old 3, create new 7)

---

## Non-Goals

- No dev EKS cluster — local Docker Compose is sufficient for day-to-day development
- No Terragrunt — separate directories are explicit and sufficient at this team size
- No staging environment beyond UAT
- No blue/green or canary deployments (out of scope for this boilerplate phase)
