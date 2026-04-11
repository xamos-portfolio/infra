# Workload Identity Pool for GitHub Actions
# This is the container that will hold the trust relationship with GitHub
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions to authenticate with GCP"
}

# Workload Identity Provider for GitHub Actions (OIDC)
# Defines GitHub as a trusted identity provider
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = "assertion.repository == 'xamos-portfolio/infra'"

  oidc {
    # From https://docs.github.com/en/actions/reference/security/oidc
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Service Account for GitHub Actions
resource "google_service_account" "github_actions" {
  account_id   = "github-actions-infra"
  display_name = "GitHub Actions Infra Service Account"
}

# Allows the GitHub repository to impersonate the Service Account
# Restricted to ONLY the xamos-portfolio/infra repository
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/xamos-portfolio/infra"
}

# Compute Viewer (For VPC/Firewall/Nodes)
resource "google_project_iam_member" "compute_viewer" {
  project = "xamos-project"
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Container Viewer (For GKE metadata)
resource "google_project_iam_member" "container_viewer" {
  project = "xamos-project"
  role    = "roles/container.viewer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# IAM Security Reviewer (For tfsec security scanning)
resource "google_project_iam_member" "security_reviewer" {
  project = "xamos-project"
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Workload Identity Pool Viewer (For refreshing WIF metadata)
resource "google_project_iam_member" "wif_viewer" {
  project = "xamos-project"
  role    = "roles/iam.workloadIdentityPoolViewer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Browser (For resource discovery and metadata visibility)
resource "google_project_iam_member" "browser" {
  project = "xamos-project"
  role    = "roles/browser"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# State File Access (Required to refresh tf state and manage locks)
# Limited strictly to the xamos-tfstate bucket
# roles/storage.objectUser provides the necessary permissions to read state and manage .tflock files
resource "google_storage_bucket_iam_member" "state_admin" {
  bucket = "xamos-tfstate"
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}

# OIDC Provider for GitHub Actions in AWS
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  name = "github-actions-xamos-portfolio-infra-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" : "repo:xamos-portfolio/infra:*"
          }
        }
      }
    ]
  })
}

data "aws_route53_zone" "main" {
  name = "xamos.org."
}

# Least-privilege permissions for required Route 53 metadata
resource "aws_iam_role_policy" "route53_viewer" {
  name = "route53-metadata-viewer"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource"
        ]
        Resource = data.aws_route53_zone.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZones"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:GetRole",
          "iam:ListRolePolicies"
        ]
        Resource = "*"
      }
    ]
  })
}
