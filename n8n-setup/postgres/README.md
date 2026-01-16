# Dokumentasi Database n8n (PostgreSQL)

## 🗄️ Spesifikasi Setup
- **Versi**: PostgreSQL 16 (Alpine)
- **Database**: `n8n` (Dikonfigurasi via .env)
- **User**: `n8n` (Dikonfigurasi via .env)
- **Backup**: Otomatis setiap hari pukul 02:00 (Retensi 7 hari)
- **Optimasi**: Disesuaikan untuk VM dengan RAM ~4GB (max_connections=200, shared_buffers=1GB)

## 🚀 Cara Menjalankan
Database ini adalah bagian dari stack `docker-compose.yml`.
```bash
cd n8n-setup
docker-compose up -d postgres postgres-backup
```

## 🔍 Verifikasi Instalasi

### 1. Cek Status Container
Pastikan container database dan backup berjalan:
```bash
docker-compose ps postgres postgres-backup
```
Status harus `Up (healthy)`.

### 2. Cek Koneksi & Konfigurasi
Masuk ke container postgres dan verifikasi parameter:
```bash
docker-compose exec postgres psql -U n8n -d n8n -c "SHOW max_connections;"
docker-compose exec postgres psql -U n8n -d n8n -c "SHOW shared_buffers;"
```
Output harus menunjukkan `200` dan `1GB`.

### 3. Test Backup Manual
Anda bisa memicu backup secara manual untuk memastikan skrip bekerja:
```bash
docker-compose exec postgres-backup /usr/local/bin/backup.sh
```
Cek hasilnya di folder host:
```bash
ls -lh postgres/backups/
```

## 📈 Monitoring
Ekstensi `pg_stat_statements` sudah diaktifkan untuk melacak query yang lambat.
Untuk melihat top 5 query yang paling memakan resource CPU:
```sql
SELECT 
    query, 
    calls, 
    total_exec_time, 
    mean_exec_time 
FROM pg_stat_statements 
ORDER BY total_exec_time DESC 
LIMIT 5;
```

## 🔧 Troubleshooting
- **Koneksi Ditolak**: Pastikan `docker-compose.yml` network sudah benar dan password di `.env` sinkron.
- **Backup Gagal**: Cek permission folder `postgres/backups` di host. Pastikan user docker bisa menulis ke sana.
