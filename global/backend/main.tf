# Create a keyring to hold the encryption key
resource "google_kms_key_ring" "tf_state" {
  name     = "xamos-tfstate"
  location = "us"
}

# The key is held in the above keyring
resource "google_kms_crypto_key" "tf_state_bucket" {
  name            = "xamos-tfstate"
  key_ring        = google_kms_key_ring.tf_state.id
  rotation_period = "7776000s" # 90 Days

  # In order to avoid losing access to the state, we prevent destruction of the key
  lifecycle {
    prevent_destroy = true
  }
}

# Query information about the project we are running in
data "google_project" "project" {}

# Ensure the Cloud Storage service has permission to perform encryption/decryption with the above key
resource "google_project_iam_member" "default" {
  project = data.google_project.project.project_id
  role    = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member  = "serviceAccount:service-${data.google_project.project.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# Create the bucket to store state
resource "google_storage_bucket" "default" {
  name          = "xamos-tfstate"
  force_destroy = false
  location      = "US"
  storage_class = "STANDARD"

  # These settings will prevent us from running tf commands
  # without manually granting access to the bucket
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  # It is recommended to enable versioning to avoid catastrophic mishaps
  versioning {
    enabled = true
  }

  # Prevent infinite accumulation of old state versions
  lifecycle_rule {
    condition {
      num_newer_versions = 2
    }
    action {
      type = "Delete"
    }
  }

  # We encrypt the state to secure any sensitive data our state might contain
  encryption {
    default_kms_key_name = google_kms_crypto_key.tf_state_bucket.id
  }

  # Wait to create bucket until the service account has been granted access to use the key
  depends_on = [
    google_project_iam_member.default
  ]
}
