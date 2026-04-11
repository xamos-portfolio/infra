terraform {
  backend "gcs" {
    bucket = "xamos-tfstate"
    prefix = "global/iam"
  }
}
