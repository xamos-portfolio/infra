# Create a DNS entry for the Load Balancer

# Fetch the source zone
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone
data "aws_route53_zone" "source" {
  name         = "xamos.org"
  private_zone = false
}

# Fetch the IP address of the Load Balancer
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/service
data "kubernetes_service" "ingress_controller" {
  metadata {
    name      = "${helm_release.ingress.name}-${helm_release.ingress.chart}-controller"
    namespace = helm_release.ingress.namespace
  }
}

# Create a managed zone in GCP for the 2048 game subdomain
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_managed_zone
resource "google_dns_managed_zone" "game" {
  name        = "game"
  dns_name    = "game.${data.aws_route53_zone.source.name}."
  description = "game DNS zone"
  labels = {
    purpose = "demo"
  }
}

# Pass ownership of the subdomain to GCP by creating an NS record in AWS Route 53
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record
resource "aws_route53_record" "game" {
  zone_id = data.aws_route53_zone.source.zone_id
  name    = "game.${data.aws_route53_zone.source.name}"
  type    = "NS"
  ttl     = 172800

  # The contents of the NS record must be the name servers from the managed zone from GCP
  records = google_dns_managed_zone.game.name_servers
}

# Assign the IP address of the Load Balancer to the subdomain
# This should redirect "game.xamos.org" to the Load Balancer"
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set
resource "google_dns_record_set" "game" {
  name = "game.${data.aws_route53_zone.source.name}."
  type = "A"
  ttl  = 300 # Keeping it short for demo purposes

  managed_zone = google_dns_managed_zone.game.name

  rrdatas = [
    data.kubernetes_service.ingress_controller.status.0.load_balancer.0.ingress.0.ip
  ]
}

# Create the actual demo application
# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment
resource "kubernetes_deployment" "game" {
  metadata {
    name = "game"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "game"
      }
    }

    template {
      metadata {
        labels = {
          app = "game"
        }
      }

      spec {
        container {
          image = "alexwhen/docker-2048:latest"
          name  = "game"

          port {
            container_port = 80
          }

          # https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "50Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }

            initial_delay_seconds = 15
            period_seconds        = 30
          }
        }
      }
    }
  }
}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service
resource "kubernetes_service" "game" {
  metadata {
    name = "game"
  }

  spec {
    selector = {
      app = "game"
    }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
      name        = "http"
    }

    type = "ClusterIP"
  }
}

# https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/ingress_v1
resource "kubernetes_ingress_v1" "game" {
  metadata {
    name = "game"
    annotations = {
      "cert-manager.io/cluster-issuer" = kubernetes_manifest.cluster_issuer.object.metadata.name
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [aws_route53_record.game.fqdn]
      secret_name = "2048-game-tls"
    }

    rule {
      host = aws_route53_record.game.fqdn

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "game"
              port {
                name = "http"
              }
            }
          }
        }
      }
    }
  }
}
