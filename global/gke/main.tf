# Since the VPC is managed as independent state, we first query GCP for the network and subnet
data "google_compute_network" "main" {
  name = "main"
}

data "google_compute_subnetwork" "main" {
  name   = "private"
  region = "us-east1"
}

# We then create the cluster itself
resource "google_container_cluster" "main" {
  name     = "main"
  location = "us-east1-b" # By specifying a zone rather than a region, we create a zonal cluster
  # This has less availability by not replicating across all zones in a region, but also will be cheaper
  # as it needs less resources
  # Additionally, GKE's free tier offering applies only if you have a single zonal cluster
  # So not only does it need less resources for replication, but also saves
  # the 10 cents per hour management fee
  # https://cloud.google.com/kubernetes-engine/pricing#cluster_management_fee_and_free_tier

  # If we want to specify multiple zones without making the cluster into a regional cluster
  # we can optionally specify the extra zones with
  # node_locations = ["us-east1-c"]

  # The cluster will exist within the network and subnet created previously
  network    = data.google_compute_network.main.name
  subnetwork = data.google_compute_subnetwork.main.name

  # These settings are all the default values for now
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"
  networking_mode    = "VPC_NATIVE"

  # We intend to manage our node_pools separately, so we remove the default node pool
  remove_default_node_pool = true
  initial_node_count       = 1 # It will be removed, so it is as small as possible

  addons_config {
    # We don't want the default Load Balancer Controller addon
    # As it claims to create a LB per Ingress resource
    # As LBs are expensive, we would prefer to manage one LB
    # for all Ingress resources
    # https://cloud.google.com/kubernetes-engine/docs/concepts/ingress
    http_load_balancing {
      disabled = true
    }

    # The Autoscaling addon is already enabled by default
    # But it is better to be strict in case configuration changes
    # https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Default monitoring config is fine for now
  # We will revisit this later when we're ready to setup proper monitoring
  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
    ]

    managed_prometheus {
      enabled = true
    }
  }

  # We want to support autoscaling down to zero when possible
  # So we change the autoscaling profile from BALANCED to OPTIMIZE_UTILIZATION
  # This may evict pods at inopportune times so likely isn't suitable for production clusters
  # But in our case it will improve our resource utilization and we'll spend less money
  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  # Ensure we receive steady updates
  release_channel {
    channel = "REGULAR"
  }

  # We want to allow pods to interact with GCP services
  # https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
  workload_identity_config {
    # <project-id>.svc.id.goog
    workload_pool = "xamos-project.svc.id.goog"
  }

  # Leverage the secondary IP ranges of our subnet for VPC-native cluster
  ip_allocation_policy {
    cluster_secondary_range_name  = "k8s-pod-range"
    services_secondary_range_name = "k8s-service-range"
  }

  # We want the cluster to be private by default
  # And restrict access to the outside internet
  # https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept
  private_cluster_config {
    enable_private_nodes    = true            # This setting turns the cluster into a private cluster
    enable_private_endpoint = false           # Keeping this as false allows the control plane to be accessible from the internet (namely for kubectl commands from local machine)
    master_ipv4_cidr_block  = "172.16.10.0/28" # This must be a /28 CIDR range (16 IPs) that does not overlap with any of our other networking blocks
  }
}

# We create a GCP service account that will be attached to each node in the cluster
# If there are ever any permissions that need to be given to every node, this service account will be used
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/google_service_account
resource "google_service_account" "kubernetes" {
  account_id = "kubernetes"
}

# The first node pool we create will be an always active dedicated node pool
# It will be used to manage operators/systems that should always be available
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool
resource "google_container_node_pool" "dedicated" {
  name       = "dedicated"
  cluster    = google_container_cluster.main.id
  node_count = 1

  max_pods_per_node = 32

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 3
  }

  node_config {
    preemptible  = false
    machine_type = "e2-small"

    labels = {
      role = "dedicated"
    }

    service_account = google_service_account.kubernetes.email

    # By leveraging Kubernetes taints, we ensure that only services that
    # are specifically configured can be scheduled on this node pool
    # The components.gke.io/gke-managed-components taint is already tolerated
    # by the system components that GKE deploys, which means
    # the autoscaler will be able to evict system pods from the spot pool into this pool
    # Resulting in allowing the spot pool to scale down to zero
    # https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
    taint {
      key    = "components.gke.io/gke-managed-components"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    # https://github.com/xamos-portfolio/infra/issues/5
    disk_size_gb = 30
    disk_type    = "pd-standard"
  }
}

# The next node pool will be where we will deploy our
# application containers/services
# This approach will save money in the long run
resource "google_container_node_pool" "spot" {
  name    = "spot"
  cluster = google_container_cluster.main.id

  max_pods_per_node = 32

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  autoscaling {
    total_min_node_count = 0 # Ensure that the spot pool can scale down to zero
    total_max_node_count = 5
  }

  node_config {
    spot         = true # This provides the cheaper cost of running the nodes by allowing them to be interrupted
    machine_type = "e2-small"

    labels = {
      role = "spot"
    }

    service_account = google_service_account.kubernetes.email

    # https://github.com/xamos-portfolio/infra/issues/5
    disk_size_gb = 30
    disk_type    = "pd-standard"
  }
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

  depends_on = [google_container_cluster.main]
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
