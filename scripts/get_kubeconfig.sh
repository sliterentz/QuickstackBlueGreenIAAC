#!/bin/bash
# ==============================================================================
# Script: get_kubeconfig.sh
# Deskripsi: Mendeteksi lokasi file kubeconfig secara otomatis di lingkungan Ubuntu/KVM.
# Alur Kerja:
#   1. Memeriksa environment variable KUBECONFIG.
#   2. Memeriksa lokasi default user (~/.kube/config).
#   3. Memeriksa lokasi default K3s (/etc/rancher/k3s/k3s.yaml).
#   4. Memeriksa file lokal 'kubeconfig' di direktori modul.
#   5. Mengembalikan hasil dalam format JSON untuk Terraform external data source.
# ==============================================================================

set -e

# Fungsi logging ke stderr agar tidak mengganggu output JSON
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [KUBECONFIG-SEARCH] $1" >&2
}

# Inisialisasi variabel path
KUBE_CONFIG_PATH="./kubeconfig"
HOME_DIR="${HOME:-/home/ubuntu}" # Default ke /home/ubuntu jika HOME tidak set

log "Memulai pencarian file kubeconfig..."

# 1. Periksa Environment Variable KUBECONFIG
if [ -n "$KUBECONFIG" ]; then
    log "Memeriksa env var KUBECONFIG: $KUBECONFIG"
    IFS=':' read -ra PATHS <<< "$KUBECONFIG"
    for p in "${PATHS[@]}"; do
        if [ -f "$p" ]; then
            KUBE_CONFIG_PATH="$p"
            log "Ditemukan via KUBECONFIG: $KUBE_CONFIG_PATH"
            break
        fi
    done
fi

# 2. Periksa Lokasi Default ~/.kube/config
if [ -z "$KUBE_CONFIG_PATH" ]; then
    DEFAULT_PATH="$HOME_DIR/.kube/config"
    log "Memeriksa lokasi default: $DEFAULT_PATH"
    if [ -f "$DEFAULT_PATH" ]; then
        KUBE_CONFIG_PATH="$DEFAULT_PATH"
        log "Ditemukan di lokasi default: $KUBE_CONFIG_PATH"
    fi
fi

# 3. Periksa Lokasi Default K3s (Sering digunakan di Ubuntu KVM)
if [ -z "$KUBE_CONFIG_PATH" ]; then
    K3S_PATH="/etc/rancher/k3s/k3s.yaml"
    log "Memeriksa lokasi K3s: $K3S_PATH"
    if [ -f "$K3S_PATH" ]; then
        KUBE_CONFIG_PATH="$K3S_PATH"
        log "Ditemukan di lokasi K3s: $KUBE_CONFIG_PATH"
    fi
fi

# 4. Periksa File Lokal di Modul (Fallback terakhir)
if [ -z "$KUBE_CONFIG_PATH" ]; then
    LOCAL_PATH="$(pwd)/kubeconfig"
    log "Memeriksa file lokal: $LOCAL_PATH"
    if [ -f "$LOCAL_PATH" ]; then
        KUBE_CONFIG_PATH="$LOCAL_PATH"
        log "Ditemukan di file lokal: $KUBE_CONFIG_PATH"
    fi
fi

# Final Check & Output
if [ -n "$KUBE_CONFIG_PATH" ]; then
    log "Pencarian selesai. Menggunakan: $KUBE_CONFIG_PATH"
    
    # Verifikasi apakah host cluster dapat dijangkau
    # SERVER_URL=$(grep "server:" "$KUBE_CONFIG_PATH" | awk '{print $2}')
    # HOST=$(echo $SERVER_URL | sed -e 's|^[^/]*//||' -e 's|:[0-9]*$||')
    # PORT=$(echo $SERVER_URL | sed -e 's|^.*:||')
    
    # log "Memeriksa konektivitas ke $HOST:$PORT..."
    # if ! timeout 2 bash -c "true > /dev/tcp/$HOST/$PORT" 2>/dev/null; then
    #     log "PERINGATAN: Cluster $HOST:$PORT tidak dapat dijangkau. Mengalihkan ke mode offline."
    #     echo "{\"kube_config_path\": \"NOT_FOUND\"}"
    #     exit 0
    # fi

    # Pastikan file dapat dibaca
    if [ ! -r "$KUBE_CONFIG_PATH" ]; then
        log "PERINGATAN: File ditemukan tapi tidak dapat dibaca (Permission Denied)."
    fi
    echo "{\"kube_config_path\": \"$KUBE_CONFIG_PATH\"}"
    exit 0
else
    log "ERROR: Tidak dapat menemukan file kubeconfig di lokasi manapun."
    # Mengembalikan JSON kosong atau error untuk Terraform
    echo "{\"kube_config_path\": \"NOT_FOUND\"}"
    exit 0 # Exit 0 agar Terraform bisa menangani logic 'NOT_FOUND' di locals
fi
