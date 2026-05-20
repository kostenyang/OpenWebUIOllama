#!/usr/bin/env bash
# Ollama online install — on a fresh Ubuntu 20.04 VM with internet access.
#   sudo bash scripts/install-online.sh [model]
#
# Default model: llama3.2:3b (~2 GB, CPU-friendly)
#
# What it does:
#   1. apt: zstd + curl (Ollama tarball is .tar.zst since 2024)
#   2. curl https://ollama.com/install.sh | sh  → /usr/local/bin/ollama + systemd unit
#   3. systemd override → OLLAMA_HOST=0.0.0.0:11434 (so OpenWebUI can reach it)
#   4. ollama pull <model>
#   5. quick API smoke test
set -euo pipefail

MODEL="${1:-llama3.2:3b}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

echo "== 1. apt: zstd curl =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zstd curl ca-certificates

echo "== 2. ollama install.sh =="
# pre-flight check
zstd --version >/dev/null || { echo "zstd missing"; exit 1; }
curl -fsSL https://ollama.com/install.sh -o /tmp/ollama-install.sh
bash /tmp/ollama-install.sh

echo "== 3. systemd override (bind 0.0.0.0) =="
install -d /etc/systemd/system/ollama.service.d
install -m 644 "$REPO_DIR/systemd/ollama.service.override.conf" \
               /etc/systemd/system/ollama.service.d/override.conf
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

# wait for socket
for i in $(seq 1 20); do
    ss -tlnp 2>/dev/null | grep -q ':11434' && break
    sleep 1
done
ss -tlnp | grep ':11434' || { echo "ollama not listening"; exit 1; }

echo "== 4. ollama pull $MODEL =="
ollama pull "$MODEL"
ollama list

echo "== 5. smoke test =="
curl -fsS http://127.0.0.1:11434/api/tags | head -c 500; echo
curl -fsS http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"reply ok\",\"stream\":false}" \
    | head -c 500; echo

cat <<EOF

== DONE ==
Ollama:  http://$(hostname -I | awk '{print $1}'):11434
Model:   $MODEL

Next:
  - Open WebUI Admin Panel → Settings → Connections → Ollama API
    URL: http://$(hostname -I | awk '{print $1}'):11434
EOF
