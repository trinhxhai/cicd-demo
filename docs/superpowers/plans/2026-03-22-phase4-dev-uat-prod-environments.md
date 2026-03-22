# Dev / UAT / Prod Environments & Branch Strategy — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single-environment deployment into 3 environments (dev/local, UAT/EKS, prod/EKS) backed by a trunk-based branch strategy (`main → uat → prod`), separate Terraform workspaces, and dedicated GitHub Actions workflows per environment.

**Architecture:** A new `infra/terraform/prod/` directory (renamed from the current flat `infra/terraform/`) and a new `infra/terraform/uat/` directory provide isolated cluster infrastructure. A new `k8s/overlays/uat/` Kustomize overlay and three focused GitHub Actions workflows (`ci.yml`, `deploy-uat.yml`, `deploy-prod.yml`) replace the current monolithic `ci-cd.yml`. Images are built once in the UAT pipeline; the prod pipeline promotes those same image tags with no rebuild.

**Tech Stack:** Terraform (AWS EKS/VPC/IAM), Kustomize, GitHub Actions, Amazon ECR, kubectl

**Spec:** `docs/superpowers/specs/2026-03-22-dev-uat-prod-env-branch-strategy-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| `git mv` (each .tf file) | `infra/terraform/*.tf` → `infra/terraform/prod/*.tf` | Move prod infra into its own subdirectory |
| Modify | `infra/terraform/prod/versions.tf` | Annotate correct S3 backend key for prod state |
| Modify | `infra/terraform/prod/outputs.tf` | Update secret name hints to use `PROD_` prefix |
| Create | `infra/terraform/uat/versions.tf` | Providers + S3 backend key for UAT state |
| Create | `infra/terraform/uat/variables.tf` | Same variables as prod |
| Create | `infra/terraform/uat/vpc.tf` | VPC config (same CIDR, single NAT) |
| Create | `infra/terraform/uat/eks.tf` | UAT cluster — `t3.medium`, min 1 / max 2 nodes |
| Create | `infra/terraform/uat/iam.tf` | GitHub Actions OIDC role + Cluster Autoscaler role for UAT; references existing OIDC provider via data source |
| Create | `infra/terraform/uat/outputs.tf` | Secret name hints using `UAT_` prefix |
| Create | `infra/terraform/uat/terraform.tfvars.example` | UAT defaults |
| Create | `k8s/overlays/uat/kustomization.yaml` | UAT Kustomize overlay |
| Create | `.github/workflows/ci.yml` | Lint / test / build — triggered on PRs and push to `main` only |
| Create | `.github/workflows/deploy-uat.yml` | Build images → push ECR → deploy to UAT EKS |
| Create | `.github/workflows/deploy-prod.yml` | Promote UAT image tags → manual approval → deploy to prod EKS |
| Delete | `.github/workflows/ci-cd.yml` | Replaced by the three workflows above |
| Modify | `.gitignore` | Ensure `infra/terraform/uat/terraform.tfvars` is covered |

---

## Task 1: Move prod Terraform into subdirectory

**Files:**
- Rename: `infra/terraform/*.tf` → `infra/terraform/prod/`
- Rename: `infra/terraform/terraform.tfvars.example` → `infra/terraform/prod/`

- [ ] **Step 1: Create the prod subdirectory and move tracked files**

```bash
mkdir -p infra/terraform/prod
git mv infra/terraform/versions.tf infra/terraform/prod/
git mv infra/terraform/variables.tf infra/terraform/prod/
git mv infra/terraform/vpc.tf infra/terraform/prod/
git mv infra/terraform/eks.tf infra/terraform/prod/
git mv infra/terraform/ecr.tf infra/terraform/prod/
git mv infra/terraform/iam.tf infra/terraform/prod/
git mv infra/terraform/outputs.tf infra/terraform/prod/
git mv infra/terraform/terraform.tfvars.example infra/terraform/prod/
```

- [ ] **Step 2: Move gitignored files (not tracked by git)**

```bash
# terraform.tfvars is gitignored — move manually if it exists
[ -f infra/terraform/terraform.tfvars ] && mv infra/terraform/terraform.tfvars infra/terraform/prod/
# State files stay where they are (also gitignored) — Terraform will re-init
```

- [ ] **Step 3: Verify no .tf files remain in the old location**

```bash
ls infra/terraform/
# Expected: only the prod/ subdirectory (plus any *.tfstate* backup files)
# No *.tf files should remain here
```

- [ ] **Step 4: Update prod outputs.tf to use PROD_ prefixed secret names**

Edit `infra/terraform/prod/outputs.tf` — replace the description strings so the output hints match the new secret names:

```hcl
output "aws_role_arn" {
  description = "Add to GitHub secret: PROD_AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "ecr_registry" {
  description = "Add to GitHub secret: PROD_ECR_REGISTRY"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "cluster_name" {
  description = "Add to GitHub secret: PROD_EKS_CLUSTER_NAME"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
```

- [ ] **Step 5: Annotate the S3 backend key in prod versions.tf**

Edit `infra/terraform/prod/versions.tf` — update the commented-out backend block to show the correct prod key:

```hcl
  # Optional: uncomment to store state in S3 (recommended for teams)
  # Each environment MUST use a different key to prevent state collisions.
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "terraform/prod/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"   # optional, prevents concurrent applies
  # }
```

- [ ] **Step 6: Validate Terraform config still parses correctly**

```bash
cd infra/terraform/prod
terraform init -backend=false
terraform validate
# Expected: "Success! The configuration is valid."
cd ../../../
```

- [ ] **Step 7: Commit**

```bash
git add infra/terraform/prod/ infra/terraform/
git commit -m "refactor: move terraform files into infra/terraform/prod/ subdirectory"
```

---

## Task 2: Create UAT Terraform workspace

**Files:**
- Create: `infra/terraform/uat/versions.tf`
- Create: `infra/terraform/uat/variables.tf`
- Create: `infra/terraform/uat/vpc.tf`
- Create: `infra/terraform/uat/eks.tf`
- Create: `infra/terraform/uat/iam.tf`
- Create: `infra/terraform/uat/outputs.tf`
- Create: `infra/terraform/uat/terraform.tfvars.example`

- [ ] **Step 1: Create the uat directory**

```bash
mkdir -p infra/terraform/uat
```

- [ ] **Step 2: Create versions.tf**

`infra/terraform/uat/versions.tf`:
```hcl
terraform {
  required_version = ">= 1.5"

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
  # Each environment MUST use a different key to prevent state collisions.
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "terraform/uat/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"   # optional, prevents concurrent applies
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

- [ ] **Step 3: Create variables.tf** (identical to prod)

`infra/terraform/uat/variables.tf`:
```hcl
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "nx-monorepo-uat"
}

variable "github_repo" {
  description = "GitHub repo in owner/repo format (e.g. myorg/nx-monorepo-boilerplate)"
  type        = string
}
```

- [ ] **Step 4: Create vpc.tf** (identical to prod)

`infra/terraform/uat/vpc.tf`:
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
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
```

- [ ] **Step 5: Create eks.tf** (smaller nodes for UAT)

`infra/terraform/uat/eks.tf`:
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
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      disk_size      = 20
    }
  }

  enable_cluster_creator_admin_permissions = true
}

# Nginx Ingress Controller
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

- [ ] **Step 6: Create iam.tf for UAT**

Key differences from prod:
- The GitHub Actions OIDC provider already exists in the AWS account (created by prod). Reference it via a data source — do NOT create it again.
- All IAM role and policy names use a `-uat` suffix to avoid name collisions with prod.

`infra/terraform/uat/iam.tf`:
```hcl
data "aws_caller_identity" "current" {}

# Reference the existing GitHub Actions OIDC provider — do NOT create it here.
# AWS allows only one OIDC provider per URL per account.
# The provider is managed by infra/terraform/prod/iam.tf.
data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-eks-uat"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_policy" "github_actions_eks_describe" {
  name = "github-actions-eks-describe-uat"

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

# Cluster Autoscaler IRSA role
data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "cluster-autoscaler-uat"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler-uat"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Cluster Autoscaler service account (UAT)"
  value       = aws_iam_role.cluster_autoscaler.arn
}
```

- [ ] **Step 7: Create outputs.tf for UAT**

`infra/terraform/uat/outputs.tf`:
```hcl
output "aws_role_arn" {
  description = "Add to GitHub secret: UAT_AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "ecr_registry" {
  description = "Add to GitHub secret: UAT_ECR_REGISTRY"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "cluster_name" {
  description = "Add to GitHub secret: UAT_EKS_CLUSTER_NAME"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for UAT"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}
```

- [ ] **Step 8: Create terraform.tfvars.example for UAT**

`infra/terraform/uat/terraform.tfvars.example`:
```hcl
aws_region   = "us-east-1"
cluster_name = "nx-monorepo-uat"
github_repo  = "your-org/nx-monorepo-boilerplate"
```

- [ ] **Step 9: Update .gitignore to cover UAT and prod terraform secrets**

The `.gitignore` has no Terraform entries at all. Add pattern-based rules to cover both environments:

Open `.gitignore` and add:
```
# Terraform — local secrets and state (never commit these)
**/terraform.tfvars
**/terraform.tfstate
**/terraform.tfstate*
**/.terraform/
```

Verify:
```bash
git check-ignore -v infra/terraform/uat/terraform.tfvars
# Expected: .gitignore:<line>:**/terraform.tfvars  infra/terraform/uat/terraform.tfvars
git check-ignore -v infra/terraform/prod/terraform.tfvars
# Expected: .gitignore:<line>:**/terraform.tfvars  infra/terraform/prod/terraform.tfvars
```

- [ ] **Step 10: Validate UAT Terraform config**

```bash
cd infra/terraform/uat
terraform init -backend=false
terraform validate
# Expected: "Success! The configuration is valid."
cd ../../../
```

- [ ] **Step 11: Commit**

```bash
git add infra/terraform/uat/ .gitignore infra/terraform/prod/
git commit -m "feat: add UAT Terraform workspace (separate EKS cluster, isolated IAM)"
```

---

## Task 3: Create UAT Kubernetes overlay

**Files:**
- Create: `k8s/overlays/uat/kustomization.yaml`

- [ ] **Step 1: Create the UAT overlay directory**

```bash
mkdir -p k8s/overlays/uat
```

- [ ] **Step 2: Create kustomization.yaml**

`k8s/overlays/uat/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

# IMPORTANT: Do not apply this overlay manually before the UAT deploy pipeline has run.
# The image names below are placeholders. The deploy-uat.yml pipeline patches them to full ECR URIs:
#   kustomize edit set image api-nest=<ECR_REGISTRY>/api-nest:<SHA>
# Applying before the pipeline runs will cause ImagePullBackOff.
images:
  - name: api-python
    newName: YOUR_ECR_REGISTRY/api-python
    newTag: latest
  - name: api-express
    newName: YOUR_ECR_REGISTRY/api-express
    newTag: latest
  - name: api-nest
    newName: YOUR_ECR_REGISTRY/api-nest
    newTag: latest
  - name: web
    newName: YOUR_ECR_REGISTRY/web
    newTag: latest
```

- [ ] **Step 3: Verify the overlay can be rendered against base**

```bash
kubectl kustomize k8s/overlays/uat --dry-run 2>&1 | head -5
# OR if kubectl kustomize isn't available:
kustomize build k8s/overlays/uat | head -20
# Expected: YAML output with placeholder image names — no errors
```

- [ ] **Step 4: Commit**

```bash
git add k8s/overlays/uat/
git commit -m "feat: add k8s UAT overlay (kustomize, placeholder image tags)"
```

---

## Task 4: Create ci.yml — pure CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

This is the CI job extracted from `ci-cd.yml`. It runs on PRs to any branch and pushes to `main` only. It does no deployment.

- [ ] **Step 1: Create ci.yml**

`.github/workflows/ci.yml`:
```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore:
      - '**.md'
      - 'docs/**'
  pull_request:
    paths-ignore:
      - '**.md'
      - 'docs/**'

jobs:
  ci:
    runs-on: ubuntu-latest
    permissions:
      actions: read
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - run: npm ci

      - run: pip install -r apps/api-python/requirements.txt

      - run: npx nx run-many -t lint test build typecheck
```

Note: `push` trigger is limited to `main` only. Pushes to `uat` and `prod` are handled exclusively by their respective deploy workflows.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "feat: add ci.yml — pure CI workflow (lint, test, build, typecheck)"
```

---

## Task 5: Create deploy-uat.yml — build and deploy to UAT

**Files:**
- Create: `.github/workflows/deploy-uat.yml`

Triggered on push to `uat` branch. Builds Docker images for affected services, pushes to ECR, scans with Trivy, patches the UAT overlay, and deploys to the UAT EKS cluster.

- [ ] **Step 1: Create deploy-uat.yml**

`.github/workflows/deploy-uat.yml`:
```yaml
name: Deploy UAT

on:
  push:
    branches: [uat]
    paths-ignore:
      - '**.md'
      - 'docs/**'
  workflow_dispatch:
    inputs:
      force_all:
        description: 'Force rebuild and deploy all services (skip affected check)'
        type: boolean
        default: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: uat
    permissions:
      id-token: write   # required for OIDC
      contents: write   # required to push updated overlay tags
      actions: read     # required to query last successful deploy run
    env:
      AWS_REGION: ${{ secrets.AWS_REGION }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.UAT_AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Install dependencies
        run: npm ci

      - name: Log in to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Resolve affected base SHA
        id: base-sha
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          LAST_SUCCESS=$(gh run list \
            --workflow=deploy-uat.yml \
            --branch=uat \
            --status=success \
            --limit=1 \
            --json headSha \
            -q '.[0].headSha' 2>/dev/null || echo "")
          if [ -n "$LAST_SUCCESS" ] && git cat-file -t "$LAST_SUCCESS" &>/dev/null; then
            echo "base=$LAST_SUCCESS" >> $GITHUB_OUTPUT
            echo "Base SHA from last successful UAT deploy: $LAST_SUCCESS"
          else
            FALLBACK=$(git rev-parse origin/uat~1 2>/dev/null || echo "HEAD")
            echo "base=$FALLBACK" >> $GITHUB_OUTPUT
            echo "No previous successful UAT deploy found, falling back to: $FALLBACK"
          fi

      - name: Install Trivy
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

      - name: Build, push, scan, and patch affected Docker images
        env:
          ECR_REGISTRY: ${{ secrets.UAT_ECR_REGISTRY }}
          IMAGE_TAG: ${{ github.sha }}
          BASE_SHA: ${{ steps.base-sha.outputs.base }}
          FORCE_ALL: ${{ inputs.force_all }}
        run: |
          SERVICES=("api-python" "api-express" "api-nest" "web")
          if [ "$FORCE_ALL" = "true" ]; then
            echo "Force-all enabled — rebuilding all services"
            AFFECTED=$(printf '%s\n' "${SERVICES[@]}")
          else
            AFFECTED=$(npx nx show projects --affected --base=$BASE_SHA --head=HEAD)
            echo "Affected projects since $BASE_SHA: $AFFECTED"
          fi
          cd k8s/overlays/uat
          for svc in "${SERVICES[@]}"; do
            if echo "$AFFECTED" | grep -qE "(^|/)${svc}$"; then
              echo "Building and pushing $svc..."
              cd $GITHUB_WORKSPACE
              docker build -t "$ECR_REGISTRY/$svc:$IMAGE_TAG" -f "apps/$svc/Dockerfile" .
              docker push "$ECR_REGISTRY/$svc:$IMAGE_TAG"
              echo "Scanning $svc for vulnerabilities..."
              trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed "$ECR_REGISTRY/$svc:$IMAGE_TAG"
              cd k8s/overlays/uat
              kustomize edit set image "$svc=$ECR_REGISTRY/$svc:$IMAGE_TAG"
            else
              echo "Skipping $svc (not affected) — keeping existing image tag"
            fi
          done
          cd $GITHUB_WORKSPACE
          git config user.email "ci@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/uat/kustomization.yaml
          git diff --cached --quiet || git commit -m "ci: update UAT image tags for $IMAGE_TAG [skip ci]"
          # Retry loop handles concurrent pushes to uat (e.g. two PRs merged close together)
          for i in 1 2 3; do
            git pull --rebase origin uat && git push && break
            echo "Push attempt $i failed — retrying in 5s"
            sleep 5
          done

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ secrets.UAT_EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}

      - name: Deploy to UAT EKS
        run: kubectl apply -k k8s/overlays/uat

      - name: Wait for rollout
        run: |
          kubectl rollout status deployment/api-python --timeout=120s
          kubectl rollout status deployment/api-express --timeout=120s
          kubectl rollout status deployment/api-nest --timeout=120s
          kubectl rollout status deployment/web --timeout=120s
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/deploy-uat.yml
git commit -m "feat: add deploy-uat.yml — build images and deploy to UAT EKS on uat branch push"
```

---

## Task 6: Create deploy-prod.yml — promote UAT images to prod

**Files:**
- Create: `.github/workflows/deploy-prod.yml`

Triggered on push to `prod` branch. **No Docker build.** Reads image tags that were committed to `k8s/overlays/uat/kustomization.yaml` by the UAT pipeline (the file is present on the `prod` branch because the PR `uat → prod` carries it), writes them to `k8s/overlays/prod/kustomization.yaml`, then deploys to the prod EKS cluster after manual approval.

- [ ] **Step 1: Create deploy-prod.yml**

`.github/workflows/deploy-prod.yml`:
```yaml
name: Deploy Prod

on:
  push:
    branches: [prod]
    paths-ignore:
      - '**.md'
      - 'docs/**'
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production   # pauses here until a required reviewer approves in GitHub Actions UI
    permissions:
      id-token: write   # required for OIDC
      contents: write   # required to push updated overlay tags
      actions: read
    env:
      AWS_REGION: ${{ secrets.AWS_REGION }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Install yq
        run: |
          wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
          chmod +x /usr/local/bin/yq

      - name: Promote UAT image tags to prod overlay
        run: |
          # No Docker build — read the exact image tags deployed to UAT and apply to prod.
          # k8s/overlays/uat/kustomization.yaml was committed by deploy-uat.yml and is
          # present on this branch because the uat→prod PR merge carried it.
          SERVICES=("api-python" "api-express" "api-nest" "web")
          cd k8s/overlays/prod
          for svc in "${SERVICES[@]}"; do
            NEW_NAME=$(yq eval ".images[] | select(.name == \"$svc\") | .newName" $GITHUB_WORKSPACE/k8s/overlays/uat/kustomization.yaml)
            NEW_TAG=$(yq eval ".images[] | select(.name == \"$svc\") | .newTag" $GITHUB_WORKSPACE/k8s/overlays/uat/kustomization.yaml)
            if [ -n "$NEW_TAG" ] && [ "$NEW_TAG" != "null" ]; then
              echo "Promoting $svc → $NEW_NAME:$NEW_TAG"
              kustomize edit set image "$svc=$NEW_NAME:$NEW_TAG"
            else
              echo "No tag found for $svc in UAT overlay — skipping"
            fi
          done
          cd $GITHUB_WORKSPACE
          git config user.email "ci@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/prod/kustomization.yaml
          git diff --cached --quiet || git commit -m "ci: promote UAT image tags to prod [skip ci]"
          # Retry loop handles edge case of concurrent pushes to prod
          for i in 1 2 3; do
            git pull --rebase origin prod && git push && break
            echo "Push attempt $i failed — retrying in 5s"
            sleep 5
          done

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ secrets.PROD_EKS_CLUSTER_NAME }} --region ${{ env.AWS_REGION }}

      - name: Deploy to prod EKS
        run: kubectl apply -k k8s/overlays/prod

      - name: Wait for rollout
        run: |
          kubectl rollout status deployment/api-python --timeout=120s
          kubectl rollout status deployment/api-express --timeout=120s
          kubectl rollout status deployment/api-nest --timeout=120s
          kubectl rollout status deployment/web --timeout=120s
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/deploy-prod.yml
git commit -m "feat: add deploy-prod.yml — promote UAT image tags to prod with manual approval gate"
```

---

## Task 7: Delete ci-cd.yml

**Files:**
- Delete: `.github/workflows/ci-cd.yml`

- [ ] **Step 1: Delete the old monolithic workflow**

```bash
git rm .github/workflows/ci-cd.yml
```

- [ ] **Step 2: Verify three new workflows exist**

```bash
ls .github/workflows/
# Expected: ci.yml  deploy-uat.yml  deploy-prod.yml
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: delete ci-cd.yml — replaced by ci.yml, deploy-uat.yml, deploy-prod.yml"
```

---

## Task 8: Create uat and prod long-lived branches

- [ ] **Step 1: Create the uat branch from main**

```bash
git checkout -b uat
git push -u origin uat
git checkout main
```

- [ ] **Step 2: Create the prod branch from main**

```bash
git checkout -b prod
git push -u origin prod
git checkout main
```

- [ ] **Step 3: Verify both branches exist on remote**

```bash
git branch -r | grep -E "uat|prod"
# Expected: origin/uat and origin/prod
```

- [ ] **Step 4: Commit (nothing to commit — branches are already pushed)**

No file changes needed. The branches are created above.

---

## Task 9: Manual setup checklist (GitHub repository settings)

These steps must be done manually in the GitHub repository UI — they cannot be scripted without a GitHub token.

- [ ] **Step 1: Create GitHub environments**

Go to: repo → Settings → Environments → New environment

| Environment name | Protection rules |
|-----------------|-----------------|
| `uat` | None (leave empty — auto-deploys) |
| `production` | Required reviewers: add yourself (or your team lead) |

> The `deploy-prod.yml` references `environment: production` — this name must match exactly.

- [ ] **Step 2: Add branch protection rules**

Go to: repo → Settings → Branches → Add rule

| Branch | Settings |
|--------|---------|
| `main` | ✅ Require a pull request before merging; ✅ Require status checks (select the `ci` job); ✅ Restrict who can push directly (no direct push) |
| `uat` | ✅ Require a pull request before merging; add `github-actions[bot]` as a **bypass actor** (so the deploy workflow can push updated kustomization.yaml) |
| `prod` | ✅ Require a pull request before merging; add `github-actions[bot]` as a **bypass actor** |

> Bypass actor location: Edit rule → "Allow specified actors to bypass required pull requests" → add `github-actions[bot]`

- [ ] **Step 3: Migrate GitHub secrets**

Go to: repo → Settings → Secrets and variables → Actions

**Delete old secrets** (no longer referenced by any workflow):
- `AWS_ROLE_ARN`
- `ECR_REGISTRY`
- `EKS_CLUSTER_NAME`

**Create new secrets** (values come from `terraform output` after each cluster is provisioned):

| Secret | Value source |
|--------|-------------|
| `AWS_REGION` | e.g. `us-east-1` (may already exist) |
| `UAT_AWS_ROLE_ARN` | `cd infra/terraform/uat && terraform output aws_role_arn` |
| `UAT_ECR_REGISTRY` | `cd infra/terraform/uat && terraform output ecr_registry` |
| `UAT_EKS_CLUSTER_NAME` | `cd infra/terraform/uat && terraform output cluster_name` |
| `PROD_AWS_ROLE_ARN` | `cd infra/terraform/prod && terraform output aws_role_arn` |
| `PROD_ECR_REGISTRY` | `cd infra/terraform/prod && terraform output ecr_registry` |
| `PROD_EKS_CLUSTER_NAME` | `cd infra/terraform/prod && terraform output cluster_name` |

> Note: UAT and prod share the same ECR registry URL (same AWS account). `UAT_ECR_REGISTRY` and `PROD_ECR_REGISTRY` will have the same value. Both secrets are kept separate so they can diverge if accounts are ever split.

- [ ] **Step 4: Final smoke test — push to uat**

> **PREREQUISITE:** Complete Steps 1, 2, and 3 of this task (GitHub environments, branch protection bypass actors, and secrets) BEFORE pushing. If branch protection is active without the `github-actions[bot]` bypass actor, the deploy workflow will fail when it tries to push the updated `kustomization.yaml` back to the `uat` branch.

```bash
git checkout uat
# Make a trivial change to trigger the pipeline
echo "# UAT branch initialized" >> README.md
git add README.md
git commit -m "chore: initialize uat branch"
git push origin uat
```

Go to GitHub Actions and verify `deploy-uat.yml` triggers and runs successfully.

---

## Summary

After all tasks are complete:

```
Branches:    main ──PR──▶ uat ──PR──▶ prod
Infra:       infra/terraform/prod/  +  infra/terraform/uat/
K8s:         k8s/overlays/prod/     +  k8s/overlays/uat/
Workflows:   ci.yml  |  deploy-uat.yml  |  deploy-prod.yml
```

- Feature work: branch from `main`, PR back to `main`
- Promote to UAT: PR `main → uat` → auto-deploys
- Promote to prod: PR `uat → prod` → manual approval → deploys same image SHA
