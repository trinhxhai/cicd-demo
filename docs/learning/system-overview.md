# System Overview — Deployment, CI/CD, and AWS

This document is your entry point for understanding how this system works end-to-end: from writing code locally to running it on AWS. Other files in `docs/learning/` go deeper into specific tools and components. Start here.

---

## 1. The Big Picture — Three Layers

Everything in this system lives in one of three layers. Understanding the boundary between them is the key mental model.

```
┌─────────────────────────────────────────────────────┐
│  MONOREPO LAYER  (NX)                               │
│  Manages code, builds, and knows what changed        │
└────────────────────────┬────────────────────────────┘
                         │ git push
┌────────────────────────▼────────────────────────────┐
│  PIPELINE LAYER  (GitHub Actions)                   │
│  Reacts to pushes — test → build → push → deploy    │
└────────────────────────┬────────────────────────────┘
                         │ kubectl apply
┌────────────────────────▼────────────────────────────┐
│  CLOUD LAYER  (AWS via Terraform)                   │
│  Runs workloads (EKS), stores images (ECR),         │
│  routes traffic (NLB → Nginx → services)            │
└─────────────────────────────────────────────────────┘
```

Each layer has one job. The monorepo layer does not know about AWS. The pipeline layer connects them. The cloud layer does not know about GitHub.

**Tools at a glance:**

| Layer | Tool | Role |
|---|---|---|
| Monorepo | NX | Workspace orchestration, `nx affected` for smart builds |
| Monorepo | Docker | Containerizes each service |
| Pipeline | GitHub Actions | CI/CD automation triggered on push |
| Pipeline | Kustomize | Patches Kubernetes manifests with new image tags |
| Cloud | Terraform | Declares and provisions all AWS infrastructure |
| Cloud | AWS ECR | Container image registry — one repo per service |
| Cloud | AWS EKS | Managed Kubernetes — runs the containers |
| Cloud | AWS VPC | Network isolation for the cluster |
| Cloud | AWS IAM / OIDC | Auth between GitHub Actions and AWS |
| Cloud | NLB | Network Load Balancer — entry point from the internet |
| Cloud | Nginx Ingress | Routes traffic inside the cluster by path |

---

## 2. Branch Strategy — Three Environments

Code flows through three branches, each with its own environment:

```
main  ──► (CI only — lint, test, build, typecheck)
  │
  └─ merge to uat ──► deploy-uat: build Docker images → push to UAT ECR → deploy to UAT EKS
                            │
                            └─ merge to prod ──► deploy-prod: promote UAT image tags → deploy to Prod EKS
```

| Branch | Workflow | What it does |
|--------|----------|-------------|
| `main` | `ci.yml` | Runs tests/lint/build on every push and PR — no deploy |
| `uat` | `deploy-uat.yml` | Builds Docker images, scans with Trivy, deploys to UAT cluster |
| `prod` | `deploy-prod.yml` | Promotes UAT image tags to prod overlay, deploys to Prod cluster (requires manual approval) |

**Key principle: build once, deploy many.** Docker images are built once on `uat` and promoted to prod — the same image that was tested in UAT goes to prod, with no rebuild.

---

## 3. The UAT Deployment Flow — What Happens on `git push` to `uat`

Every push to `uat` triggers `.github/workflows/deploy-uat.yml`. Here's the full story:

### Step 1 — GitHub Actions authenticates to AWS (OIDC)

```yaml
uses: aws-actions/configure-aws-credentials@v4
with:
  role-to-assume: ${{ secrets.UAT_AWS_ROLE_ARN }}
```

GitHub Actions assumes a UAT-specific IAM role via OIDC federation. There are no long-lived AWS access keys — just a role ARN. The role has least-privilege permissions: ECR push/pull and `AmazonEKSEditPolicy` scoped to the `default` namespace only.

**Why OIDC?** Static access keys are a security risk — if they leak, anyone can use them. OIDC tokens are short-lived and scoped to the exact workflow. Terraform created the trust relationship in `infra/terraform/uat/`.

### Step 2 — NX figures out what changed

```
AFFECTED=$(npx nx show projects --affected --base=$LAST_DEPLOY_SHA --head=HEAD)
```

NX compares the current commit against the last successful UAT deploy. Only services whose source files changed are affected. If you only touched `api-express`, the other three services are skipped entirely — no rebuild, no redeploy.

### Step 3 — Docker images built, pushed, and scanned

For each affected service:
```
docker build -t <ecr-registry>/<service>:<git-sha> -f apps/<service>/Dockerfile .
docker push <ecr-registry>/<service>:<git-sha>
trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed <image>
```

Images are tagged with the git commit SHA. Trivy scans each image for known CVEs — if a critical unfixed vulnerability is found, the pipeline fails and the image is never deployed.

### Step 4 — Kustomize patches the UAT overlay

```
kustomize edit set image "api-express=$ECR_REGISTRY/api-express:$IMAGE_TAG"
```

Kustomize updates `k8s/overlays/uat/kustomization.yaml` with the new ECR image URI for each affected service. CI commits this file back to the `uat` branch (`[skip ci]`). The overlay is the source of truth for what's deployed to UAT.

### Step 5 — Deploy to UAT EKS

```
kubectl apply -k k8s/overlays/uat
kubectl rollout status deployment/api-express --timeout=120s
```

Kubernetes applies the updated manifests with a rolling update. The workflow blocks until all deployments are healthy.

**UAT flow summary:**
```
git push → OIDC auth → nx affected → docker build → ECR push → Trivy scan
→ kustomize patch → git commit overlay → kubectl apply → rollout status
```

---

## 4. The Prod Deployment Flow — Promoting from UAT

Every push to `prod` triggers `.github/workflows/deploy-prod.yml`. Prod does **not** rebuild Docker images — it reads the exact image tags from the UAT overlay and applies them to prod.

### Step 1 — Manual approval gate

The workflow is configured with `environment: production` in GitHub Actions. A required reviewer must approve the deployment before it proceeds. This is the human checkpoint between UAT and prod.

### Step 2 — Authenticate to prod AWS role

```yaml
role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
```

A separate prod-specific IAM role with least-privilege permissions.

### Step 3 — Promote UAT image tags

```bash
# Read each service's image from the UAT overlay
NEW_TAG=$(yq eval ".images[] | select(.name == \"$svc\") | .newTag" k8s/overlays/uat/kustomization.yaml)
kustomize edit set image "$svc=$NEW_NAME:$NEW_TAG"
```

The exact same images that passed UAT are patched into `k8s/overlays/prod/kustomization.yaml`. No Docker build happens.

### Step 4 — Deploy to Prod EKS

```
kubectl apply -k k8s/overlays/prod
kubectl rollout status deployment/... --timeout=120s
```

**Prod flow summary:**
```
PR merge to prod → approval gate → OIDC auth → read UAT image tags
→ patch prod overlay → git commit overlay → kubectl apply → rollout status
```

---

## 5. The Infrastructure — What Terraform Owns

All AWS resources are declared in `infra/terraform/`. Terraform is the source of truth for cloud state — you do not click in the AWS console to create or change infrastructure.

There are **two separate Terraform roots**, one per environment:

```
infra/terraform/
  prod/    ← production cluster
  uat/     ← UAT cluster
```

Each root follows the same file structure:

| File | What it creates |
|---|---|
| `vpc.tf` | VPC, subnets (public + private), routing |
| `eks.tf` | EKS cluster, managed node group (t3.medium × 2), Nginx Ingress via Helm, cluster-autoscaler via Helm |
| `ecr.tf` | 4 ECR repositories (one per service) |
| `iam.tf` | OIDC provider, IAM role for GitHub Actions (least-privilege: ECR + AmazonEKSEditPolicy scoped to default namespace), ESO RBAC ClusterRole + binding |
| `outputs.tf` | Prints ECR URLs, cluster name, kubeconfig command after apply |

**The workflow for any infra change:**
```
terraform plan    ← preview what will change
terraform apply   ← apply it
```

Never skip `plan`. It shows you exactly what Terraform will create, modify, or destroy before anything touches AWS.

**Nginx Ingress** is installed inside the cluster by Terraform (via Helm provider). Its `LoadBalancer` service causes AWS to auto-provision an NLB. Nginx then routes incoming traffic by path:
- `/` → `web` (Next.js)
- `/api/nest/*` → `api-nest`
- `/api/express/*` → `api-express`
- `/api/python/*` → `api-python`

**Cluster Autoscaler** is also installed via Helm by Terraform. It watches for unschedulable Pods (node is full) and adds EC2 nodes, and removes underutilized nodes to save cost.

**External Secrets Operator (ESO)** runs inside the cluster (installed separately) and syncs secrets from AWS Secrets Manager into Kubernetes Secrets. For example, `api-nest` reads its `SERVICE_SECRET` from Secrets Manager via ESO — no secrets are hardcoded in YAML or environment variables.

---

## 6. Your Responsibilities as Maintainer

### Day-to-day

- **Watch GitHub Actions** — the deploy workflows are the first signal something is wrong. A failed step tells you exactly where the problem is.
- **Check rollout health** — if `kubectl rollout status` times out, investigate with `kubectl describe pod <name>` and `kubectl logs <name>`.
- **Monitor costs** — each cluster runs ~$150/month when idle. You have two clusters (UAT + prod). Know this number and check monthly.

### Deployment promotion flow

```
1. Push to main → CI (tests/lint/build) must pass
2. Merge main → uat → deploy-uat builds images, deploys to UAT
3. Test in UAT
4. Merge uat → prod → deploy-prod (approval required) promotes images to prod
```

### When things change

| Change needed | What you touch |
|---|---|
| Add a new service | New `apps/<svc>/`, Dockerfile, `project.json`, K8s manifests in `k8s/base/`, ECR repo in both `infra/terraform/prod/ecr.tf` and `infra/terraform/uat/ecr.tf`, update deploy-uat.yml SERVICES array |
| Change infra (node size, region, etc.) | Edit `.tf` files in `infra/terraform/prod/` or `infra/terraform/uat/` → `terraform plan` → `terraform apply` |
| Change K8s config (env vars, replicas, resources) | Edit `k8s/base/<svc>/deployment.yaml` or overlay patch → push triggers deploy |
| Add/rotate application secrets | Update secret in AWS Secrets Manager — ESO syncs it automatically to the cluster |
| Rotate CI credentials | CI uses OIDC (no static keys to rotate). Update trust policy or role ARN in GitHub secrets if needed. |
| Update a service | Push to `main` → merge to `uat` — the pipeline handles the rest |

### Cost and safety

Each cluster costs money whether or not traffic is running:

| Resource | ~Monthly cost per cluster |
|---|---|
| EKS control plane | $73 |
| 2× t3.medium EC2 nodes | $60 |
| NLB | $18 |
| ECR storage | ~$1 |
| **Total per cluster** | **~$150** |

With UAT + prod both running: ~$300/month.

**To tear down an environment safely:**
```
cd infra/terraform/prod    # or /uat
terraform destroy
```

This removes the EKS cluster, NLB, ECR repos, IAM roles, and VPC. Do not delete resources manually in the AWS console — Terraform won't know about it and future operations will error or leave orphans.

---

## Where to Go Next

| Topic | File |
|---|---|
| NX — affected, caching, targets | `docs/learning/monorepo-nx.md` |
| EKS + Kubernetes concepts | `docs/learning/eks-kubernetes.md` |
| How K8s is set up in this project | `docs/learning/project-k8s-setup.md` |
| CI/CD security (OIDC, least privilege) | `docs/learning/cicd-security.md` |
| Full setup from zero | `docs/learning/set-up-from-zero.md` |
| Phase 2 anti-patterns and gaps | `docs/learning/phase-2-report.md` |
