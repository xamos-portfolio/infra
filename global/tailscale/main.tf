data "google_project" "main" {}

data "google_compute_network" "main" {
  name = "main"
}

data "google_compute_subnetwork" "private" {
  name   = "private"
  region = "us-east1"
}

data "google_container_cluster" "main" {
  name     = "main"
  location = "us-east1-b"
}

resource "google_service_account" "tailscale_router" {
  account_id   = "tailscale-router"
  display_name = "Tailscale Subnet Router"
}

# Allow the service account to mint OIDC tokens for itself
# This is required for Workload Identity Federation to work on the VM
resource "google_service_account_iam_member" "tailscale_router_token_creator" {
  service_account_id = google_service_account.tailscale_router.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.tailscale_router.email}"
}

# Identity for CI Pipeline (GitHub Actions)
resource "tailscale_federated_identity" "ci" {
  description = "GitHub Actions Federation for Infra Repo"
  issuer      = "https://token.actions.githubusercontent.com"

  # Trusts the repository directly
  subject = "repo:xamos-portfolio/infra:*"

  # Scopes: 
  # - devices:core (join tailnet)
  # - logs:read (audit logs)
  # - auth_keys (generate runner keys)
  # - federated_keys:read (read-only access to Tailscale federated identities)
  scopes = ["devices:core", "logs:read", "auth_keys", "federated_keys:read"]
  tags   = ["tag:ci"]
}

# Identity for the Subnet Router VM (Google Cloud)
resource "tailscale_federated_identity" "router" {
  description = "GCP Workload Federation for Subnet Router VM"
  issuer      = "https://accounts.google.com"

  # Trusts the service account attached to the VM
  subject = google_service_account.tailscale_router.unique_id

  scopes = ["devices:core", "auth_keys"]
  tags   = ["tag:router"]
}

resource "google_compute_instance" "tailscale_router" {
  name         = "tailscale-subnet-router"
  machine_type = "e2-micro"
  zone         = "us-east1-b"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = data.google_compute_network.main.name
    subnetwork = data.google_compute_subnetwork.private.name
  }

  # trivy:ignore:GCP-0043 - IP forwarding is required for the Subnet Router
  can_ip_forward = true
  service_account {
    email  = google_service_account.tailscale_router.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    tailscale-client-id = tailscale_federated_identity.router.id
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    CLIENT_ID=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/tailscale-client-id")
    
    tailscale up \
      --client-id="$CLIENT_ID" \
      --audience="api.tailscale.com/$CLIENT_ID" \
      --advertise-routes="${data.google_compute_subnetwork.private.ip_cidr_range},${data.google_container_cluster.main.private_cluster_config.0.master_ipv4_cidr_block}" \
      --advertise-tags="tag:router" \
      --accept-routes
  EOF

  depends_on = [
    tailscale_federated_identity.router,
    google_service_account_iam_member.tailscale_router_token_creator
  ]
}

output "tailscale_ci_federated_client_id" {
  value       = tailscale_federated_identity.ci.id
  description = "The OAuth Client ID for Tailscale CI federation"
}
