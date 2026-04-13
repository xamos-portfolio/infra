# https://cert-manager.io/docs/installation/compatibility/#gke

# This helm chart will deploy cert-manager in the cluster
# It will allow us to request TLS certificates from Let's Encrypt
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  atomic           = true
  version          = "1.13.3"

  cleanup_on_fail = true
  lint            = true

  # https://github.com/cert-manager/cert-manager/blob/master/deploy/charts/cert-manager/values.yaml
  values = [
    file("${path.module}/helm/cert-manager.yaml")
  ]
}

# We must create a firewall rule to allow the GKE control plane access to our cert-manager webhook pod
# https://cert-manager.io/docs/installation/compatibility/#gke

# First we fetch the service
data "kubernetes_service" "cert_manager_webhook" {
  metadata {
    name      = "cert-manager-webhook"
    namespace = "cert-manager"
  }

  depends_on = [helm_release.cert_manager] # The service only exists if the helm chart is deployed
}

# Then we create the firewall rule
resource "google_compute_firewall" "cert_manager_webhook" {
  name    = "cert-manager-webhook"
  network = data.google_compute_network.main.name

  # Get the used port from the deployed service
  # Port 443 is the default
  allow {
    protocol = "tcp"
    ports    = [data.kubernetes_service.cert_manager_webhook.spec.0.port.0.port]
  }

  # Requests from the cluster api server
  # https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters#add_firewall_rules
  # This can also be found manually with `gcloud container clusters describe <cluster-name> --location=<location> --format="yaml(network, privateClusterConfig)"`
  source_ranges = [google_container_cluster.main.private_cluster_config.0.private_endpoint]

  target_tags = ["gke-${google_container_cluster.main.name}-node"]
}

# We then need to create our issuer
# This will be responsible for requesting certificates from Let's Encrypt
# following the ACME protocol
# https://cert-manager.io/docs/configuration/acme/

# Fetch information about the current user
# Used to obtain your email dynamically for populating cert-manager manifests
# The email will be needed for ACME registration with Let's Encrypt
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_openid_userinfo
data "google_client_openid_userinfo" "me" {}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest
resource "kubernetes_manifest" "cluster_issuer" {
  manifest = yamldecode(templatefile("${path.module}/manifests/cluster-issuer.yaml", {
    email = data.google_client_openid_userinfo.me.email

    # https://letsencrypt.org/docs/staging-environment/ vs 
    acme_server = "https://acme-v02.api.letsencrypt.org/directory"
    name        = "letsencrypt"
  }))

  depends_on = [helm_release.cert_manager]
}

# With this setup, all we need to do is add an annotation to our ingress resources to have the TLS certs
# automatically requested from Let's Encrypt

# This will automatically request the certificate and store it in a secret specified in the tls block
# of the Ingress resource

# Even if the Ingress resource is removed, the secret will continue to exist and contain the cert
# Which can then be re-used by a new Ingress resource later (or re-requested if the certificate expires)
