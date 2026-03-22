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
