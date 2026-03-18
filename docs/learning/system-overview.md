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

## 2. The Deployment Flow — What Happens on `git push`

Every push to `main` triggers the deploy workflow (`.github/workflows/deploy.yml`). Here's the full story:

### Step 1 — NX figures out what changed

```
nx show projects --affected --base=origin/main~1 --head=HEAD
```

NX compares the current commit against the previous one and outputs only the services that actually changed. This means if you only touched `api-express`, the other three services are skipped entirely — no rebuild, no redeploy. This matters because rebuilding all 4 Docker images on every push is slow and wasteful.

**Why NX for this?** NX understands the dependency graph of the monorepo. If a shared library changes, it knows which services depend on it and marks them all as affected.

### Step 2 — Tests run (affected only)

```
nx affected --target=test --parallel=3
```

Only the affected services are tested. If tests fail, the workflow stops here — nothing is built or deployed.

### Step 3 — GitHub Actions authenticates to AWS (OIDC)

```yaml
uses: aws-actions/configure-aws-credentials@v4
with:
  role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
```

GitHub Actions assumes an IAM role via OIDC federation. There are no long-lived AWS access keys stored in GitHub secrets — just a role ARN. AWS verifies the request came from this specific GitHub repo and branch before granting access.

**Why OIDC?** Static access keys are a security risk — if they leak, anyone can use them. OIDC tokens are short-lived and scoped to the exact workflow. Terraform created the trust relationship in `infra/terraform/iam.tf`.

### Step 4 — Docker images built and pushed to ECR

For each affected service:
```
docker build -t <ecr-registry>/<service>:<git-sha> -f apps/<service>/Dockerfile .
docker push <ecr-registry>/<service>:<git-sha>
```

Images are tagged with the git commit SHA (`$GITHUB_SHA`). This makes every image traceable — you can always tell exactly which commit produced it.

**Why ECR?** It's the AWS-native registry, tightly integrated with EKS. IAM controls who can push and pull — no separate credentials needed once OIDC is configured.

### Step 5 — Kustomize patches the image tag

```
kustomize edit set image api-express=<ecr-registry>/api-express:<git-sha>
```

Kustomize updates `k8s/overlays/prod/kustomization.yaml` with the new image tag for each affected service. This file is then committed back to the repo (`[skip ci]` to avoid a loop). The overlay is the source of truth for what's currently deployed.

**Why Kustomize?** It lets `k8s/base/` hold the canonical manifests (shared across environments) while overlays patch only what differs (image tags, replica counts, resource limits). No templating engine needed — it's plain YAML with targeted patches.

### Step 6 — Deploy to EKS

```
kubectl apply -k k8s/overlays/prod
```

Kubernetes applies the updated manifests. For services with a new image tag, it performs a rolling update — new pods start, old pods drain, no downtime.

### Step 7 — Wait for rollout

```
kubectl rollout status deployment/api-express --timeout=120s
```

The workflow blocks until all deployments are healthy. If a pod fails to start (bad image, crash loop, etc.), this step times out and the workflow fails — surfacing the problem immediately.

**Full flow summary:**
```
git push → nx affected → tests → OIDC auth → docker build → ECR push
→ kustomize patch → git commit overlay → kubectl apply → rollout status
```

---

## 3. The Infrastructure — What Terraform Owns

All AWS resources are declared in `infra/terraform/`. Terraform is the source of truth for cloud state — you do not click in the AWS console to create or change infrastructure.

| File | What it creates |
|---|---|
| `vpc.tf` | VPC, subnets (public + private), routing |
| `eks.tf` | EKS cluster, managed node group (t3.medium × 2), Nginx Ingress via Helm |
| `ecr.tf` | 4 ECR repositories (one per service) |
| `iam.tf` | OIDC provider, IAM role for GitHub Actions with ECR + EKS permissions |
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

---

## 4. Your Responsibilities as Maintainer

### Day-to-day

- **Watch GitHub Actions** — the deploy workflow is the first signal something is wrong. A failed step tells you exactly where the problem is.
- **Check rollout health** — if `kubectl rollout status` times out, investigate with `kubectl describe pod <name>` and `kubectl logs <name>`.
- **Monitor costs** — the cluster runs ~$150/month when idle. Know this number and check it monthly.

### When things change

| Change needed | What you touch |
|---|---|
| Add a new service | New `apps/<svc>/`, Dockerfile, `project.json`, K8s manifests in `k8s/base/`, ECR repo in `ecr.tf`, entry in deploy workflow |
| Change infra (node size, region, etc.) | Edit `.tf` files → `terraform plan` → `terraform apply` |
| Change K8s config (env vars, replicas, resources) | Edit `k8s/base/<svc>/deployment.yaml` or overlay patch → push triggers deploy |
| Rotate secrets | Update GitHub repo secrets (AWS_ROLE_ARN, ECR_REGISTRY, EKS_CLUSTER_NAME) |
| Update a service | Just push code — the pipeline handles the rest |

### Cost and safety

The cluster costs money whether or not traffic is running. Resources that keep billing:

| Resource | ~Monthly cost |
|---|---|
| EKS control plane | $73 |
| 2× t3.medium EC2 nodes | $60 |
| NLB | $18 |
| ECR storage | ~$1 |
| **Total** | **~$150** |

**To tear everything down safely:**
```
terraform destroy   ← removes all AWS resources Terraform created
```

This removes the EKS cluster, NLB, ECR repos, IAM roles, and VPC. Do not run `eksctl delete cluster` or manually delete resources — Terraform needs to manage teardown to avoid orphaned resources that keep billing.

---

## Where to Go Next

| Topic | File |
|---|---|
| NX — affected, caching, targets | `docs/learning/nx.md` |
| GitHub Actions — workflow anatomy | `docs/learning/github-actions.md` |
| Terraform — how it works, state | `docs/learning/terraform.md` |
| EKS + Kubernetes concepts | `docs/learning/eks-kubernetes.md` |
| Kustomize — base + overlays | `docs/learning/kustomize.md` |
| Docker — multi-stage builds | `docs/learning/docker.md` |
| Autoscaling (Phase 3) | `docs/learning/autoscaling.md` |
