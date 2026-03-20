data "aws_caller_identity" "current" {}

# Register the GitHub Actions OIDC provider with AWS IAM.
# This must exist before any role can use AssumeRoleWithWebIdentity from GitHub.
#
# NOTE: AWS allows only one OIDC provider per URL per account.
# If your account already has this provider (from another project), terraform apply will fail
# with EntityAlreadyExists. Fix: import it instead of creating it:
#   aws iam list-open-id-connect-providers   # find the ARN
#   terraform import aws_iam_openid_connect_provider.github_actions <ARN>
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
