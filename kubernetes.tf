# Create namespaces
resource "kubernetes_namespace" "blue" {
  count      = var.enable_blue_environment ? 1 : 0
  depends_on = [null_resource.wait_for_cluster]
  metadata {
    name = "${var.k3s_default_namespace}-blue"
  }

  timeouts {
    delete = "15m"
  }
}

resource "kubernetes_namespace" "green" {
  depends_on = [null_resource.wait_for_cluster]
  metadata {
    name = "${var.k3s_default_namespace}-green"
  }

  timeouts {
    delete = "15m"
  }
}

resource "random_password" "mariadb_password" {
  length  = 16
  special = false
}

resource "random_password" "mongodb_password" {
  length  = 16
  special = false
}


# Create PostgreSQL init script ConfigMaps for both namespaces
resource "kubernetes_config_map" "postgres_init_script" {
  for_each = toset(local.namespaces)

  metadata {
    name      = "postgres-${each.key}-init-script"
    namespace = each.key
  }

  depends_on = [
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]

  data = {
    "00-pg-hba.sh" = <<-EOT
      #!/bin/sh
      set -eu

      HBA="$${PGDATA}/pg_hba.conf"
      CONF="$${PGDATA}/postgresql.conf"

      if [ -f "$HBA" ]; then
        grep -q "^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+10\\.42\\.0\\.0/16" "$HBA" || echo "host all all 10.42.0.0/16 scram-sha-256" >> "$HBA"
        grep -q "^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+10\\.43\\.0\\.0/16" "$HBA" || echo "host all all 10.43.0.0/16 scram-sha-256" >> "$HBA"
      fi

      if [ -f "$CONF" ]; then
        grep -q "^listen_addresses" "$CONF" || echo "listen_addresses='*'" >> "$CONF"
      fi
    EOT
    "init.sql"     = <<-EOT
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${local.databases.postgres.app_user}') THEN
          CREATE ROLE ${local.databases.postgres.app_user} WITH LOGIN PASSWORD '${local.databases.postgres.app_password_resource}';
          ALTER ROLE ${local.databases.postgres.app_user} CREATEDB;
          ALTER ROLE ${local.databases.postgres.app_user} SUPERUSER;
        END IF;
      END
      $$;

      SELECT format('CREATE DATABASE %I OWNER %I', '${local.databases.postgres.db_name}', '${local.databases.postgres.app_user}')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${local.databases.postgres.db_name}')
      \gexec

      SELECT format('CREATE DATABASE %I OWNER %I', 'n8n', '${local.databases.postgres.app_user}')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n')
      \gexec

      GRANT ALL PRIVILEGES ON DATABASE ${local.databases.postgres.db_name} TO ${local.databases.postgres.app_user};
      GRANT ALL PRIVILEGES ON DATABASE n8n TO ${local.databases.postgres.app_user};

      \c ${local.databases.postgres.db_name}
      GRANT ALL ON SCHEMA public TO ${local.databases.postgres.app_user};
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${local.databases.postgres.app_user};
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${local.databases.postgres.app_user};
      GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${local.databases.postgres.app_user};
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${local.databases.postgres.app_user};
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${local.databases.postgres.app_user};
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${local.databases.postgres.app_user};

      SELECT format('CREATE DATABASE %I', 'harbor_core')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'harbor_core')
      \gexec
      SELECT format('CREATE DATABASE %I', 'harbor_clair')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'harbor_clair')
      \gexec
      SELECT format('CREATE DATABASE %I', 'harbor_notary_server')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'harbor_notary_server')
      \gexec
      SELECT format('CREATE DATABASE %I', 'harbor_notary_signer')
      WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'harbor_notary_signer')
      \gexec

      GRANT ALL PRIVILEGES ON DATABASE harbor_core TO postgres;
      GRANT ALL PRIVILEGES ON DATABASE harbor_clair TO postgres;
      GRANT ALL PRIVILEGES ON DATABASE harbor_notary_server TO postgres;
      GRANT ALL PRIVILEGES ON DATABASE harbor_notary_signer TO postgres;
    EOT
  }
}

# Create secrets for all database types in both namespaces
resource "kubernetes_secret" "postgres_secrets" {
  for_each = toset(local.namespaces)

  metadata {
    name      = "postgres-secrets"
    namespace = each.key
  }

  depends_on = [
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]

  data = {
    "postgres-user"     = local.databases.postgres.user
    "postgres-password" = local.databases.postgres.password_resource
    "app-user"          = local.databases.postgres.app_user
    "app-user-password" = local.databases.postgres.app_password_resource
  }
}

resource "kubernetes_secret" "mariadb_secrets" {
  for_each = toset(local.namespaces)

  metadata {
    name      = "mariadb-secrets"
    namespace = each.key
  }

  depends_on = [
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]

  data = {
    "mariadb-user"          = local.databases.mariadb.user
    "mariadb-password"      = local.databases.mariadb.password
    "mariadb-root-password" = base64encode(local.databases.mariadb.root_password_resource)
  }

  type = "Opaque"
}

# Secrets for MongoDB
resource "kubernetes_secret" "mongodb_secrets" {
  for_each = toset(local.namespaces)

  metadata {
    name      = "mongodb-secrets"
    namespace = each.key
  }

  depends_on = [
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]

  data = {
    "mongodb-root-username" = local.databases.mongodb.root_user
    "mongodb-root-password" = local.databases.mongodb.root_password_resource
  }
}

# Secrets for Redis
resource "kubernetes_secret" "redis_secrets" {
  for_each = toset(local.namespaces)

  metadata {
    name      = "redis-secrets"
    namespace = each.key
  }

  depends_on = [
    kubernetes_namespace.blue,
    kubernetes_namespace.green
  ]

  data = {
    "redis-password" = local.databases.redis.password_resource
  }
}
