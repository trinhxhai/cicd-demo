# CI Role Least-Privilege Design

*Date: 2026-03-23*

## Problem

Both UAT and prod GitHub Actions roles are granted `AmazonEKSClusterAdminPolicy` with cluster-wide scope. A CI compromise gives an attacker full cluster admin: they can read all Secrets across namespaces, exec into any pod, delete all workloads, create privileged pods to escape to EC2 nodes, and pivot to the node's IAM role.

## Goal

Scope CI to the minimum permissions needed to deploy app workloads: CRUD on resources in the `default` namespace only.

## What CI Actually Needs

The deploy workflows do three things:
1. `aws eks update-kubeconfig` — requires `eks:DescribeCluster` (already correctly scoped)
2. `kubectl apply -k k8s/overlays/{env}` — requires write access to Deployments, Services, ConfigMaps, Secrets, HPA, PDB, Ingress in `default`
3. `kubectl rollout status deployment/...` — requires read access to Deployments in `default`

`AmazonEKSEditPolicy` scoped to `default` covers all of this. It explicitly blocks cluster-level resources (Nodes, ClusterRoles, Namespaces, PersistentVolumes).

## Changes

### 1. IAM — both `uat/iam.tf` and `prod/iam.tf`

Replace `AmazonEKSClusterAdminPolicy` (cluster scope) with `AmazonEKSEditPolicy` (namespace scope).

Note: EKS does not permit updating an access policy association in-place — Terraform will delete then recreate it, creating a ~second window where the CI role has no EKS policy. Run `terraform apply` only when no deploy workflow is actively running.

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

### 2. Cluster Autoscaler — move from kustomize to Terraform Helm

The base kustomize includes `cluster-autoscaler.yaml` which deploys to `kube-system`. The new namespace-scoped CI role cannot write to `kube-system`, so the cluster-autoscaler must be managed by Terraform instead.

The `helm` provider is already declared in both `uat/versions.tf` and `prod/versions.tf` — no provider changes needed.

Add `helm.tf` to both `infra/terraform/uat/` and `infra/terraform/prod/`:

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

  # Must match the service account name in the IRSA trust policy.
  # The existing trust policy binds to system:serviceaccount:kube-system:cluster-autoscaler.
  # Do not change this value without updating aws_iam_role.cluster_autoscaler.
  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }
}
```

The existing IRSA role (`aws_iam_role.cluster_autoscaler`) is unchanged. The Helm chart creates its own ServiceAccount, ClusterRole, and Deployment, replacing the manually managed `k8s/base/cluster-autoscaler.yaml`.

If `terraform init` has not been run since the `helm` provider was added to `versions.tf`, run it before `terraform apply` to ensure the provider is downloaded and the lock file is up to date.

### 3. Kustomize cleanup

In `k8s/base/kustomization.yaml`, remove the `cluster-autoscaler.yaml` entry and delete the file.

Also delete `k8s/base/metrics-server.yaml` from the repo — it is only a documentation placeholder (a ConfigMap recording the install command) and is not listed in `kustomization.yaml`, so no kustomization edit is needed for it.

## Rollout Order

The Helm chart will conflict with the existing kustomize-owned `kube-system` resources if both exist simultaneously. The kustomize resources must be removed from the cluster before Terraform creates the Helm-managed ones.

**Per environment (UAT first, then prod):**

1. Delete the existing cluster-autoscaler resources from the cluster. Note: cluster autoscaling is unavailable from this point until step 2 completes — schedule during low-traffic periods.
   ```bash
   kubectl delete -f k8s/base/cluster-autoscaler.yaml
   ```

2. Run `terraform apply` in the environment workspace — this creates the Helm-managed cluster-autoscaler and narrows the IAM policy. Ensure no deploy workflow is running at this moment (the IAM policy association delete+recreate creates a ~second gap where CI has no EKS policy).

3. Verify cluster-autoscaler is running:
   ```bash
   kubectl get deployment -n kube-system cluster-autoscaler
   ```

4. Remove `cluster-autoscaler.yaml` from `k8s/base/kustomization.yaml`, delete `k8s/base/cluster-autoscaler.yaml` and `k8s/base/metrics-server.yaml`, push — this triggers the deploy workflow under the new scoped role.

5. Confirm the deploy workflow passes.

6. Repeat for prod.

## Verification

After step 4, confirm the deploy workflow completes without errors. The deploy workflow itself is the most reliable end-to-end test.

To manually check permissions, use the STS assumed-role format (not the IAM role ARN):

```bash
# Should return yes
kubectl auth can-i create deployment -n default \
  --as=arn:aws:sts::<ACCOUNT_ID>:assumed-role/github-actions-eks/<SESSION>

# Should return no
kubectl auth can-i create deployment -n kube-system \
  --as=arn:aws:sts::<ACCOUNT_ID>:assumed-role/github-actions-eks/<SESSION>
```

## Out of Scope

- Namespace creation: workloads stay in `default` for now
- OIDC trust policy tightening (restrict to deploy branches only) — separate future hardening
- HPA threshold fix (5% → 70%) — separate issue
