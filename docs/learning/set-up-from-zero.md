# Setting Up CI/CD and Deployment from Zero

> **Assumptions:** AWS CLI is configured with an IAM user that has admin permissions. The repo is already pushed to GitHub. Nothing else exists yet.

---

## What You're Building

A multi-environment pipeline where:
1. You push code to `main` → CI runs (tests, lint, build)
2. You merge `main` → `uat` → GitHub Actions builds Docker images, scans them, and deploys to a UAT EKS cluster
3. You merge `uat` → `prod` → GitHub Actions (with manual approval) promotes the same UAT images to a Prod EKS cluster — no rebuild

The full chain of moving parts:

```
Your machine
  └─ git push → GitHub (main branch)
                  └─ CI: npm test / lint / build / typecheck
                         (no deploy on main)

  └─ merge main → uat → deploy-uat workflow
                  ├─ Build Docker images (NX affected only)
                  ├─ Push to UAT ECR + Trivy scan
                  └─ Deploy to UAT EKS

  └─ merge uat → prod → deploy-prod workflow (approval required)
                  ├─ Read UAT image tags (no rebuild)
                  └─ Deploy same images to Prod EKS
```

---

## Infrastructure Layout

There are **two separate Terraform roots**, one per environment:

```
infra/terraform/
  prod/    ← provisions production AWS resources
  uat/     ← provisions UAT AWS resources
```

Each environment gets its own: VPC, EKS cluster, ECR repositories, IAM roles, and OIDC provider.

---

## Step 1: Provision UAT Infrastructure

```bash
cd infra/terraform/uat
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set github_repo = "your-org/your-repo"

terraform init      # downloads provider plugins
terraform plan      # shows what will be created — read this
terraform apply     # actually creates everything (~15 minutes)
```

After `apply` finishes, Terraform prints outputs:

```
aws_role_arn      = "arn:aws:iam::123456789.../github-actions-uat"
ecr_registry      = "123456789.dkr.ecr.us-east-1.amazonaws.com"
cluster_name      = "nx-monorepo-uat"
configure_kubectl = "aws eks update-kubeconfig --name nx-monorepo-uat --region us-east-1"
```

---

## Step 2: Provision Prod Infrastructure

```bash
cd infra/terraform/prod
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set github_repo = "your-org/your-repo"

terraform init
terraform plan
terraform apply
```

Same outputs as UAT but for the prod cluster.

---

## Step 3: Add GitHub Secrets

GitHub Actions reads environment-scoped secrets at runtime. Go to:
**GitHub repo → Settings → Secrets and variables → Actions**

Add these secrets to the **UAT environment** (`Settings → Environments → uat → Secrets`):

| Secret name | Value |
|-------------|-------|
| `UAT_AWS_ROLE_ARN` | from UAT `terraform output aws_role_arn` |
| `UAT_ECR_REGISTRY` | from UAT `terraform output ecr_registry` |
| `UAT_EKS_CLUSTER_NAME` | from UAT `terraform output cluster_name` |
| `AWS_REGION` | e.g. `us-east-1` |

Add these to the **production environment** (`Settings → Environments → production → Secrets`):

| Secret name | Value |
|-------------|-------|
| `PROD_AWS_ROLE_ARN` | from prod `terraform output aws_role_arn` |
| `PROD_EKS_CLUSTER_NAME` | from prod `terraform output cluster_name` |

> Add a required reviewer to the `production` environment — this is the approval gate before prod deploys.

---

## Step 4: Configure kubectl (Optional — for Local Debugging)

```bash
# UAT cluster
aws eks update-kubeconfig --name nx-monorepo-uat --region us-east-1

# Prod cluster
aws eks update-kubeconfig --name nx-monorepo-prod --region us-east-1

kubectl get nodes    # should show 2 nodes in Ready state
```

CI configures kubeconfig automatically. You only need this locally when debugging.

---

## Step 5: Push Code Through the Pipeline

**CI (main branch):**
```bash
git push origin main
```
Watch it run under **GitHub → Actions → CI**.

**Deploy to UAT:**
```bash
git checkout uat
git merge main
git push origin uat
```
Watch **GitHub → Actions → Deploy UAT**. This builds images, scans, and deploys.

**Deploy to Prod:**
```bash
git checkout prod
git merge uat
git push origin prod
```
Go to **GitHub → Actions → Deploy Prod** → click **Review deployments** → approve. Prod deployment starts immediately after approval. No rebuild — the same images from UAT are promoted.

---

## What Happens Inside the Workflows

There are three workflow files:

### `ci.yml` — Quality Gate (main branch + PRs)

```
checkout repo
→ install Node 20 + Python 3.12
→ npm ci + pip install
→ npx nx run-many -t lint test build typecheck
```

Runs on every push to `main` and every PR. If anything fails, the PR is blocked. Nothing is deployed.

### `deploy-uat.yml` — UAT Deployment

1. **OIDC auth** — assumes `UAT_AWS_ROLE_ARN` (no static keys)
2. **Resolve base SHA** — finds the last successful UAT deploy commit
3. **NX affected** — determines which services changed since last deploy
4. **For each affected service:**
   - `docker build` + `docker push` to UAT ECR (tagged with git SHA)
   - `trivy image` — fails if CRITICAL unfixed CVEs found
   - `kustomize edit set image` — patches UAT overlay
5. **Commit UAT overlay** back to `uat` branch (`[skip ci]`)
6. **`kubectl apply -k k8s/overlays/uat`** → rolling update
7. **`kubectl rollout status`** — waits for healthy pods

### `deploy-prod.yml` — Prod Promotion

1. **Manual approval** — GitHub Environment gate (required reviewer)
2. **OIDC auth** — assumes `PROD_AWS_ROLE_ARN`
3. **Read UAT image tags** — uses `yq` to parse `k8s/overlays/uat/kustomization.yaml`
4. **Patch prod overlay** — copies the exact same ECR image URIs + SHAs to `k8s/overlays/prod/kustomization.yaml`
5. **Commit prod overlay** back to `prod` branch (`[skip ci]`)
6. **`kubectl apply -k k8s/overlays/prod`** → rolling update
7. **`kubectl rollout status`** — waits for healthy pods

---

## The Kubernetes Side (What Lives in `k8s/`)

```
k8s/
  base/                          ← shared across environments
    api-nest/deployment.yaml     ← container spec, resources, health check
    api-nest/service.yaml        ← internal DNS name
    api-express/deployment.yaml
    api-express/service.yaml
    api-express/hpa.yaml         ← HorizontalPodAutoscaler (min 1, max 4 replicas)
    api-express/pdb.yaml         ← PodDisruptionBudget (min 1 available)
    api-python/...
    web/...
    api-ingress.yaml             ← routes /api/* traffic with path rewriting
    web-ingress.yaml             ← routes /* to the web frontend
  overlays/
    uat/
      kustomization.yaml         ← patches image tags to UAT ECR URIs
      cluster-secret-store.yaml  ← ESO: connects to UAT AWS Secrets Manager
      external-secret-api-nest.yaml ← ESO: pulls SERVICE_SECRET for api-nest
    prod/
      kustomization.yaml         ← patches image tags to Prod ECR URIs
      hpa-api-express.yaml       ← overrides HPA threshold to 70% CPU for prod
      cluster-secret-store.yaml  ← ESO: connects to Prod AWS Secrets Manager
      external-secret-api-nest.yaml ← ESO: pulls SERVICE_SECRET for api-nest
```

**Base manifests** use placeholder image names (`api-nest:latest`). CI updates each overlay's `kustomization.yaml` with real ECR URIs on every deploy.

**Ingress** routes external HTTP traffic:
- `/api/nest/*` → strips prefix → `api-nest` pod on port 3000
- `/api/express/*` → strips prefix → `api-express` pod on port 3001
- `/api/python/*` → strips prefix → `api-python` pod on port 8000
- `/` → `web` pod on port 4000

**External Secrets Operator (ESO)** syncs secrets from AWS Secrets Manager to Kubernetes Secrets. Pods read these secrets as environment variables — no secrets live in YAML files or Git.

---

## Verifying It Worked

After the UAT pipeline completes:

```bash
aws eks update-kubeconfig --name nx-monorepo-uat --region us-east-1
kubectl get pods          # all 4 pods should be Running, 1/1 Ready
kubectl get ingress       # shows the NLB address in the ADDRESS column
curl http://<NLB_ADDRESS>/api/nest/ping
```

Expected response — the full echo chain:
```json
{
  "service": "nest",
  "status": "ok",
  "downstream": {
    "service": "express",
    "status": "ok",
    "downstream": { "service": "python", "status": "ok" }
  }
}
```

---

## Tearing Down (Cost Management)

Each cluster costs ~$150/month while running. When done:

```bash
cd infra/terraform/uat
terraform destroy   # removes UAT cluster and all its resources

cd infra/terraform/prod
terraform destroy   # removes prod cluster and all its resources
```

The repo and code stay intact. Run `terraform apply` again to recreate.

---

## Summary of Responsibilities

| Component | Who creates it | What it does |
|-----------|---------------|-------------|
| Terraform (`infra/terraform/uat/`, `prod/`) | You, once manually per env | Provisions all AWS resources |
| GitHub Environment secrets | You, once manually per env | Gives CI permission to use AWS |
| `ci.yml` | Runs on main + PRs | Tests, lints, builds — blocks bad code |
| `deploy-uat.yml` | Runs on uat branch | Builds, scans, deploys to UAT |
| `deploy-prod.yml` | Runs on prod branch (with approval) | Promotes UAT images to prod |
| ECR | Created by Terraform | Stores Docker images |
| EKS | Created by Terraform | Runs containers |
| K8s manifests (`k8s/`) | Already in repo | Tells Kubernetes how to run each service |
| Kustomize overlays | Updated by CI on deploy | Patches image tags to specific ECR URIs |
| AWS Secrets Manager + ESO | Terraform + ESO install | Syncs app secrets into the cluster |
