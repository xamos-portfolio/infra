# Create the base network
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network
resource "google_compute_network" "main" {
  name                    = "main"
  routing_mode            = "REGIONAL"
  auto_create_subnetworks = false # Do not create default subnets
  mtu                     = 1460
}

# Create our subnet manually
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork
resource "google_compute_subnetwork" "private" {
  name                     = "private"
  ip_cidr_range            = "10.10.0.0/24" # 10.10.0.1 - 10.10.0.254
  region                   = "us-east1"
  network                  = google_compute_network.main.id
  private_ip_google_access = true

  # We want to create a VPC-native cluster in order to have native addressing for pods/services
  # https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips
  secondary_ip_range {
    range_name    = "k8s-pod-range"
    ip_cidr_range = "10.100.0.0/21" # 10.100.0.1 - 10.100.7.254
    # Total 2,048 IPs for Pods
  }

  secondary_ip_range {
    range_name    = "k8s-service-range"
    ip_cidr_range = "10.100.8.0/24" # 10.100.8.1 - 10.100.8.254
    # Total 254 IPs for Services
  }
}

# Create a Router to be leveraged by the NAT Gateway
# This is what is responsible for mapping between the NAT Gateway and the various instances, pods, and services within the network
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router
resource "google_compute_router" "router" {
  name    = "router"
  region  = "us-east1"
  network = google_compute_network.main.id
}

# A NAT Gateway will allow instances to communicate externally
# Any request sent out from the network will show that the IP
# is coming from the NAT Gateway
# This is needed because the instances, pods, services, etc do not have their own dedicated IP
# They only have private IPs within the VPC
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat
resource "google_compute_router_nat" "nat" {
  name   = "nat"
  router = google_compute_router.router.name
  region = "us-east1"

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  nat_ip_allocate_option             = "MANUAL_ONLY"

  # Here we define what sources can leverage this gateway
  # We specify all IPs within our network
  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  nat_ips = [google_compute_address.nat.self_link]
}

# This allocates a Dedicated IP for the NAT Gateway
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_address
resource "google_compute_address" "nat" {
  name         = "nat"
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}
