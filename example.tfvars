# Example variable values - rename to terraform.tfvars and update with your values

server_ips            = ["127.0.0.1"] #change it into your ip public node / server
ssh_username          = "changeme_username" #change it into your real username 
ssh_private_key_path  = "~/.ssh/id_rsa" 
k3s_default_namespace = "kube-system" #change it into namespace you want
argocd_hostname       = "argocd.localhost.local" #change it into valid domain for argocd server
argocd_admin_password = "strong_password" #change it into your admin argocd admin password
argocd_tls_secret_name = "simple-tls" #change it later
postgres_database = "sample_db" #change it later
postgres_root_password = "strong_db_password" #change it later
postgres_username = "changeme_username" #change it later
postgres_password = "strong_pass" #change it later
mariadb_database = "sample_db" #change it later
mariadb_username = "changeme_username" #change it later
mariadb_password = "strong_pass" #change it later
mariadb_root_password = "strong_db_password" #change it later
mongo_username = "admin"
mongo_password = "strong_db_password" #change it later
redis_password = "cache_pass" #change it later