# PostgreSQL StatefulSet for both environments
resource "kubernetes_stateful_set" "postgres" {
  for_each = toset(local.namespaces)
  
  metadata {
    name      = "postgres"
    namespace = each.key
  }

  spec {
    service_name = "postgres"
    replicas     = 1

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = local.databases.postgres.image
          
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.postgres_secrets[each.key].metadata[0].name
                key  = "postgres-user"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name =  kubernetes_secret.postgres_secrets[each.key].metadata[0].name
                key  = "postgres-password"
              }
            }
          }
          env {
            name  = "POSTGRES_DB"
            value = local.databases.postgres.db_name
          }
          
          volume_mount {
            name       = "init-script"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }
          
          port {
            container_port = local.databases.postgres.port
          }
          
          volume_mount {
            name       = "postgres-${each.key}-storage"
            mount_path = "/var/lib/postgresql/data"
            sub_path   = "postgres"
          }

          readiness_probe {
            exec {
              command = local.databases.postgres.probes.readiness.command
            }
            initial_delay_seconds = local.databases.postgres.probes.readiness.initial_delay
            period_seconds        = local.databases.postgres.probes.readiness.period
            timeout_seconds       = local.databases.postgres.probes.readiness.timeout
            failure_threshold     = local.databases.postgres.probes.readiness.failure_threshold
          }

          liveness_probe {
            exec {
              command = local.databases.postgres.probes.liveness.command
            }
            initial_delay_seconds = local.databases.postgres.probes.liveness.initial_delay
            period_seconds        = local.databases.postgres.probes.liveness.period
            timeout_seconds       = local.databases.postgres.probes.liveness.timeout
            failure_threshold     = local.databases.postgres.probes.liveness.failure_threshold
          }
        }
        
        volume {
          name = "init-script"
          config_map {
            name = kubernetes_config_map.postgres_init_script[each.key].metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "postgres-${each.key}-storage"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = local.databases.postgres.storage_size
          }
        }
      }
    }

    update_strategy {
      type = "RollingUpdate"
      rolling_update {
        partition = 0
      }
    }
  }
}

# MariaDB StatefulSet for both environments
resource "kubernetes_stateful_set" "mariadb" {
  for_each = toset(local.namespaces)
  
  metadata {
    name      = "mariadb"
    namespace = each.key
  }

  spec {
    service_name = "mariadb"
    replicas     = 1

    selector {
      match_labels = {
        app = "mariadb"
      }
    }

    template {
      metadata {
        labels = {
          app = "mariadb"
        }
      }

      spec {
        container {
          name  = "mariadb"
          image = local.databases.mariadb.image

          env {
            name = "MYSQL_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mariadb_secrets[each.key].metadata[0].name
                key  = "mariadb-root-password"
              }
            }
          }
          env {
            name = "MYSQL_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mariadb_secrets[each.key].metadata[0].name
                key  = "mariadb-user"
              }
            }
          }
          env {
            name = "MYSQL_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mariadb_secrets[each.key].metadata[0].name
                key  = "mariadb-password"
              }
            }
          }
          env {
            name = "MYSQL_DATABASE"
            value = local.databases.mariadb.db_name
          }

          port {
            container_port = local.databases.mariadb.port
          }

          volume_mount {
            name       = "mariadb-${each.key}-storage"
            mount_path = "/var/lib/mysql"
          }

          readiness_probe {
            exec {
              command = local.databases.mariadb.probes.readiness.command
            }
            initial_delay_seconds = local.databases.mariadb.probes.readiness.initial_delay
            period_seconds        = local.databases.mariadb.probes.readiness.period
            timeout_seconds       = local.databases.mariadb.probes.readiness.timeout
            failure_threshold     = local.databases.mariadb.probes.readiness.failure_threshold
          }

          liveness_probe {
            exec {
              command = local.databases.mariadb.probes.liveness.command
            }
            initial_delay_seconds = local.databases.mariadb.probes.liveness.initial_delay
            period_seconds        = local.databases.mariadb.probes.liveness.period
            timeout_seconds       = local.databases.mariadb.probes.liveness.timeout
            failure_threshold     = local.databases.mariadb.probes.liveness.failure_threshold
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "mariadb-${each.key}-storage"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = local.databases.mariadb.storage_size
          }
        }
      }
    }

    update_strategy {
      type = "RollingUpdate"
      rolling_update {
        partition = 0
      }
    }
  }
}

# MongoDB StatefulSet for both environments
resource "kubernetes_stateful_set" "mongodb" {
  for_each = toset(local.namespaces)
  
  metadata {
    name      = "mongodb"
    namespace = each.key
  }

  spec {
    service_name = "mongodb"
    replicas     = 1

    selector {
      match_labels = {
        app = "mongodb"
      }
    }

    template {
      metadata {
        labels = {
          app = "mongodb"
        }
      }

      spec {
        container {
          name  = "mongodb"
          image = local.databases.mongodb.image

          env {
            name = "MONGO_INITDB_ROOT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongodb_secrets[each.key].metadata[0].name
                key  = "mongodb-root-username"
              }
            }
          }
          env {
            name = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.mongodb_secrets[each.key].metadata[0].name
                key  = "mongodb-root-password"
              }
            }
          }

          port {
            container_port = local.databases.mongodb.port
          }

          volume_mount {
            name       = "mongodb-${each.key}-storage"
            mount_path = "/data/db"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "mongodb-${each.key}-storage"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = local.databases.mongodb.storage_size
          }
        }
      }
    }
  }
}

# Redis StatefulSet for both environments
resource "kubernetes_stateful_set" "redis" {
  for_each = toset(local.namespaces)
  
  metadata {
    name      = "redis"
    namespace = each.key
  }

  spec {
    service_name = "redis"
    replicas     = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = local.databases.redis.image

          port {
            container_port = local.databases.redis.port
          }

          volume_mount {
            name       = "redis-${each.key}-storage"
            mount_path = "/data"
          }

          args = [
            "--requirepass", 
            "$(REDIS_PASSWORD)"
          ]
          
          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.redis_secrets[each.key].metadata[0].name
                key  = "redis-password"
              }
            }
          }
          
          readiness_probe {
            exec {
              command = local.databases.redis.probes.readiness.command
            }
            initial_delay_seconds = local.databases.redis.probes.readiness.initial_delay
            period_seconds        = local.databases.redis.probes.readiness.period
            timeout_seconds       = local.databases.redis.probes.readiness.timeout
            failure_threshold     = local.databases.redis.probes.readiness.failure_threshold
          }

          liveness_probe {
            exec {
              command = local.databases.redis.probes.liveness.command
            }
            initial_delay_seconds = local.databases.redis.probes.liveness.initial_delay
            period_seconds        = local.databases.redis.probes.liveness.period
            timeout_seconds       = local.databases.redis.probes.liveness.timeout
            failure_threshold     = local.databases.redis.probes.liveness.failure_threshold
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "redis-${each.key}-storage"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = local.databases.redis.storage_size
          }
        }
      }
    }
  }
}

# Database Services for both environments
resource "kubernetes_service" "database_services" {
  for_each = {
    for pair in setproduct(local.namespaces, ["postgres", "mariadb", "mongodb", "redis"]) : 
    "${pair[0]}-${pair[1]}" => {
      namespace = pair[0]
      db_type = pair[1]
    }
  }

  metadata {
    name      = each.value.db_type
    namespace = each.value.namespace
  }
  
  spec {
    selector = {
      app = each.value.db_type
    }
    
    port {
      port        = local.databases[each.value.db_type].port
      target_port = local.databases[each.value.db_type].port
    }
  }

  depends_on = [ 
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]
}
