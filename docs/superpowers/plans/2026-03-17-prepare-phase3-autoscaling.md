# Phase 3 Pre-flight: Fix Issues Before Executing Autoscaling Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve two blocking issues discovered during phase 3 plan review so that autoscaling works end-to-end when the main plan is executed.

**Why this exists:** The phase 3 plan (`2026-03-17-phase3-autoscaling.md`) was written assuming `eksctl`, but the actual cluster uses Terraform. The Cluster Autoscaler IAM role does not exist and must be created before the CA deployment will function.

---

## Issue 1: Cluster Autoscaler IAM Role Missing

**Problem:** The phase 3 plan tells you to find the CA IAM role with:

```bash
aws iam list-roles --query "Roles[?contains(RoleName, 'cluster-autoscaler') || contains(RoleName, 'eksctl')]..."
```

But `infra/terraform/iam.tf` has no Cluster Autoscaler role. The Terraform EKS module does not create one automatically. Without it, the CA pod cannot call the AWS Auto Scaling API and will log permission errors.

**Fix:** Add the IRSA role to Terraform.

- [ ] **Step 1: Add CA IRSA role to `infra/terraform/iam.tf`**

Append to `infra/terraform/iam.tf`:

```hcl
# Cluster Autoscaler — IRSA role
# The CA pod uses this role (via service account annotation) to call the AWS
# Auto Scaling API: describe/set desired capacity on the node group ASG.
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
  name               = "cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"

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
  description = "IAM role ARN for the Cluster Autoscaler service account"
  value       = aws_iam_role.cluster_autoscaler.arn
}
```

- [ ] **Step 2: Apply Terraform**

```bash
cd infra/terraform
terraform plan -out=tfplan
terraform apply tfplan
```

Expected: 3 new resources created (`aws_iam_role.cluster_autoscaler`, `aws_iam_policy.cluster_autoscaler`, `aws_iam_role_policy_attachment.cluster_autoscaler`).

- [ ] **Step 3: Get the role ARN for use in phase 3**

```bash
terraform output cluster_autoscaler_role_arn
```

Copy this ARN — you will paste it into `k8s/base/cluster-autoscaler.yaml` in phase 3 Task 4 Step 3.

- [ ] **Step 4: Commit**

```bash
git add infra/terraform/iam.tf
git commit -m "feat: add Cluster Autoscaler IRSA role via Terraform"
```

---

## Issue 2: Cluster Autoscaler Node Discovery Tags

**Problem:** The phase 3 `cluster-autoscaler.yaml` uses this discovery flag:

```
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/nx-monorepo
```

The Terraform EKS module (`terraform-aws-modules/eks ~> 20.0`) automatically tags managed node group ASGs with both `k8s.io/cluster-autoscaler/enabled=true` and `k8s.io/cluster-autoscaler/<cluster-name>=owned`. Verify the tags exist before deploying CA.

- [ ] **Step 1: Confirm ASG tags after `terraform apply`**

```bash
# Get the ASG name
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'nx-monorepo')].{Name:AutoScalingGroupName}" \
  --output table

# Check its tags
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'nx-monorepo')].AutoScalingGroupName" \
  --output text)

aws autoscaling describe-tags \
  --filters Name=auto-scaling-group,Values=$ASG_NAME \
  --query "Tags[?Key=='k8s.io/cluster-autoscaler/enabled' || Key=='k8s.io/cluster-autoscaler/nx-monorepo'].{Key:Key,Value:Value}" \
  --output table
```

Expected: both tags appear. If they are missing, add them to the node group in `eks.tf`:

```hcl
eks_managed_node_groups = {
  workers = {
    # ... existing config ...
    tags = {
      "k8s.io/cluster-autoscaler/enabled"       = "true"
      "k8s.io/cluster-autoscaler/nx-monorepo"   = "owned"
    }
  }
}
```

Then re-run `terraform apply`.

---

## Done ✓

Both issues resolved when:
- `terraform output cluster_autoscaler_role_arn` returns a valid ARN
- ASG has both CA discovery tags

You can now execute `2026-03-17-phase3-autoscaling.md` — skip its Task 4 Step 2 IAM lookup (use the Terraform output instead) and substitute the ARN directly.
