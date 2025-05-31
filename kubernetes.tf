# Create namespaces
resource "kubernetes_namespace" "blue" {
  metadata {
    name = "${var.k3s_default_namespace}-blue"
  }
}

resource "kubernetes_namespace" "green" {
  metadata {
    name = "${var.k3s_default_namespace}-green"
  }
}

# Generate random passwords
resource "random_password" "postgres_password" {
  length  = 16
  special = false
}

resource "random_password" "app_user_password" {
  length  = 16
  special = false
}

resource "random_password" "mariadb_password" {
  length  = 16
  special = false
}

resource "random_password" "mongodb_password" {
  length  = 16
  special = false
}

resource "random_password" "redis_password" {
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
    "init.sql" = <<-EOT
      CREATE ROLE '${local.databases.postgres.app_user}' WITH LOGIN PASSWORD '${local.databases.postgres.app_password_resource}';
      CREATE DATABASE '${local.databases.postgres.db_name}';
      GRANT ALL PRIVILEGES ON DATABASE '${local.databases.postgres.db_name}' TO '${local.databases.postgres.app_user}';

      -- Connect to the '${local.databases.postgres.db_name}' to set schema permissions
      \c '${local.databases.postgres.db_name}';
      
      -- Grant permissions on the public schema
      GRANT ALL ON SCHEMA public TO '${local.databases.postgres.app_user}';
      
      -- Grant permissions on all tables in the public schema
      GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO '${local.databases.postgres.app_user}';
      GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO '${local.databases.postgres.app_user}';
      GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO '${local.databases.postgres.app_user}';
      
      -- Set default privileges for future objects
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO '${local.databases.postgres.app_user}';
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO '${local.databases.postgres.app_user}';
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO '${local.databases.postgres.app_user}';
      
      -- Make '${local.databases.postgres.app_user}' a superuser and allow creating databases
      ALTER ROLE '${local.databases.postgres.app_user}' CREATEDB;
      ALTER USER '${local.databases.postgres.app_user}' WITH SUPERUSER;

      -- Create Harbor databases
      CREATE DATABASE harbor_core;
      CREATE DATABASE harbor_clair;
      CREATE DATABASE harbor_notary_server;
      CREATE DATABASE harbor_notary_signer;
      
      -- Grant permissions to postgres user for Harbor databases
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
    "postgres-password" = base64encode(random_password.postgres_password.result)
    "app-user"          = local.databases.postgres.app_user
    "app-user-password" = base64encode(random_password.app_user_password.result)
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
    "mariadb-root-password" = base64encode(random_password.mariadb_password.result)
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
    "mongodb-root-username" = base64encode(local.databases.mongodb.root_user)
    "mongodb-root-password" = base64encode(random_password.mongodb_password.result)
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
    "redis-password" = base64encode(random_password.redis_password.result)
  }
}
