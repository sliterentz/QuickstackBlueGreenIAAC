# Centralized locals for the entire project
locals {
  namespaces = ["${var.k3s_default_namespace}-blue", "${var.k3s_default_namespace}-green"]
  
  # Database configurations
  databases = {
    postgres = {
      image = "postgres:latest"
      port = 5432
      storage_size = "2Gi"
      db_name = "${var.postgres_database}"
      user = "postgres"
      password_resource = "${var.postgres_root_password}"
      app_user = "${var.postgres_username}"
      app_password_resource = "${var.postgres_password}"
      probes = {
        readiness = {
          command = ["pg_isready", "-U", "postgres"]
          initial_delay = 5
          period = 10
          timeout = 5
          failure_threshold = 6
        }
        liveness = {
          command = ["pg_isready", "-U", "postgres"]
          initial_delay = 15
          period = 10
          timeout = 5
          failure_threshold = 6
        }
      }
    }
    mariadb = {
      image = "mariadb:10.11"
      port = 3306
      storage_size = "2Gi"
      db_name = "${var.mariadb_database}"
      user = "${var.mariadb_username}"
      password = "${var.mariadb_password}"
      root_password_resource = "${var.mariadb_root_password}"
      probes = {
        readiness = {
          command = ["sh", "-c", "mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD"]
          initial_delay = 5
          period = 10
          timeout = 1
          failure_threshold = 3
        }
        liveness = {
          command = ["sh", "-c", "mysqladmin ping -u root -p$MYSQL_ROOT_PASSWORD"]
          initial_delay = 30
          period = 10
          timeout = 5
          failure_threshold = 3
        }
      }
    }
    mongodb = {
      image = "mongo:4.4"
      port = 27017
      storage_size = "1Gi"
      root_user = "${var.mongo_username}"
      root_password_resource = "${var.mongo_password}"
    }
    redis = {
      image = "redis:6.2-alpine"
      port = 6379
      storage_size = "1Gi"
      password_resource = "${var.redis_password}"
      probes = {
        readiness = {
          command = ["sh", "-c", "redis-cli -a $REDIS_PASSWORD ping | grep PONG"]
          initial_delay = 5
          period = 10
          timeout = 5
          failure_threshold = 3
        }
        liveness = {
          command = ["sh", "-c", "redis-cli -a $REDIS_PASSWORD ping | grep PONG"]
          initial_delay = 15
          period = 10
          timeout = 5
          failure_threshold = 3
        }
      }
    }
  }
}
