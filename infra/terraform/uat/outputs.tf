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
