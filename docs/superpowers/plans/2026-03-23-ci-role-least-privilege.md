# CI Role Least-Privilege Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace cluster-admin CI roles with namespace-scoped edit roles and move cluster-autoscaler from kustomize to Terraform Helm.

**Architecture:** IAM access policy association updated from `AmazonEKSClusterAdminPolicy` (cluster scope) to `AmazonEKSEditPolicy` (namespace `default`) in both UAT and prod. Cluster-autoscaler relocated from `k8s/base/cluster-autoscaler.yaml` (applied by CI) to a Terraform `helm_release` resource (applied by `terraform apply`) so CI never needs `kube-system` access. Kustomize base cleaned up once both clusters are Helm-managed.

**Tech Stack:** Terraform (HCL), AWS EKS access entries, Helm (cluster-autoscaler chart), kubectl, kustomize

---

## File Map

| Action | Path | Purpose |
|--------|------|---------|
| Modify | `infra/terraform/uat/iam.tf:68-76` | Swap to AmazonEKSEditPolicy, namespace scope |
| Create | `infra/terraform/uat/helm.tf` | Helm-managed cluster-autoscaler for UAT |
| Modify | `infra/terraform/prod/iam.tf:86-94` | Swap to AmazonEKSEditPolicy, namespace scope |
| Create | `infra/terraform/prod/helm.tf` | Helm-managed cluster-autoscaler for prod |
| Modify | `k8s/base/kustomization.yaml` | Remove cluster-autoscaler.yaml entry |
| Delete | `k8s/base/cluster-autoscaler.yaml` | Replaced by Helm |
| Delete | `k8s/base/metrics-server.yaml` | Documentation placeholder — not in kustomization.yaml, safe to remove |

---

## Task 1: UAT Terraform — update IAM policy

**Files:**
- Modify: `infra/terraform/uat/iam.tf:68-76`

- [ ] **Step 1: Edit uat/iam.tf — replace the access policy association**

  In `infra/terraform/uat/iam.tf`, replace lines 68–76:

  ```hcl
  # Before
  resource "aws_eks_access_policy_association" "github_actions_admin" {
    cluster_name  = module.eks.cluster_name
    principal_arn = aws_iam_role.github_actions.arn
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
      type = "cluster"
    }
  }
  ```

  Replace with:

  ```hcl
  resource "aws_eks_access_policy_association" "github_actions_admin" {
    cluster_name  = module.eks.cluster_name
    principal_arn = aws_iam_role.github_actions.arn
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

    access_scope {
      type       = "namespace"
      namespaces = ["default"]
    }
  }
  ```

- [ ] **Step 2: Initialize Terraform**

  ```bash
  cd infra/terraform/uat
  terraform init
  ```

  Expected: `Terraform has been successfully initialized!`

- [ ] **Step 3: Preview the change**

  ```bash
  terraform plan
  ```

  Expected output includes:
  ```
  # aws_eks_access_policy_association.github_actions_admin must be replaced
  ~ policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  + policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  ```

- [ ] **Step 4: Commit**

  ```bash
  cd ../../..
  git add infra/terraform/uat/iam.tf
  git commit -m "feat(uat): scope CI role to default namespace (AmazonEKSEditPolicy)"
  ```

---

## Task 2: UAT Terraform — add Helm-managed cluster-autoscaler

**Files:**
- Create: `infra/terraform/uat/helm.tf`

- [ ] **Step 1: Create `infra/terraform/uat/helm.tf`**

  ```hcl
  resource "helm_release" "cluster_autoscaler" {
    name       = "cluster-autoscaler"
    repository = "https://kubernetes.github.io/autoscaler"
    chart      = "cluster-autoscaler"
    namespace  = "kube-system"

    set {
      name  = "autoDiscovery.clusterName"
      value = module.eks.cluster_name
    }

    set {
      name  = "awsRegion"
      value = var.aws_region
    }

    set {
      name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.cluster_autoscaler.arn
    }

    # Must match the IRSA trust policy: system:serviceaccount:kube-system:cluster-autoscaler
    # Do not change without also updating aws_iam_role.cluster_autoscaler
    set {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    }
  }
  ```

- [ ] **Step 2: Preview**

  ```bash
  cd infra/terraform/uat
  terraform plan
  ```

  Expected: `helm_release.cluster_autoscaler` will be created.

- [ ] **Step 3: Commit**

  ```bash
  cd ../../..
  git add infra/terraform/uat/helm.tf
  git commit -m "feat(uat): add Helm-managed cluster-autoscaler"
  ```

---

## Task 3: Prod Terraform — update IAM policy

**Files:**
- Modify: `infra/terraform/prod/iam.tf:86-94`

- [ ] **Step 1: Edit prod/iam.tf — replace the access policy association**

  In `infra/terraform/prod/iam.tf`, replace lines 83–94 (including the stale comment block):

  ```hcl
  # Before — lines 83–94
  # SECURITY NOTE: AmazonEKSClusterAdminPolicy grants full cluster admin to GitHub Actions.
  # For a demo/learning project this is acceptable. For a production environment, replace with
  # a namespace-scoped policy (AmazonEKSEditPolicy) to limit blast radius.
  resource "aws_eks_access_policy_association" "github_actions_admin" {
    cluster_name  = module.eks.cluster_name
    principal_arn = aws_iam_role.github_actions.arn
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
      type = "cluster"
    }
  }
  ```

  Replace with:

  ```hcl
  resource "aws_eks_access_policy_association" "github_actions_admin" {
    cluster_name  = module.eks.cluster_name
    principal_arn = aws_iam_role.github_actions.arn
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

    access_scope {
      type       = "namespace"
      namespaces = ["default"]
    }
  }
  ```

- [ ] **Step 2: Initialize Terraform**

  ```bash
  cd infra/terraform/prod
  terraform init
  ```

  Expected: `Terraform has been successfully initialized!`

- [ ] **Step 3: Preview**

  ```bash
  terraform plan
  ```

  Expected: `github_actions_admin` must be replaced.

- [ ] **Step 4: Commit**

  ```bash
  cd ../../..
  git add infra/terraform/prod/iam.tf
  git commit -m "feat(prod): scope CI role to default namespace (AmazonEKSEditPolicy)"
  ```

---

## Task 4: Prod Terraform — add Helm-managed cluster-autoscaler

**Files:**
- Create: `infra/terraform/prod/helm.tf`

- [ ] **Step 1: Create `infra/terraform/prod/helm.tf`**

  ```hcl
  resource "helm_release" "cluster_autoscaler" {
    name       = "cluster-autoscaler"
    repository = "https://kubernetes.github.io/autoscaler"
    chart      = "cluster-autoscaler"
    namespace  = "kube-system"

    set {
      name  = "autoDiscovery.clusterName"
      value = module.eks.cluster_name
    }

    set {
      name  = "awsRegion"
      value = var.aws_region
    }

    set {
      name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.cluster_autoscaler.arn
    }

    # Must match the IRSA trust policy: system:serviceaccount:kube-system:cluster-autoscaler
    # Do not change without also updating aws_iam_role.cluster_autoscaler
    set {
      name  = "rbac.serviceAccount.name"
      value = "cluster-autoscaler"
    }
  }
  ```

- [ ] **Step 2: Initialize Terraform**

  ```bash
  cd infra/terraform/prod
  terraform init
  ```

  Expected: `Terraform has been successfully initialized!`

- [ ] **Step 3: Preview**

  ```bash
  terraform plan
  ```

  Expected: `helm_release.cluster_autoscaler` will be created.

- [ ] **Step 3: Commit**

  ```bash
  cd ../../..
  git add infra/terraform/prod/helm.tf
  git commit -m "feat(prod): add Helm-managed cluster-autoscaler"
  ```

---

## Task 5: Apply UAT — cluster prep and terraform apply

> **Important:** Cluster autoscaling is unavailable from step 1 until step 2 completes. Do this during low-traffic periods.
> **Important:** Ensure no UAT deploy workflow is running before step 2 (the IAM policy delete+recreate creates a ~second gap where CI has no EKS policy).

**Files:** (live cluster — no file changes)

- [ ] **Step 1: Connect to UAT cluster**

  ```bash
  aws eks update-kubeconfig --name <UAT_EKS_CLUSTER_NAME> --region <AWS_REGION>
  ```

  Verify you're on the right cluster:
  ```bash
  kubectl config current-context
  ```

- [ ] **Step 2: Delete existing kustomize-managed cluster-autoscaler**

  ```bash
  kubectl delete -f k8s/base/cluster-autoscaler.yaml
  ```

  Expected (6 resources deleted):
  ```
  serviceaccount "cluster-autoscaler" deleted
  clusterrole.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  role.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  rolebinding.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  clusterrolebinding.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  deployment.apps "cluster-autoscaler" deleted
  ```

- [ ] **Step 3: Apply UAT Terraform**

  ```bash
  cd infra/terraform/uat
  terraform apply
  ```

  Type `yes` when prompted. Expected: `helm_release.cluster_autoscaler` created, `aws_eks_access_policy_association.github_actions_admin` replaced.

- [ ] **Step 4: Verify cluster-autoscaler is running**

  ```bash
  kubectl get deployment -n kube-system cluster-autoscaler
  ```

  Expected: `READY 1/1`. May take ~30 seconds to come up.

- [ ] **Step 5: Check autoscaler logs for errors**

  ```bash
  kubectl logs -n kube-system deployment/cluster-autoscaler --tail=20
  ```

  Expected: no `ERROR` lines, autoscaler reports watching the cluster.

---

## Task 6: Apply Prod — cluster prep and terraform apply

> **Important:** Same windows as UAT — low-traffic period, no active prod deploy workflow.

**Files:** (live cluster — no file changes)

- [ ] **Step 1: Connect to prod cluster**

  ```bash
  aws eks update-kubeconfig --name <PROD_EKS_CLUSTER_NAME> --region <AWS_REGION>
  ```

  Verify:
  ```bash
  kubectl config current-context
  ```

- [ ] **Step 2: Delete existing kustomize-managed cluster-autoscaler**

  > Note: `k8s/base/cluster-autoscaler.yaml` still exists in the repo at this point — do NOT delete the file before running this command.

  ```bash
  kubectl delete -f k8s/base/cluster-autoscaler.yaml
  ```

  Expected (6 resources deleted):
  ```
  serviceaccount "cluster-autoscaler" deleted
  clusterrole.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  role.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  rolebinding.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  clusterrolebinding.rbac.authorization.k8s.io "cluster-autoscaler" deleted
  deployment.apps "cluster-autoscaler" deleted
  ```

- [ ] **Step 3: Apply prod Terraform**

  ```bash
  cd infra/terraform/prod
  terraform apply
  ```

  Type `yes`. Expected: same as UAT.

- [ ] **Step 4: Verify cluster-autoscaler is running**

  ```bash
  kubectl get deployment -n kube-system cluster-autoscaler
  ```

  Expected: `READY 1/1`.

---

## Task 7: Kustomize cleanup and final verification

> Both clusters now have Helm-managed autoscalers. Safe to remove the kustomize files.

**Files:**
- Modify: `k8s/base/kustomization.yaml`
- Delete: `k8s/base/cluster-autoscaler.yaml`
- Delete: `k8s/base/metrics-server.yaml`

- [ ] **Step 1: Remove cluster-autoscaler.yaml from kustomization.yaml**

  In `k8s/base/kustomization.yaml`, remove this line:
  ```yaml
    - cluster-autoscaler.yaml
  ```

  The file should contain 12 resource entries after this change (was 13).

- [ ] **Step 2: Delete the files**

  ```bash
  rm k8s/base/cluster-autoscaler.yaml
  rm k8s/base/metrics-server.yaml
  ```

- [ ] **Step 3: Verify kustomize build still works**

  ```bash
  kubectl kustomize k8s/overlays/uat
  kubectl kustomize k8s/overlays/prod
  ```

  Expected: YAML output for all 4 services, no errors, no mention of cluster-autoscaler.

- [ ] **Step 4: Commit and push**

  ```bash
  git add k8s/base/kustomization.yaml
  git rm k8s/base/cluster-autoscaler.yaml
  git rm k8s/base/metrics-server.yaml
  git commit -m "chore: remove cluster-autoscaler and metrics-server from kustomize base"
  git push
  ```

  This push triggers the UAT deploy workflow under the new namespace-scoped role.

- [ ] **Step 5: Verify UAT deploy workflow passes**

  Watch the `Deploy UAT` workflow in GitHub Actions. It should complete without permission errors. The `kubectl apply -k k8s/overlays/uat` step is the key one — it now runs under `AmazonEKSEditPolicy` scoped to `default`.

- [ ] **Step 6: Verify prod deploy workflow passes**

  Trigger the `Deploy Prod` workflow manually (or via the normal branch promotion process) and confirm it completes without errors.

- [ ] **Step 7: Final permission check (optional but recommended)**

  Get the CI role's assumed-role ARN format. In the workflow logs, find the `Configure AWS credentials` step output — it shows the assumed role session. Then:

  ```bash
  # Replace ACCOUNT_ID with your AWS account ID (514453840552)
  # Should return yes
  kubectl auth can-i create deployment -n default \
    --as=arn:aws:sts::514453840552:assumed-role/github-actions-eks/GitHubActions

  # Should return no
  kubectl auth can-i create deployment -n kube-system \
    --as=arn:aws:sts::514453840552:assumed-role/github-actions-eks/GitHubActions
  ```
