terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.28.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

provider "tailscale" {
  tailnet = "fenrir-trout.ts.net"
  # Authentication will be handled by the environment variables:
  # - TAILSCALE_API_KEY (for local bootstrap)
  # - TAILSCALE_OAUTH_CLIENT_ID & TAILSCALE_IDENTITY_TOKEN (for CI)
}

provider "google" {
  project = "xamos-project"
  region  = "us-east1"
}
