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
