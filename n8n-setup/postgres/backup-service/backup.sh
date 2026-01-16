#!/bin/sh

# Konfigurasi
BACKUP_DIR="/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/n8n_db_backup_$TIMESTAMP.sql.gz"
RETENTION_DAYS=7

echo "Starting backup process at $(date)..."

# Pastikan direktori backup ada
mkdir -p $BACKUP_DIR

# Eksekusi Backup
# Menggunakan variabel environment PGHOST, PGUSER, PGPASSWORD dari container
pg_dump -h $PGHOST -U $PGUSER -d $PGDATABASE | gzip > $BACKUP_FILE

if [ $? -eq 0 ]; then
  echo "Backup successful: $BACKUP_FILE"
else
  echo "Backup FAILED!"
  exit 1
fi

# Rotasi Backup (Hapus yang lebih tua dari RETENTION_DAYS)
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find $BACKUP_DIR -name "n8n_db_backup_*.sql.gz" -mtime +$RETENTION_DAYS -exec rm {} \;

echo "Backup process completed."
