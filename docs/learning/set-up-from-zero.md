# Setting Up CI/CD and Deployment from Zero

> **Assumptions:** AWS CLI is configured with an IAM user that has admin permissions. The repo is already pushed to GitHub. Nothing else exists yet.

---

## What You're Building

A pipeline where:
1. You push code to `main`
2. GitHub Actions automatically runs tests
3. Only changed services get rebuilt and pushed to AWS ECR (Docker registry)
4. The new images get deployed to a Kubernetes cluster on AWS (EKS)

The full chain of moving parts:

```
Your machine
  └─ git push → GitHub
                  └─ GitHub Actions (CI/CD)
                       ├─ npm test / lint / build
                       ├─ AWS ECR (stores Docker images)
                       └─ AWS EKS (runs containers)
                              └─ Kubernetes pods (api-nest, api-express, api-python, web)
```

---

## Step 1: Provision AWS Infrastructure (Terraform)

Before CI/CD can do anything, the AWS resources it needs must exist. Terraform creates all of them in one shot:

| Resource | What it is | Why it's needed |
|----------|-----------|-----------------|
| VPC + subnets | Private network in AWS | Isolates your cluster from the internet |
| EKS cluster | Managed Kubernetes | Runs your Docker containers |
| ECR repositories (×4) | Docker image registry | Stores built images for each service |
| IAM OIDC role | Identity for GitHub Actions | Lets CI authenticate to AWS without a static key |
| Nginx Ingress (via Helm) | HTTP router inside the cluster | Routes external traffic to the right service |
| NLB | Network Load Balancer | Public entry point, auto-created by Nginx Ingress |

**How to run it:**

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set github_repo = "your-org/your-repo"

terraform init      # downloads provider plugins
terraform plan      # shows what will be created (~50 resources) — read this
terraform apply     # actually creates everything (~15 minutes)
```

After `apply` finishes, Terraform prints outputs:

```
aws_role_arn     = "arn:aws:iam::123456789.../github-actions-eks"
ecr_registry     = "123456789.dkr.ecr.us-east-1.amazonaws.com"
cluster_name     = "nx-monorepo"
configure_kubectl = "aws eks update-kubeconfig --name nx-monorepo --region us-east-1"
```

Save these — you'll need them in the next step.

---

## Step 2: Add GitHub Secrets

GitHub Actions reads these secrets at runtime. Without them, the pipeline can't authenticate to AWS.

Go to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|-------------|-------|
| `AWS_ROLE_ARN` | from `terraform output aws_role_arn` |
| `AWS_REGION` | e.g. `us-east-1` |
| `ECR_REGISTRY` | from `terraform output ecr_registry` |
| `EKS_CLUSTER_NAME` | from `terraform output cluster_name` |

**Why secrets and not hardcoded values?** The role ARN and ECR registry contain your AWS account ID. Committing them to the repo exposes your account to enumeration. Secrets are encrypted and injected into the workflow at runtime.

---

## Step 3: Configure kubectl (Optional — for Local Debugging)

This lets you inspect the cluster from your machine:

```bash
aws eks update-kubeconfig --name nx-monorepo --region us-east-1
kubectl get nodes    # should show 2 nodes in Ready state
```

CI does this automatically during the deploy job. You only need this locally when debugging.

---

## Step 4: Push to Main

Everything is now wired up. Pushing to `main` triggers the pipeline:

```bash
git push origin main
```

Watch it run: **GitHub → Actions tab**

---

## What Happens Inside CI/CD

The workflow file lives at `.github/workflows/ci-cd.yml`. It runs two jobs sequentially.

### Job 1: `ci` (runs on every push and PR)

```
checkout repo
→ install Node 20 + Python 3.12
→ npm ci
→ pip install -r apps/api-python/requirements.txt
→ npx nx run-many -t lint test build typecheck
```

This job runs for **every** push and PR. If any test or lint check fails, the deploy job is blocked. No broken code reaches the cluster.

### Job 2: `deploy` (only on push to `main`)

This job runs only after `ci` passes, and only on `main` (not PRs).

#### 2a. Authenticate to AWS (OIDC — no static keys)

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
```

GitHub sends a short-lived JWT token to AWS. AWS checks it against the OIDC provider Terraform created. If it matches your repo, AWS hands back a temporary session credential. No passwords stored anywhere.

#### 2b. Log in to ECR

```bash
aws-actions/amazon-ecr-login   # generates a temporary docker login token
```

Docker can now push images to your ECR repositories.

#### 2c. Determine what changed (nx affected)

```bash
LAST_SUCCESS=$(gh run list --workflow=ci-cd.yml --status=success --limit=1 ...)
AFFECTED=$(npx nx show projects --affected --base=$LAST_SUCCESS --head=HEAD)
```

Nx compares the current commit against the last successful deploy. Only projects whose source files changed are listed as "affected". If you only changed `api-nest`, the other three services are skipped — saving build time and avoiding unnecessary restarts.

#### 2d. Build, push, and scan each affected service

For each affected service:

```bash
docker build -t "$ECR_REGISTRY/$svc:$IMAGE_TAG" -f "apps/$svc/Dockerfile" .
docker push "$ECR_REGISTRY/$svc:$IMAGE_TAG"
trivy image --exit-code 1 --severity CRITICAL "$ECR_REGISTRY/$svc:$IMAGE_TAG"
```

`IMAGE_TAG` is the git commit SHA (e.g. `abc1234`). This makes every image traceable back to an exact commit.

Trivy scans the pushed image for known CVEs. If a CRITICAL unfixed vulnerability is found, the pipeline fails and the image is never deployed.

#### 2e. Patch image tags in the Kubernetes overlay

```bash
cd k8s/overlays/prod
kustomize edit set image "api-nest=$ECR_REGISTRY/api-nest:$IMAGE_TAG"
```

Kubernetes doesn't know about CI — it reads a YAML file. `kustomize edit set image` updates `k8s/overlays/prod/kustomization.yaml` with the new ECR image URI. CI then commits and pushes this change back to the repo.

#### 2f. Deploy to EKS

```bash
aws eks update-kubeconfig --name $EKS_CLUSTER_NAME
kubectl apply -k k8s/overlays/prod
kubectl rollout status deployment/api-nest --timeout=120s
```

`kubectl apply -k` sends the Kustomize-rendered manifests to the cluster. Kubernetes performs a rolling update — starting new pods with the new image before terminating old ones. The rollout status command waits up to 2 minutes and fails the job if pods don't become healthy.

---

## The Kubernetes Side (What Lives in `k8s/`)

The cluster configuration is split into base and overlay:

```
k8s/
  base/                        ← shared across environments
    api-nest/
      deployment.yaml          ← "run this container, 1 replica, health check at /ping"
      service.yaml             ← "expose this pod inside the cluster on port 3000"
    api-ingress.yaml           ← "route /api/nest/* → api-nest service"
    web-ingress.yaml           ← "route /* → web service"
  overlays/
    prod/
      kustomization.yaml       ← patches image names with real ECR URIs
```

**Base manifests** use placeholder image names (`api-nest:latest`). They define the shape of the deployment — replicas, ports, resource limits, health checks.

**The overlay** patches those placeholders with real ECR image URIs. CI updates this file on every deploy. This is how Kubernetes knows which exact image to pull.

**Ingress** is the HTTP router. Nginx Ingress Controller reads these rules and routes incoming requests:
- `/api/nest/*` → strips the prefix, forwards to `api-nest` pod on port 3000
- `/api/express/*` → strips the prefix, forwards to `api-express` pod on port 3001
- `/` → forwards to `web` pod on port 4000

---

## Verifying It Worked

After the pipeline completes:

```bash
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

EKS costs ~$150/month while running. When you're done:

```bash
cd infra/terraform
terraform destroy   # removes everything Terraform created
```

The repo and code stay intact. Run `terraform apply` again next session to recreate everything.

---

## Summary of Responsibilities

| Component | Who creates it | What it does |
|-----------|---------------|-------------|
| Terraform (`infra/terraform/`) | You, once manually | Provisions all AWS resources |
| GitHub Secrets | You, once manually | Gives CI permission to use AWS |
| GitHub Actions (`.github/workflows/ci-cd.yml`) | Runs automatically on push | Tests, builds, scans, deploys |
| ECR | Created by Terraform | Stores Docker images |
| EKS | Created by Terraform | Runs containers |
| Kubernetes manifests (`k8s/`) | Already in repo | Tells Kubernetes how to run each service |
| Kustomize overlay (`k8s/overlays/prod/`) | Updated by CI on deploy | Patches image tags to specific ECR URIs |
