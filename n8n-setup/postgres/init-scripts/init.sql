-- Script ini akan dijalankan otomatis saat container PostgreSQL pertama kali dibuat
-- Pastikan variabel environment POSTGRES_USER, POSTGRES_DB sudah sesuai di docker-compose

-- Catatan: User dan DB default sudah dibuat oleh image postgres berdasarkan env vars.
-- Script ini fokus pada penyesuaian hak akses dan ekstensi tambahan.

-- Mengaktifkan ekstensi untuk monitoring
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Memastikan user n8n memiliki akses penuh (jika user dibuat manual, tapi di sini kita pakai env var)
-- ALTER USER n8n_user WITH SUPERUSER; -- Hati-hati dengan superuser di production

-- Optimasi parameter session untuk user n8n (opsional)
ALTER ROLE n8n_user SET client_encoding TO 'utf8';
ALTER ROLE n8n_user SET default_transaction_isolation TO 'read committed';
ALTER ROLE n8n_user SET timezone TO 'UTC';

-- Membuat tabel log khusus jika ingin memisahkan dari n8n core (opsional)
-- CREATE TABLE IF NOT EXISTS custom_audit_log (...);
