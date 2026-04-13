provider "google" {
  project = "xamos-project"
  region  = "us-east1"
}

data "google_client_config" "current" {}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.main.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.main.master_auth.0.cluster_ca_certificate)
  token                  = data.google_client_config.current.access_token
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.main.endpoint}"
    cluster_ca_certificate = base64decode(data.google_container_cluster.main.master_auth.0.cluster_ca_certificate)
    token                  = data.google_client_config.current.access_token
  }
}

provider "aws" {
  region = "us-east-1"
}
