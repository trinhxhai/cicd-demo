resource "kubernetes_cluster_role" "ci_eso_manager" {
  metadata {
    name = "ci-eso-manager"
  }

  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["clustersecretstores", "externalsecrets", "secretstores"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "ci_eso_manager" {
  metadata {
    name = "ci-eso-manager"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ci_eso_manager.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "ci-deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
