# Enterprise WhatsApp Bot Solution dengan n8n & OpenAI

Solusi otomasi lengkap untuk menangani pesan WhatsApp menggunakan AI, didukung oleh infrastruktur n8n yang scalable (Worker/Queue mode).

## 🚀 Fitur Utama
- **High Availability**: Menggunakan arsitektur Queue n8n dengan Redis & Postgres.
- **AI-Powered**: Integrasi OpenAI GPT-4 dengan manajemen konteks.
- **Multi-Media**: Mendukung teks, gambar, dan audio.
- **Secure**: Validasi signature WhatsApp dan enkripsi kredensial.

## 📂 Struktur Proyek
```text
n8n-setup/
├── docker-compose.yml   # Konfigurasi Main, Worker, Webhook, Redis, Postgres
├── .env.example         # Template konfigurasi environment
└── nginx/               # Konfigurasi Reverse Proxy
workflows/
└── whatsapp_ai_bot.json # Template workflow siap import
```

## 🛠 Panduan Setup Step-by-Step

### 1. Prasyarat
- Server Linux (Ubuntu/Debian) dengan Docker & Docker Compose terinstall.
- Domain yang sudah diarahkan ke IP server (misal: `n8n.example.com`).
- Akun Meta Developers & OpenAI API Key.

### 2. Instalasi Infrastruktur
1. Masuk ke direktori setup:
   ```bash
   cd n8n-setup
   ```
2. Salin dan edit file environment:
   ```bash
   cp .env.example .env
   nano .env
   ```
   *Isi kredensial DB, Domain, dan API Key Anda.*

3. Jalankan container:
   ```bash
   docker-compose up -d
   ```

### 3. Konfigurasi WhatsApp (Meta Developers)
1. Buat App di Meta Developers -> Pilih "WhatsApp".
2. Di menu **Configuration**, masukkan Callback URL: `https://n8n.example.com/webhook/whatsapp-webhook`.
3. Masukkan **Verify Token** (sesuai yang Anda set di workflow node "Verify Token").
4. Subscribe ke event `messages`.

### 4. Import Workflow
1. Buka dashboard n8n (`https://n8n.example.com`).
2. Buat Workflow baru -> Klik menu (tiga titik) -> **Import from File**.
3. Pilih file `workflows/whatsapp_ai_bot.json`.
4. Setup Credentials untuk **OpenAI** dan **WhatsApp** di dalam node masing-masing.
5. Aktifkan Workflow.

## 🔧 Troubleshooting
- **Webhook Error**: Cek logs container webhook: `docker-compose logs -f n8n-webhook`.
- **AI Timeout**: Jika respons AI lambat (>5s), pertimbangkan menurunkan `max_tokens` atau ganti model ke `gpt-3.5-turbo`.
- **Database Error**: Pastikan volume `db_storage` memiliki permission yang benar.

## 🛡 Security Checklist
- [ ] Ganti default password database di `.env`.
- [ ] Pastikan port 5678/6379 tidak terekspos ke publik (gunakan firewall/security group).
- [ ] Setup SSL/TLS yang valid (LetsEncrypt via Certbot atau Cloudflare).
