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
