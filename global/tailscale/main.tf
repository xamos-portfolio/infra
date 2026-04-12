data "google_project" "main" {}

data "google_compute_network" "main" {
  name = "main"
}

data "google_compute_subnetwork" "private" {
  name   = "private"
  region = "us-east1"
}

resource "google_service_account" "tailscale_router" {
  account_id   = "tailscale-router"
  display_name = "Tailscale Subnet Router"
}

# Identity for CI Pipeline (GitHub Actions)
resource "tailscale_federated_identity" "ci" {
  description = "GitHub Actions Federation for Infra Repo"
  issuer      = "https://token.actions.githubusercontent.com"

  # Trusts the repository directly
  subject = "repo:xamos-portfolio/infra:*"

  scopes = ["devices:core", "logs:read", "auth_keys"]
  tags   = ["tag:ci"]
}

# Identity for the Subnet Router VM (Google Cloud)
resource "tailscale_federated_identity" "router" {
  description = "GCP Workload Federation for Subnet Router VM"
  issuer      = "https://accounts.google.com"

  # Trusts the service account attached to the VM
  subject = "principalSet://iam.googleapis.com/projects/${data.google_project.main.number}/serviceAccounts/${google_service_account.tailscale_router.email}"

  scopes = ["devices:core"]
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

  metadata_startup_script = <<-EOF
    #!/bin/bash
    curl -fsSL https://tailscale.com/install.sh | sh
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    PROJECT_NUM=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/numeric-project-id")
    TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://tailscale.com/$PROJECT_NUM")

    tailscale up --authkey="ts-oidc:$TOKEN" --advertise-routes="10.10.0.0/24" --accept-routes
  EOF

  depends_on = [tailscale_federated_identity.router]
}

output "tailscale_ci_federated_client_id" {
  value       = tailscale_federated_identity.ci.id
  description = "The OAuth Client ID for Tailscale CI federation"
}
