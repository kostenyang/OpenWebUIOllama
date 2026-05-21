#!/usr/bin/env bash
# Install Open WebUI + mcpo from an offline bundle.
#   sudo bash install-openwebui-offline.sh <bundle_dir>
#
# bundle_dir contents (built by prep-openwebui-bundle.sh):
#   open-webui.tar   docker image
#   mcpo.tar         docker image
#   docker-compose.yml
#   mcpo/{config.json,certs/}
#   functions/        (optional)
#
# Pre-req on target: docker + docker compose (Ubuntu 20.04 install in
# parent README §2; or use deb bundle separately — out of scope here).
set -euo pipefail

BUNDLE="${1:?usage: $0 <bundle_dir>}"
[ -d "$BUNDLE" ] || { echo "$BUNDLE not a dir"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }
INSTALL_DIR="${INSTALL_DIR:-/opt/open-webui}"

command -v docker >/dev/null || { echo "docker missing — install Docker first"; exit 1; }

cd "$BUNDLE"

echo "== 1. docker load images =="
docker load -i open-webui.tar
docker load -i mcpo.tar
docker images | grep -E "open-webui|mcpo" | head -5

echo "== 2. lay down /opt/open-webui =="
mkdir -p "$INSTALL_DIR/mcpo/certs"
cp docker-compose.yml "$INSTALL_DIR/docker-compose.yml"
cp mcpo/config.json "$INSTALL_DIR/mcpo/config.json"
[ -d mcpo/certs ] && cp -r mcpo/certs/. "$INSTALL_DIR/mcpo/certs/" 2>/dev/null || true
[ -d functions ]  && cp -r functions     "$INSTALL_DIR/"            2>/dev/null || true

echo "== 3. docker compose up -d =="
cd "$INSTALL_DIR"
docker compose up -d

# wait for openwebui health
for i in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ 2>/dev/null || true)
    [ "$code" = "200" ] && break
    sleep 2
done

echo "== 4. status =="
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "open-webui|mcpo"
echo
echo "Open WebUI:  http://$(hostname -I | awk '{print $1}'):3000/"
echo "mcpo OpenAPI: http://$(hostname -I | awk '{print $1}'):8000/<server-name>/openapi.json"

cat <<EOF

== DONE — bring-up complete ==

Next (wire-up):
  bash wire-ollama.sh $(hostname -I | awk '{print $1}') http://<ollama-ip>:11434
  bash wire-mcpo.sh   $(hostname -I | awk '{print $1}') <vcf-mcp-ip> <vcf-mcp-token>

Note: the FIRST user that opens http://<ip>:3000/ in a browser becomes
admin automatically. Open it yourself first before sharing the URL.

If you also need Docker on a fresh box, see the parent repo README §2
(get.docker.com sets up apt repos but fails on Ubuntu 20.04 because of
docker-model-plugin; the workaround is apt-get install -y the deb-line
packages directly).
EOF
