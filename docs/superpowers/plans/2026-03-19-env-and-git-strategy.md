# Environment Management & Git Branch Strategy

**Date:** 2026-03-19
**Status:** Brainstorm / Plan
**Scope:** Dev + Prod environment separation via separate EKS clusters, branch strategy, secrets, CI/CD routing

---

## 1. Current State

| What exists today | Gap |
|---|---|
| One Kustomize overlay: `k8s/overlays/prod/` | No `dev` overlay |
| CI deploys to prod on every push to `main` | No dev cluster or dev deployment target |
| `.env.example` with K8s DNS URLs | No per-environment env var management |
| GitHub Actions OIDC auth | Single IAM role, no env-scoped permissions |
| Trivy scan gates on CRITICAL only | Same threshold for dev and prod |

---

## 2. Recommended Git Branch Strategy: Two-Branch Model (`main` + `develop`)

> **Not** trunk-based development. Trunk-based means committing directly to `main` with feature flags — no `develop` branch. What we use here is **GitHub Flow with a staging branch**: two long-lived branches, short-lived feature branches, and feature flags to decouple deploy from release.

### Branch Model

```
main          ─── protected, always deployable, maps to PROD
  │
develop       ─── integration branch, maps to DEV
  │
feature/*     ─── short-lived, open PRs against develop
hotfix/*      ─── branch from main, PR to main + cherry-pick to develop
```

### Rules

| Branch | Who merges | Protection rules | Triggers CI/CD |
|---|---|---|---|
| `main` | Squash merge from `develop` only | Required review + status checks | Deploy → **prod** EKS cluster |
| `develop` | Squash merge from `feature/*` | Required status checks | Deploy → **dev** EKS cluster |
| `feature/*` | Author | None | Run lint/test/build only |
| `hotfix/*` | Author | Required review | Deploy → prod on merge to main |

### Why this over GitFlow?

- NX `nx affected` already does incremental builds — no need for long release branches
- Short-lived feature branches (1–3 days) keep diffs small and conflicts minimal
- A single `develop` integration branch gives a stable dev environment to test against
- Avoids GitFlow's `release/` branch overhead — promote directly `develop → main`

### Feature Flags — the essential companion

Short-lived branches only work if incomplete features can be merged without breaking the app. Use environment-variable feature flags to deploy code in a disabled state:

```typescript
// api-nest: feature hidden behind flag
if (process.env.FEATURE_NEW_ECHO === 'true') {
  // new behaviour
}
```

- Flag is `false` on `develop` and `main` until the feature is ready
- Enables merging to `develop` daily even for multi-day work
- Prevents `develop` from becoming an "integration hell" dumping ground where half-finished features from multiple developers collide for the first time

---

## 3. Environment Separation

### 3.1 Separate EKS Clusters

Two dedicated EKS clusters — one per environment. Dev workloads never share a node, control plane, or API server with prod.

```
k8s/
  overlays/
    dev/          ← new
    prod/         ← already exists
```

| Attribute | dev cluster | prod cluster |
|---|---|---|
| EKS cluster name | `cicd-demo-dev` | `cicd-demo-prod` |
| K8s namespace | `default` (or `app`) | `default` (or `app`) |
| Node group | 1× t3.medium | 2× t3.medium (auto-scaled) |
| Replicas | 1 | 2 (HPA-managed) |
| CPU request/limit | 50m / 200m | 100m / 500m |
| Memory request/limit | 64Mi / 128Mi | 128Mi / 256Mi |
| Image tag strategy | `:dev-<sha7>` | `:prod-<sha7>` |
| Ingress hostname | `dev.internal` or node port | `app.yourdomain.com` |
| Approx. cost | ~$73/mo | ~$73/mo |

**Why separate clusters over namespaces:**
- Full control-plane isolation — a misconfigured dev webhook cannot crash prod
- No shared node resources — dev workloads cannot starve prod pods
- Cluster-scoped resources (CRDs, admission webhooks, PersistentVolumes) are truly isolated
- Meets SOC2/PCI-DSS/HIPAA environment separation requirements without extra networking policy

### 3.2 `k8s/overlays/dev/kustomization.yaml` (new file)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# No namespace field — the dev cluster uses 'default' (or 'app').
# Cluster selection is done by CI via kubeconfig, not by a namespace override.

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

# Image tags: CI replaces "dev-placeholder" via `kustomize edit set image`
# NEVER manually set dev-latest here — mutable tags break rollbacks and
# may not trigger a new pull if imagePullPolicy is IfNotPresent.
images:
  - name: api-nest
    newName: <ECR_REGISTRY>/api-nest
    newTag: dev-placeholder
  - name: api-express
    newName: <ECR_REGISTRY>/api-express
    newTag: dev-placeholder
  - name: api-python
    newName: <ECR_REGISTRY>/api-python
    newTag: dev-placeholder
  - name: web
    newName: <ECR_REGISTRY>/web
    newTag: dev-placeholder
```

> **CI must replace `dev-placeholder` with the real SHA tag.** The deploy-dev job in GitHub Actions must run the following before `kubectl apply`:
>
> ```bash
> SHA7=$(echo $GITHUB_SHA | cut -c1-7)
> cd k8s/overlays/dev
> kustomize edit set image \
>   api-nest=<ECR_REGISTRY>/api-nest:dev-${SHA7} \
>   api-express=<ECR_REGISTRY>/api-express:dev-${SHA7} \
>   api-python=<ECR_REGISTRY>/api-python:dev-${SHA7} \
>   web=<ECR_REGISTRY>/web:dev-${SHA7}
> kubectl apply -k .
> ```
>
> This mirrors exactly how the existing `prod` deploy works in `ci-cd.yml` (via `kustomize edit set image`). The placeholder in git is intentional — it documents the shape of the tag without committing a real SHA.

### 3.3 Service Discovery URLs per Environment

**Local (docker-compose):**
Uses container hostnames — already working via `.env.example`.

**Dev (`cicd-demo-dev` cluster):**
```
EXPRESS_URL=http://api-express.default.svc.cluster.local:3001
PYTHON_URL=http://api-python.default.svc.cluster.local:8000
NEST_URL=http://api-nest.default.svc.cluster.local:3000
```

**Prod (`cicd-demo-prod` cluster):**
```
EXPRESS_URL=http://api-express.default.svc.cluster.local:3001
PYTHON_URL=http://api-python.default.svc.cluster.local:8000
NEST_URL=http://api-nest.default.svc.cluster.local:3000
```

The URLs are identical across clusters — services always talk to each other within the same cluster via the K8s DNS shortname. This means the `configMapGenerator` values in the Kustomize overlay are the same for dev and prod. The environment difference is entirely in which cluster kubeconfig CI uses, not in the manifest content.

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

Each deploy job authenticates to a different EKS cluster using cluster-specific IAM roles. The kubeconfig is generated at runtime by `aws eks update-kubeconfig`.

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
    environment: development          # GitHub Environment, no approval gate
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.DEV_IAM_ROLE_ARN }}
          aws-region: us-east-1
      - run: |
          aws eks update-kubeconfig --name cicd-demo-dev --region us-east-1
          SHA7=$(echo $GITHUB_SHA | cut -c1-7)
          cd k8s/overlays/dev
          kustomize edit set image \
            api-nest=<ECR>/api-nest:dev-${SHA7} \
            api-express=<ECR>/api-express:dev-${SHA7} \
            api-python=<ECR>/api-python:dev-${SHA7} \
            web=<ECR>/web:dev-${SHA7}
          kubectl apply -k .

  deploy-prod:
    if: github.ref == 'refs/heads/main'
    needs: ci
    environment: production           # GitHub Environment — requires manual approval
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_IAM_ROLE_ARN }}
          aws-region: us-east-1
      - run: |
          aws eks update-kubeconfig --name cicd-demo-prod --region us-east-1
          SHA7=$(echo $GITHUB_SHA | cut -c1-7)
          cd k8s/overlays/prod
          kustomize edit set image \
            api-nest=<ECR>/api-nest:prod-${SHA7} \
            # ... etc
          kubectl apply -k .
```

> The `DEV_IAM_ROLE_ARN` and `PROD_IAM_ROLE_ARN` are stored as GitHub **Environment** secrets (not repo secrets) so only the corresponding job can assume each role. The dev role has no EKS permissions for `cicd-demo-prod` and vice versa.

### 5.2 Image Tagging Convention

| Environment | Tag format | Example |
|---|---|---|
| dev | `dev-<sha7>` | `dev-a1b2c3d` |
| prod | `prod-<sha7>` | `prod-a1b2c3d` |

Both tags pushed to the same ECR repository per service. This allows tracing any running image back to its exact commit.

### 5.3 Rollback Strategy

Every deploy job must include a post-deploy validation step. If the smoke test fails, the job rolls back automatically and fails the workflow:

```yaml
- name: Wait for rollout
  run: |
    for svc in api-nest api-express api-python web; do
      kubectl rollout status deployment/$svc -n $NAMESPACE --timeout=3m
    done

- name: Smoke test
  id: smoke
  run: |
    # Replace with actual ingress URL per environment
    curl --retry 5 --retry-delay 5 --fail \
      http://${INGRESS_HOST}/api/nest/ping | jq '.status == "ok"'

- name: Rollback on failure
  if: failure() && steps.smoke.conclusion == 'failure'
  run: |
    for svc in api-nest api-express api-python web; do
      kubectl rollout undo deployment/$svc -n $NAMESPACE
    done
    echo "Rolled back all deployments in $NAMESPACE"
    exit 1
```

Key points:
- `kubectl rollout status` already exists in `ci-cd.yml` — add the smoke test and rollback steps after it
- `kubectl rollout undo` reverts to the previous ReplicaSet — fast, no image rebuild needed
- K8s retains the last 10 ReplicaSets by default (`revisionHistoryLimit`), giving 10 rollback points
- For prod, consider also opening a GitHub Issue or Slack alert on auto-rollback

### 5.5 GitHub Environment Protection (for prod)

In GitHub repo settings → Environments:
- Create `production` environment
- Add required reviewers (1+ approvals before deploy)
- Restrict to `main` branch only
- Set environment secrets (AWS role ARN for prod)

For `development` environment: no approval gate, deploys automatically on merge to `develop`.

### 5.6 Separate IAM Roles per Environment

```
GitHubActions-Dev-Role   → ECR push, eks:DescribeCluster on cicd-demo-dev only
GitHubActions-Prod-Role  → ECR push, eks:DescribeCluster on cicd-demo-prod only
```

The IAM trust policy for each role restricts which GitHub Actions job can assume it (scoped to the `development` or `production` GitHub Environment). The prod role has zero IAM permissions on the dev cluster and vice versa.

Within each cluster, scope K8s RBAC using a `Role` (not `ClusterRole`) for least-privilege:

```yaml
# k8s/overlays/dev/ci-rbac.yaml
# Apply this to cicd-demo-dev cluster only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-deployer
  namespace: default
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer-binding
  namespace: default
subjects:
  - kind: User
    name: <GitHubActions-Dev-Role-ARN>
roleRef:
  kind: Role
  name: ci-deployer
  apiGroup: rbac.authorization.k8s.io
```

> With separate clusters, the isolation is already at the infrastructure level — the dev IAM role physically cannot call the prod cluster API. The `Role` (vs `ClusterRole`) is still best practice for least-privilege within a cluster, but it's defense-in-depth rather than the primary isolation mechanism.

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

# 4. Cherry-pick the fix onto develop (NOT git merge main → develop)
git checkout develop && git pull
git cherry-pick <hotfix-commit-sha>
git push
```

> **Why cherry-pick, not back-merge?**
> After squash-merging `develop → main`, the commits on `main` have no shared ancestry with `develop`. Merging `main` back into `develop` causes Git to treat every prod commit as new, resulting in duplicate commit entries in `git log`, spurious merge conflicts over time, and broken `git bisect`. Cherry-pick applies only the specific fix without re-introducing ancestry divergence.

---

## 7. Implementation Checklist

### Phase A — Branch Setup (Day 1)
- [ ] Protect `main` branch: require PR, 1 approver, status checks
- [ ] Create `develop` branch from `main`
- [ ] Protect `develop` branch: require status checks
- [ ] Update `on.push.branches` in `ci-cd.yml` to include `develop`

### Phase B — Kubernetes Dev Overlay (Day 1–2)
- [ ] Provision `cicd-demo-dev` EKS cluster (via Terraform or eksctl)
- [ ] Create `k8s/overlays/dev/kustomization.yaml` (no namespace override)
- [ ] Add `Role` + `RoleBinding` RBAC for CI dev role in `k8s/overlays/dev/ci-rbac.yaml`
- [ ] Test: `aws eks update-kubeconfig --name cicd-demo-dev` + `kubectl apply -k k8s/overlays/dev`

### Phase C — CI/CD Routing (Day 2–3)
- [ ] Add `deploy-dev` job gated on `github.ref == 'refs/heads/develop'`
- [ ] Add `deploy-prod` job gated on `github.ref == 'refs/heads/main'`
- [ ] Create `production` GitHub Environment with approval gate
- [ ] Create `development` GitHub Environment (no gate)
- [ ] Separate IAM roles for dev/prod in `infra/terraform/iam.tf` (each scoped to one EKS cluster ARN)
- [ ] Store `DEV_IAM_ROLE_ARN` in `development` GitHub Environment secrets
- [ ] Store `PROD_IAM_ROLE_ARN` in `production` GitHub Environment secrets

### Phase D — Secrets Management (Day 3–5)
- [ ] Create AWS Secrets Manager paths `/dev/*` and `/prod/*`
- [ ] Install External Secrets Operator via Helm in EKS
- [ ] Define `ExternalSecret` CRDs per service per namespace
- [ ] Remove any plaintext secrets from ConfigMaps

### Phase E — Dev Environment Validation (Day 5)
- [ ] Merge a test feature branch to `develop`
- [ ] Verify dev deploy triggers correctly and targets `cicd-demo-dev`
- [ ] Verify prod deploy does NOT trigger on `develop` push
- [ ] Verify images tagged correctly in ECR (`dev-<sha7>` vs `prod-<sha7>`)
- [ ] Verify dev role cannot call `cicd-demo-prod` API (expect 403/AccessDenied)
- [ ] Run smoke test: `curl http://dev.internal/api/nest/ping`

---

## 8. Trade-offs & Alternatives Considered

| Decision | Chosen | Alternative | Why not |
|---|---|---|---|
| Branch model | Trunk + `develop` | Full GitFlow | GitFlow release branches add overhead without benefit at this scale |
| Environment isolation | Separate EKS clusters | K8s namespaces on one cluster | Namespaces share control plane + nodes; clusters provide true blast-radius isolation |
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
