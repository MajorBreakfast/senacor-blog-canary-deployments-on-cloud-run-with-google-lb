locals {
  services_with_raw_env = { for filename in fileset("${path.module}/${var.services_folder}", "*.yaml") :
    # The square brackets in filenames signify canary deployments
    # filename "authentication-ms.yaml"         -> key/name "authentication-ms", basename "authentication-ms"
    # filename "authentication-ms[pr-100].yaml" -> key/name "authentication-ms-pr-100", basename "authentication-ms"
    replace(replace(trimsuffix(filename, ".yaml"), "[", "-"), "]", "")
    => {
      name         = replace(replace(trimsuffix(filename, ".yaml"), "[", "-"), "]", "")
      basename     = trimsuffix(split("[", filename).0, ".yaml")
      is_canary    = strcontains(filename, "[")
      canary_label = try(split("]", split("[", filename).1).0, "")
      config       = yamldecode(file("${path.module}/${var.services_folder}/${filename}"))
    } if !startswith(filename, "_") || !endswith(filename, ".yaml") # Only .yaml files not starting with an underscore
  }

  canary_config = jsonencode({
    variantsPerService = [for service_basename in toset([for service in values(local.services_with_raw_env) : service.basename if !try(service.config.canaryHidden, false)]) : {
      service = service_basename
      variants = [for inner_service in values(local.services_with_raw_env) : {
        label       = inner_service.canary_label
        description = try(inner_service.config.canaryDescription, "")
      } if inner_service.basename == service_basename && inner_service.is_canary]
    }]
  })

  environment_config_raw = yamldecode(file("${path.module}/${var.services_folder}/_environment-config.yaml"))

  environment_config = merge(
    local.environment_config_raw,
    {
      env = concat(
        local.environment_config_raw.env,
        [{ name = "CANARY_CONFIG", value = local.canary_config }]
      )
    }
  )

  services = {
    for service_name, service in local.services_with_raw_env : service_name => merge(service, {
      config = merge(service.config, {
        env = [
          for env_var in service.config.env :
          length(keys(env_var)) == 1
          ? [for v in local.environment_config.env : v if v.name == env_var.name].0 # Only "name" prop -> load from environment config
          : env_var                                                                 # "value" or "fromSecret" prop specified -> use as-is
        ]
      })
    })
  }

  default_service_name = [for k, v in local.services : k if try(v.config.routing.default, false)].0
}

resource "google_cloud_run_v2_service" "services" {
  for_each = local.services

  project  = var.project
  name     = "${var.prefix}-${each.key}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = each.value.config.serviceAccountName

    containers {
      image = each.value.config.image

      resources {
        startup_cpu_boost = true
      }

      dynamic "env" {
        # Sort alphabetically so that reordering stuff in the yaml files doesn't affect the plan
        for_each = [for name in sort(each.value.config.env[*].name) : [for e in each.value.config.env : e if e.name == name].0]
        content {
          name  = env.value.name
          value = try(env.value.value, null)

          dynamic "value_source" {
            for_each = can(env.value.fromSecret) ? [1] : []
            content {
              secret_key_ref {
                secret  = env.value.fromSecret
                version = "latest"
              }
            }
          }
        }
      }
    }
  }
}

resource "google_cloud_run_service_iam_member" "services_can_be_called_without_authentication" {
  for_each = local.services

  project  = google_cloud_run_v2_service.services[each.key].project
  location = google_cloud_run_v2_service.services[each.key].location
  service  = google_cloud_run_v2_service.services[each.key].name

  role   = "roles/run.invoker"
  member = "allUsers"
}

resource "google_compute_region_network_endpoint_group" "services" {
  for_each = local.services

  network_endpoint_type = "SERVERLESS"
  project               = google_cloud_run_v2_service.services[each.key].project
  name                  = google_cloud_run_v2_service.services[each.key].name
  region                = google_cloud_run_v2_service.services[each.key].location

  cloud_run {
    service = google_cloud_run_v2_service.services[each.key].name
  }
}

resource "google_compute_backend_service" "services" {
  for_each = local.services

  project = google_compute_region_network_endpoint_group.services[each.key].project
  name    = google_compute_region_network_endpoint_group.services[each.key].name

  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30

  backend {
    group = google_compute_region_network_endpoint_group.services[each.key].id
  }
}

resource "google_compute_url_map" "default" {
  project         = var.project
  name            = var.prefix
  default_service = google_compute_backend_service.services[local.default_service_name].id

  host_rule {
    hosts        = ["*"]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.services[local.default_service_name].id

    dynamic "route_rules" {
      for_each = flatten([
        # Sort the path prefixes reverse alphabetically. That way, longer path prefixes come first
        # Also list canary variants before the non-canary variant
        for path_prefix in reverse(sort(flatten(values(local.services)[*].config.routing.pathPrefixes))) :
        [
          [for _, service in local.services : { path_prefix = path_prefix, service = service } if contains(service.config.routing.pathPrefixes, path_prefix) && service.is_canary],
          [for _, service in local.services : { path_prefix = path_prefix, service = service } if contains(service.config.routing.pathPrefixes, path_prefix) && !service.is_canary]
        ]
      ])
      content {
        priority = route_rules.key + 1
        service  = google_compute_backend_service.services[route_rules.value.service.name].id

        match_rules {
          prefix_match = route_rules.value.path_prefix

          dynamic "header_matches" {
            for_each = route_rules.value.service.is_canary ? [1] : []
            content {
              header_name = "canary-${route_rules.value.service.basename}"
              exact_match = route_rules.value.service.canary_label
            }
          }
        }
      }
    }
  }
}

resource "google_compute_managed_ssl_certificate" "default" {
  project = var.project
  name    = var.prefix

  managed {
    domains = [var.api_domain]
  }
}

resource "google_compute_target_https_proxy" "default" {
  project = var.project
  name    = var.prefix

  url_map = google_compute_url_map.default.id

  ssl_certificates = [
    google_compute_managed_ssl_certificate.default.id
  ]
}

resource "google_compute_global_address" "default" {
  project = var.project
  name    = var.prefix
}

resource "google_dns_record_set" "default" {
  project = var.project
  name    = "${var.api_domain}."
  type    = "A"
  ttl     = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = [google_compute_global_address.default.address]
}

resource "google_compute_global_forwarding_rule" "default" {
  project = var.project
  name    = var.prefix

  target     = google_compute_target_https_proxy.default.id
  port_range = "443"
  ip_address = google_compute_global_address.default.address
}
