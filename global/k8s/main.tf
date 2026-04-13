# Since the cluster is managed as independent state, we first query GCP for it
data "google_project" "main" {}

data "google_container_cluster" "main" {
  name     = "main"
  location = "us-east1-b"
}

# The autoscaling profile for the cluster is not sufficient to autoscale to zero
# due to certain system resources being required to be always available
# In order to fix this we must make some modifications

# The first thing we need to do is override the 'preventSinglePointFailure' field
# in the kube-dns-autoscaler config map in the kube-system namespace to false
# It defaults to true, and we don't care about keeping the higher availability
# We instead prefer to allow evicting these pods

# First we need to fetch the current contents of the config map
data "kubernetes_config_map" "kube_dns_autoscaler" {
  metadata {
    name      = "kube-dns-autoscaler"
    namespace = "kube-system"
  }

  depends_on = [data.google_container_cluster.main]
}

# Then we override it by adjusting its contents
resource "kubernetes_config_map_v1_data" "prevent_single_point_failure" {
  metadata {
    name      = "kube-dns-autoscaler"
    namespace = "kube-system"
  }

  # This section is a little messy but it is needed
  # due to the way the config map is structured
  # Instead of using different fields, it stores multiple values
  # as a single JSON string
  data = {
    linear = jsonencode(
      merge(
        jsondecode(data.kubernetes_config_map.kube_dns_autoscaler.data["linear"]),
        { preventSinglePointFailure = false }
    ))
  }

  force = true # We have to use the force flag to override the control from cluster-autoscaler
}
