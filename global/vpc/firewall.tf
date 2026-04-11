# Allow SSH traffic ONLY via Identity-Aware Proxy (IAP)
# https://cloud.google.com/iap/docs/using-tcp-forwarding
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Only allow IAP's IP range
  source_ranges = ["35.235.240.0/20"]
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
