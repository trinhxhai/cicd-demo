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
