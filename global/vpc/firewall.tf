# We want to allow SSH traffic from anywhere to the instances within the network
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.main.name

  # Port 22 is used for SSH
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Requests from anywhere
  source_ranges = ["0.0.0.0/0"]
}

# We also want to allow communication between the nodes themselves
resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  # Requests from other instances
  source_ranges = [google_compute_subnetwork.private.ip_cidr_range]
}
