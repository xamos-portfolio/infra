terraform {
  backend "gcs" {
    bucket = "xamos-tfstate"
    prefix = "global/k8s"
  }
}
