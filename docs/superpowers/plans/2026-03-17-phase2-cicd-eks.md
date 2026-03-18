# Phase 2: CI/CD + EKS Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy all 4 services to an EKS cluster and wire a GitHub Actions pipeline so that every push to `main` automatically builds, pushes to ECR, and deploys to Kubernetes.

**Architecture:** Terraform manages all AWS resources (VPC, EKS, ECR, IAM) so every change is previewed with `terraform plan` before it runs and torn down safely with `terraform destroy`. Raw Kubernetes manifests in `k8s/base/` per service, with Kustomize overlays for prod. GitHub Actions authenticates to AWS via OIDC (no static keys), builds only changed services via `nx affected`, and deploys with `kubectl apply -k`. Nginx Ingress Controller (installed via Helm in Terraform) routes external traffic; AWS auto-provisions an NLB in front of it.

**Tech Stack:** Terraform, AWS EKS, ECR, IAM, VPC, NLB, Helm, kubectl, Kustomize, GitHub Actions

**Prerequisite:** Phase 1 must be complete. All 4 Docker images must build successfully locally.

---

## File Map

```
infra/
  terraform/
    versions.tf                  ← provider requirements + optional S3 backend
    variables.tf                 ← aws_region, cluster_name, github_repo
    vpc.tf                       ← VPC + subnets via terraform-aws-modules/vpc
    eks.tf                       ← EKS cluster + Nginx Ingress via Helm
    ecr.tf                       ← 4 ECR repositories
    iam.tf                       ← OIDC IAM role for GitHub Actions
    outputs.tf                   ← prints ARNs and kubeconfig command
    terraform.tfvars.example     ← copy to terraform.tfvars and fill in

k8s/
  base/
    api-python/
      deployment.yaml            ← 1 replica, image placeholder, readiness probe
      service.yaml               ← ClusterIP on port 8000
    api-express/
      deployment.yaml            ← 1 replica
      service.yaml               ← ClusterIP on port 3001
    api-nest/
      deployment.yaml            ← 1 replica
      service.yaml               ← ClusterIP on port 3000
    web/
      deployment.yaml            ← 1 replica
      service.yaml               ← ClusterIP on port 4000
    api-ingress.yaml             ← Nginx rules with prefix strip: /api/nest → nest, etc.
    web-ingress.yaml             ← Nginx catch-all for web, no rewrite (preserves full path)
    kustomization.yaml           ← lists all base resources
  overlays/
    prod/
      kustomization.yaml         ← patches image tags + resource limits

.github/
  workflows/
    deploy.yml                   ← CI/CD pipeline: test → build → push → deploy
```

---

## Task 1: Terraform Infrastructure

Replaces the old bash scripts. Every resource is declared in HCL, previewed before creation, and destroyed cleanly. **Nginx Ingress is installed via Helm inside Terraform** — no separate kubectl step needed.

### Files
- Create: `infra/terraform/versions.tf`
- Create: `infra/terraform/variables.tf`
- Create: `infra/terraform/vpc.tf`
- Create: `infra/terraform/eks.tf`
- Create: `infra/terraform/ecr.tf`
- Create: `infra/terraform/iam.tf`
- Create: `infra/terraform/outputs.tf`
- Create: `infra/terraform/terraform.tfvars.example`

---

- [ ] **Step 1: Create infra/terraform directory**

```bash
mkdir -p infra/terraform
```

---

- [ ] **Step 2: Create versions.tf**

Create `infra/terraform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  # Optional: uncomment to store state in S3 (recommended for teams)
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "nx-monorepo/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
```

---

- [ ] **Step 3: Create variables.tf**

Create `infra/terraform/variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "nx-monorepo"
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format (e.g. myorg/nx-monorepo-boilerplate)"
  type        = string
}
```

---

- [ ] **Step 4: Create vpc.tf**

Create `infra/terraform/vpc.tf`:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true  # cost optimization; set false for HA prod
  enable_dns_hostnames = true

  # Required tags for EKS to discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
```

---

- [ ] **Step 5: Create eks.tf**

Create `infra/terraform/eks.tf`:

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.32"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    workers = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      disk_size      = 20
    }
  }

  # Grants the caller (you) admin access to the cluster automatically
  enable_cluster_creator_admin_permissions = true
}

# Nginx Ingress Controller — installed via Helm, creates an NLB automatically
resource "helm_release" "nginx_ingress" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.10.1"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  depends_on = [module.eks]
}
```

---

- [ ] **Step 6: Create ecr.tf**

Create `infra/terraform/ecr.tf`:

```hcl
locals {
  services = toset(["api-python", "api-express", "api-nest", "web"])
}

resource "aws_ecr_repository" "services" {
  for_each = local.services

  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

---

- [ ] **Step 7: Create iam.tf**

Create `infra/terraform/iam.tf`:

```hcl
data "aws_caller_identity" "current" {}

# Register the GitHub Actions OIDC provider with AWS IAM.
# This must exist before any role can use AssumeRoleWithWebIdentity from GitHub.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Thumbprint for token.actions.githubusercontent.com (stable — rotate only if GitHub rotates their cert)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust policy: any GitHub Actions workflow in your repo can assume this role.
# StringLike with wildcard covers pushes, PRs, manual dispatches, and tags.
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike + wildcard lets all branches/tags/PRs in your repo authenticate.
    # To restrict to main-only deployments, enforce that in the workflow (not here).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-eks"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

# ECR: push/pull images
resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# EKS: describe cluster (needed for aws eks update-kubeconfig)
resource "aws_iam_policy" "github_actions_eks_describe" {
  name = "github-actions-eks-describe"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = module.eks.cluster_arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_eks_describe" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_eks_describe.arn
}

# Grant kubectl access via modern EKS access entries (replaces the old system:masters configmap hack)
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_actions_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
```

---

- [ ] **Step 8: Create outputs.tf**

Create `infra/terraform/outputs.tf`:

```hcl
output "aws_role_arn" {
  description = "Add to GitHub secret: AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "ecr_registry" {
  description = "Add to GitHub secret: ECR_REGISTRY"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
```

---

- [ ] **Step 9: Create terraform.tfvars.example**

Create `infra/terraform/terraform.tfvars.example`:

```hcl
aws_region   = "us-east-1"
cluster_name = "nx-monorepo"
github_repo  = "your-org/nx-monorepo-boilerplate"
```

---

- [ ] **Step 10: Add .gitignore for Terraform secrets**

Create `infra/terraform/.gitignore`:

```
# Local state — commit only if you have no S3 backend
terraform.tfstate
terraform.tfstate.backup

# Real vars file (contains github_repo — harmless but a good habit)
terraform.tfvars

# Terraform downloaded provider binaries (do NOT gitignore .terraform.lock.hcl — that file pins
# provider versions and MUST be committed so terraform init is reproducible across machines)
.terraform/
```

---

- [ ] **Step 11: Commit**

```bash
git add infra/
git commit -m "feat: add Terraform infra (VPC, EKS, ECR, IAM, Nginx Ingress via Helm)"
```

---

## Task 2: Kubernetes Base Manifests

One Deployment + one Service per app. All images use a placeholder tag that Kustomize will patch.

### Files
- Create: `k8s/base/api-python/deployment.yaml`
- Create: `k8s/base/api-python/service.yaml`
- Create: `k8s/base/api-express/deployment.yaml`
- Create: `k8s/base/api-express/service.yaml`
- Create: `k8s/base/api-nest/deployment.yaml`
- Create: `k8s/base/api-nest/service.yaml`
- Create: `k8s/base/web/deployment.yaml`
- Create: `k8s/base/web/service.yaml`
- Create: `k8s/base/api-ingress.yaml`
- Create: `k8s/base/web-ingress.yaml`
- Create: `k8s/base/kustomization.yaml`
- Create: `k8s/overlays/prod/kustomization.yaml`

---

- [ ] **Step 1: Create the k8s directory structure**

```bash
mkdir -p k8s/base/api-python k8s/base/api-express k8s/base/api-nest k8s/base/web
mkdir -p k8s/overlays/prod
```

---

- [ ] **Step 2: api-python manifests**

Create `k8s/base/api-python/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-python
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-python
  template:
    metadata:
      labels:
        app: api-python
    spec:
      containers:
        - name: api-python
          image: api-python:latest
          ports:
            - containerPort: 8000
          readinessProbe:
            httpGet:
              path: /ping
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "250m"
              memory: "256Mi"
```

Create `k8s/base/api-python/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-python
spec:
  selector:
    app: api-python
  ports:
    - port: 8000
      targetPort: 8000
```

---

- [ ] **Step 3: api-express manifests**

Create `k8s/base/api-express/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-express
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-express
  template:
    metadata:
      labels:
        app: api-express
    spec:
      containers:
        - name: api-express
          image: api-express:latest
          ports:
            - containerPort: 3001
          env:
            - name: PYTHON_URL
              value: "http://api-python.default.svc.cluster.local:8000"
            - name: PORT
              value: "3001"
          readinessProbe:
            httpGet:
              path: /ping
              port: 3001
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
```

Create `k8s/base/api-express/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-express
spec:
  selector:
    app: api-express
  ports:
    - port: 3001
      targetPort: 3001
```

---

- [ ] **Step 4: api-nest manifests**

Create `k8s/base/api-nest/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-nest
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-nest
  template:
    metadata:
      labels:
        app: api-nest
    spec:
      containers:
        - name: api-nest
          image: api-nest:latest
          ports:
            - containerPort: 3000
          env:
            - name: EXPRESS_URL
              value: "http://api-express.default.svc.cluster.local:3001"
          readinessProbe:
            httpGet:
              path: /ping
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
```

Create `k8s/base/api-nest/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-nest
spec:
  selector:
    app: api-nest
  ports:
    - port: 3000
      targetPort: 3000
```

---

- [ ] **Step 5: web manifests**

Create `k8s/base/web/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: web:latest
          ports:
            - containerPort: 4000
          env:
            - name: NEST_URL
              value: "http://api-nest.default.svc.cluster.local:3000"
            - name: PORT
              value: "4000"
          readinessProbe:
            httpGet:
              path: /
              port: 4000
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: "100m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
```

Create `k8s/base/web/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 4000
      targetPort: 4000
```

---

- [ ] **Step 6: Nginx Ingress rules**

Two separate Ingress objects are required. `rewrite-target` is a per-Ingress annotation — putting
web and APIs in the same object would apply the strip-prefix rewrite to web paths too, corrupting
routes like `/about` → `//about`. Keep them separate.

Create `k8s/base/api-ingress.yaml`:

```yaml
# Strips /api/<service> prefix before forwarding to each backend.
# e.g. GET /api/nest/ping → GET /ping on api-nest:3000
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api/nest(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-nest
                port:
                  number: 3000
          - path: /api/express(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-express
                port:
                  number: 3001
          - path: /api/python(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-python
                port:
                  number: 8000
```

Create `k8s/base/web-ingress.yaml`:

```yaml
# No rewrite — web receives the full original path (/, /about, /contact, etc.)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 4000
```

---

- [ ] **Step 7: Base kustomization.yaml**

Create `k8s/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - api-python/deployment.yaml
  - api-python/service.yaml
  - api-express/deployment.yaml
  - api-express/service.yaml
  - api-nest/deployment.yaml
  - api-nest/service.yaml
  - web/deployment.yaml
  - web/service.yaml
  - api-ingress.yaml
  - web-ingress.yaml
```

---

- [ ] **Step 8: Prod overlay kustomization.yaml**

Create `k8s/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

# Image tags are patched by CI using: kustomize edit set image
# e.g.: kustomize edit set image api-nest=123456.dkr.ecr.us-east-1.amazonaws.com/api-nest:abc1234
images:
  - name: api-python
    newName: api-python
    newTag: latest
  - name: api-express
    newName: api-express
    newTag: latest
  - name: api-nest
    newName: api-nest
    newTag: latest
  - name: web
    newName: web
    newTag: latest
```

---

- [ ] **Step 9: Commit**

```bash
git add k8s/
git commit -m "feat: add Kubernetes base manifests and prod overlay (Kustomize)"
```

---

## Task 3: GitHub Actions Workflow

### Files
- Create: `.github/workflows/deploy.yml`

---

- [ ] **Step 1: Create the workflow directory**

```bash
mkdir -p .github/workflows
```

---

- [ ] **Step 2: Write the deploy workflow**

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write   # required for OIDC
  contents: write   # required to push updated overlay tags
  # NOTE: if your repo has branch protection requiring PRs, the git push below will fail.
  # Fix: go to Settings → Branches → add "github-actions[bot]" as a bypass actor,
  # OR store image tags somewhere outside branch protection (e.g. a separate unprotected branch).

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history needed for nx affected

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Run affected tests
        run: npx nx affected --base=origin/main~1 --head=HEAD --target=test --parallel=3
        # Note: on first push origin/main~1 won't exist — nx affected will test all, which is safe.

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Log in to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, push, and patch affected Docker images
        env:
          ECR_REGISTRY: ${{ secrets.ECR_REGISTRY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          SERVICES=("api-python" "api-express" "api-nest" "web")
          cd k8s/overlays/prod
          for svc in "${SERVICES[@]}"; do
            if npx nx show projects --affected --base=origin/main~1 --head=HEAD | grep -q "^${svc}$"; then
              echo "Building and pushing $svc..."
              cd $GITHUB_WORKSPACE
              docker build -t "$ECR_REGISTRY/$svc:$IMAGE_TAG" -f "apps/$svc/Dockerfile" .
              docker push "$ECR_REGISTRY/$svc:$IMAGE_TAG"
              cd k8s/overlays/prod
              kustomize edit set image "$svc=$ECR_REGISTRY/$svc:$IMAGE_TAG"
            else
              echo "Skipping $svc (not affected) — keeping existing image tag in overlay"
            fi
          done
          cd $GITHUB_WORKSPACE
          git config user.email "ci@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/prod/kustomization.yaml
          git diff --cached --quiet || git commit -m "ci: update image tags for $IMAGE_TAG [skip ci]"
          git push

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ secrets.EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}

      - name: Deploy to EKS
        run: kubectl apply -k k8s/overlays/prod

      - name: Wait for rollout
        run: |
          kubectl rollout status deployment/api-python --timeout=120s
          kubectl rollout status deployment/api-express --timeout=120s
          kubectl rollout status deployment/api-nest --timeout=120s
          kubectl rollout status deployment/web --timeout=120s
```

---

- [ ] **Step 3: Commit**

```bash
git add .github/
git commit -m "feat: add GitHub Actions deploy workflow (OIDC, nx affected, EKS deploy)"
```

---

## Task 4: Run One-Time AWS Setup (Terraform)

Do this manually before pushing to `main` for the first time. Terraform shows you exactly what it will create before doing anything — **always review the plan output before typing `yes`**.

---

- [ ] **Step 1: Install Terraform (if not installed)**

```bash
brew install terraform
terraform version
# Expected: Terraform v1.9.x or later
```

---

- [ ] **Step 2: Copy and fill in your tfvars**

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set github_repo to "your-org/nx-monorepo-boilerplate"
```

---

- [ ] **Step 3: Initialize Terraform**

```bash
cd infra/terraform
terraform init
```

Expected: providers downloaded, `.terraform/` directory created.

---

- [ ] **Step 4: Preview what will be created**

```bash
terraform plan
```

Expected: ~50 resources to add, 0 to change, 0 to destroy. **Read the output.** Look for anything unexpected before proceeding.

---

- [ ] **Step 5: Apply**

```bash
terraform apply
# Review the plan summary again, then type: yes
```

Expected (~15 minutes): VPC, EKS cluster, node group, ECR repos, IAM role, Nginx Ingress all created.

---

- [ ] **Step 6: Configure kubectl**

```bash
# Copy the command from Terraform output and run it:
$(terraform output -raw configure_kubectl)
kubectl get nodes
```

Expected: 2 nodes in `Ready` state.

---

- [ ] **Step 7: Add secrets to GitHub repository**

```bash
terraform output aws_role_arn
terraform output ecr_registry
terraform output cluster_name
```

Go to GitHub → repository → Settings → Secrets and variables → Actions → New repository secret. Add:
- `AWS_ROLE_ARN` → value from `terraform output aws_role_arn`
- `AWS_REGION` → `us-east-1` (or your chosen region)
- `ECR_REGISTRY` → value from `terraform output ecr_registry`
- `EKS_CLUSTER_NAME` → value from `terraform output cluster_name`

---

## Task 5: End-to-End Deploy Verification

- [ ] **Step 1: Push to main to trigger the pipeline**

```bash
git push origin main
```

---

- [ ] **Step 2: Monitor the GitHub Actions run**

Go to GitHub → Actions tab. Watch the deploy workflow. It should:
1. Run affected tests (all on first push — expected)
2. Build and push all 4 images to ECR
3. Deploy to EKS
4. Wait for rollouts to complete

---

- [ ] **Step 3: Verify pods are running**

```bash
kubectl get pods
```

Expected: 4 pods, all `Running` and `1/1 Ready`.

---

- [ ] **Step 4: Get the NLB external URL**

```bash
kubectl get ingress
```

Look at the `ADDRESS` column on either `api-ingress` or `web-ingress` — they share the same NLB. This is the NLB DNS name (e.g. `abc123.elb.amazonaws.com`).

---

- [ ] **Step 5: Test the echo chain via the NLB**

```bash
# Wait ~2 minutes for the NLB to become active after first creation
curl -s http://<NLB_ADDRESS>/api/nest/ping | jq .
```

Expected:
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

- [ ] **Step 6: Commit verification note**

```bash
git commit --allow-empty -m "chore: phase 2 complete — EKS deploy verified"
```

---

## Teardown

When done for the session, destroy all billable resources with a single command. Terraform shows a plan before destroying anything — review it before typing `yes`.

```bash
cd infra/terraform
terraform destroy
# Review the destruction plan, then type: yes
```

Expected: all resources removed in reverse-dependency order (~10 minutes). No manual cleanup needed.

---

## Phase 2 Done ✓

**Success criterion met when:** Push to `main` → GitHub Actions deploys → `curl http://<NLB>/api/nest/ping` returns the full nested chain.

**Cost reminder:** EKS costs ~$150/month while running. Run `terraform destroy` after each session.

**Next:** See `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md`
