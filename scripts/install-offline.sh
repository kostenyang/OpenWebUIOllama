#!/usr/bin/env bash
# Offline install Ollama on a fresh Ubuntu 20.04 VM (no internet).
#   sudo bash scripts/install-offline.sh <bundle_dir>
#
# bundle_dir must be the directory produced by prepare-offline-bundle.sh, containing:
#   ollama-linux-amd64.tar.zst
#   zstd.deb
#   models/
#   ollama.service.override.conf
set -euo pipefail

BUNDLE="${1:?usage: $0 <bundle_dir>}"
[ -d "$BUNDLE" ] || { echo "$BUNDLE not a dir"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

cd "$BUNDLE"

echo "== 1. dpkg -i zstd.deb =="
if ! command -v zstd >/dev/null; then
    dpkg -i zstd.deb || apt-get install -fy
fi

echo "== 2. extract ollama tarball =="
mkdir -p /usr/local/bin /usr/local/lib/ollama
zstd -d -c ollama-linux-amd64.tar.zst | tar -xf - -C /usr/local

echo "== 3. ollama user + group =="
getent group  ollama >/dev/null || groupadd  -r ollama
getent passwd ollama >/dev/null || useradd  -r -g ollama -d /usr/share/ollama -s /bin/false ollama
# add current user to ollama group? (skip; lab uses root)

echo "== 4. systemd unit =="
cat > /etc/systemd/system/ollama.service <<'UNIT'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=default.target
UNIT

# override → bind 0.0.0.0
install -d /etc/systemd/system/ollama.service.d
install -m 644 ollama.service.override.conf \
    /etc/systemd/system/ollama.service.d/override.conf

echo "== 5. copy model blobs =="
DST=/usr/share/ollama/.ollama/models
mkdir -p "$DST/blobs" "$DST/manifests"
if [ -d models ]; then
    cp -rn models/blobs/.     "$DST/blobs/"     2>/dev/null || true
    cp -rn models/manifests/. "$DST/manifests/" 2>/dev/null || true
fi
chown -R ollama:ollama /usr/share/ollama

echo "== 6. start ollama =="
systemctl daemon-reload
systemctl enable --now ollama

# wait for socket
for i in $(seq 1 20); do
    ss -tlnp 2>/dev/null | grep -q ':11434' && break
    sleep 1
done

echo "== 7. verify =="
ss -tlnp | grep ':11434' || { echo "NOT LISTENING"; journalctl -u ollama -n 30 --no-pager; exit 1; }
ollama list

cat <<EOF

== DONE ==
Ollama:  http://$(hostname -I | awk '{print $1}'):11434
EOF
