# ============================================================================
# LOCAL VARIABLES
# ============================================================================
# Centralized locals for the entire project
locals {
  namespaces = var.enable_blue_environment ? ["${var.k3s_default_namespace}-blue", "${var.k3s_default_namespace}-green"] : ["${var.k3s_default_namespace}-green"]
  
  # Sanitize hostname untuk kompatibilitas dengan libvirt
  sanitized_hostname = replace(lower(var.vm_hostname), "_", "-")
  # Extract IP address dari CIDR notation jika ada
  # Contoh: "192.168.122.10/24" -> "192.168.122.10"
  node_ip = var.vm_ip_address != "" ? (
    can(regex("/", var.vm_ip_address)) ? split("/", var.vm_ip_address)[0] : var.vm_ip_address
  ) : ""

  # Format nameservers untuk cloud-init YAML
  nameservers_yaml = join(", ", [for ns in var.vm_nameservers : ns])

  # Detect virtualization type dari file yang dibuat oleh null_resource
  virt_type_file = "${path.module}/.virt_type"
  domain_type = fileexists(local.virt_type_file) ? trimspace(file(local.virt_type_file)) : "qemu"

  # Detect emulator path
  emulator_file      = "${path.module}/.emulator_path"
  detected_emulator  = fileexists(local.emulator_file) ? trimspace(file(local.emulator_file)) : ""

  # CPU mode berdasarkan domain type
  effective_cpu_mode = local.domain_type == "kvm" ? "host-passthrough" : "custom"

  # UEFI firmware detection
  uefi_firmware_paths = [
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
    "/usr/share/qemu/OVMF_CODE.fd"
  ]

  uefi_firmware_path = try(
    [for path in local.uefi_firmware_paths : path if fileexists(path)][0],
    ""
  )

  use_uefi = local.uefi_firmware_path != ""

  # Pool name
  pool_name = var.libvirt_pool_name

  # Validation flags
  has_static_ip = var.vm_ip_address != ""
  is_k3s_agent  = var.k3s_node_role == "agent"
  
  # K3s configuration validation
  k3s_config_valid = local.is_k3s_agent ? (
    var.k3s_server_url != "" && var.k3s_token != ""
  ) : true
  
  # Database configurations
  databases = {
    postgres = {
      image                 = "postgres:16-alpine"
      port                  = 5432
      storage_size          = "1Gi"
      db_name               = "${var.postgres_database}"
      user                  = "postgres"
      password_resource     = "${var.postgres_root_password}"
      app_user              = "${var.postgres_username}"
      app_password_resource = "${var.postgres_password}"
      probes = {
        readiness = {
          command           = ["pg_isready", "-U", "postgres"]
          initial_delay     = 5
          period            = 10
          timeout           = 5
          failure_threshold = 6
        }
        liveness = {
          command           = ["pg_isready", "-U", "postgres"]
          initial_delay     = 15
          period            = 10
          timeout           = 5
          failure_threshold = 6
        }
      }
    }
    mariadb = {
      image                  = "mariadb:10.11"
      port                   = 3306
      storage_size           = "1Gi"
      db_name                = "${var.mariadb_database}"
      user                   = "${var.mariadb_username}"
      password               = "${var.mariadb_password}"
      root_password_resource = "${var.mariadb_root_password}"
      probes = {
        readiness = {
          command           = ["sh", "-c", "mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD"]
          initial_delay     = 5
          period            = 10
          timeout           = 1
          failure_threshold = 3
        }
        liveness = {
          command           = ["sh", "-c", "mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD"]
          initial_delay     = 30
          period            = 10
          timeout           = 5
          failure_threshold = 3
        }
      }
    }
    mongodb = {
      image                  = "mongo:4.4"
      port                   = 27017
      storage_size           = "1Gi"
      root_user              = "${var.mongo_username}"
      root_password_resource = "${var.mongo_password}"
    }
    redis = {
      image             = "redis:6.2-alpine"
      port              = 6379
      storage_size      = "1Gi"
      password_resource = "${var.redis_password}"
      probes = {
        readiness = {
          command           = ["sh", "-c", "redis-cli -a $REDIS_PASSWORD ping | grep PONG"]
          initial_delay     = 5
          period            = 10
          timeout           = 5
          failure_threshold = 3
        }
        liveness = {
          command           = ["sh", "-c", "redis-cli -a $REDIS_PASSWORD ping | grep PONG"]
          initial_delay     = 15
          period            = 10
          timeout           = 5
          failure_threshold = 3
        }
      }
    }
  }
}
