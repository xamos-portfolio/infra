# This helm chart will enable the use of Ingress Resources on the cluster
# It will create 1 Load Balancer to be shared by all Ingress Resources
resource "helm_release" "ingress" {
  name             = "ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress"
  create_namespace = true
  atomic           = true
  version          = "4.9.1"

  cleanup_on_fail = true
  lint            = true

  # https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx#values
  values = [
    file("${path.module}/helm/ingress-nginx.yaml")
  ]
}
