# Define GCP provider (Google Cloud Platform)
provider "google" {
  project = "internal-interview-candidates"
  region  = "us-central1"
}

# Configure remote GCS backend

terraform {
  backend "gcs" {
    bucket  = "pandi-internal-interview-candidates"
    prefix  = "terraform/state"
  }
}
# VPC
resource "google_compute_network" "default" {
  project = "internal-interview-candidates"
  name                    = "l7-xlb-network"
  auto_create_subnetworks = false
}

# backend subnet
resource "google_compute_subnetwork" "default" {
  name          = "l7-xlb-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = "us-central1"
  network       = google_compute_network.default.id
}

# reserved IP address
resource "google_compute_global_address" "default" {
  name     = "l7-xlb-static-ip"
}

# Create a default route with the external IP as the next hop
# resource "google_compute_route" "default_route" {
#   name                  = "default-route"
#   dest_range            = "0.0.0.0/0"
#   network               = google_compute_network.default.self_link
#   next_hop_ip           = google_compute_global_address.default.address
# }

# forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "l7-xlb-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  ip_address            = google_compute_global_address.default.id
}

# http proxy
resource "google_compute_target_http_proxy" "default" {
  name     = "l7-xlb-target-http-proxy"
  url_map  = google_compute_url_map.default.id
}

# url map
resource "google_compute_url_map" "default" {
  name            = "l7-xlb-url-map"
  default_service = google_compute_backend_service.default.id
}

# backend service with custom request and response headers
resource "google_compute_backend_service" "default" {
  name                    = "l7-xlb-backend-service"
  protocol                = "HTTP"
  port_name               = "http"
  load_balancing_scheme   = "EXTERNAL"
  timeout_sec             = 10
  health_checks           = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.default.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# instance template
resource "google_compute_instance_template" "default" {
  name         = "l7-xlb-mig-template"
  machine_type = "e2-small"
  tags         = ["allow-health-check"]

  network_interface {
    network    = google_compute_network.default.id
    subnetwork = google_compute_subnetwork.default.id
    access_config {
      # add external ip to fetch packages
    }
  }
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  # startup script to install and configure the web server
  metadata = {
    startup-script = <<-EOF
    apt-get update
    apt-get install -y apache2
    
    # Change the default web server port to 8080
    sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf
    
    sudo systemctl restart apache2
    EOF
  }
  lifecycle {
    create_before_destroy = true
  }
}

# health check
resource "google_compute_health_check" "default" {
  name     = "l7-xlb-hc"
  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

# MIG
resource "google_compute_instance_group_manager" "default" {
  name     = "l7-xlb-mig1"
  zone     = "us-central1-c"
  named_port {
    name = "http"
    port = 8080
  }
  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }
  base_instance_name = "vm"
}

# Auto scaler
resource "google_compute_autoscaler" "default" {
  name   = "my-autoscaler"
  zone   = "us-central1-c"
  target = google_compute_instance_group_manager.default.id

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

# allow access from health check ranges
resource "google_compute_firewall" "default" {
  name          = "l7-xlb-fw-allow-hc"
  direction     = "INGRESS"
  network       = google_compute_network.default.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
  target_tags = ["allow-health-check"]
}

# allow access from internet to specific instances
resource "google_compute_firewall" "backend-instances" {
  name          = "internet-fw-allow"
  direction     = "INGRESS"
  network       = google_compute_network.default.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  target_tags = ["allow-health-check"]
}


resource "google_project_iam_custom_role" "my-custom-role" {
  role_id     = "myCustomRole"
  title       = "My Custom Role"
  description = "Start and stop permission"
  permissions = ["compute.instances.start", "compute.instances.stop"]
}

resource "google_project_iam_binding" "project" {
  project = "internal-interview-candidates"
  role    = google_project_iam_custom_role.my-custom-role.id

  members = [
    "user:pandithdurai@gmail.com",
  ]
}