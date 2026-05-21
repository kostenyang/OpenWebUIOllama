#!/usr/bin/env bash
# Build an offline-install bundle for the Open WebUI + mcpo stack.
#   bash prep-openwebui-bundle.sh [out_dir]
#
# Run on a machine that:
#   - has Docker (any recent version),
#   - has internet (to docker pull),
#   - already has the openwebui repo cloned (or just the compose + mcpo files).
#
# Bundle contents (~2.7 GB):
#   open-webui.tar       docker save ghcr.io/open-webui/open-webui:main
#   mcpo.tar             docker save ghcr.io/open-webui/mcpo:main
#   docker-debs/         docker-ce + cli + containerd + compose-plugin + buildx (.deb)
#                        so the target doesn't need internet to install Docker
#   docker-keyring.gpg   apt signing key (only if you want to also wire apt; install
#                        doesn't need this — dpkg -i suffices)
#   docker-compose.yml   compose entry (copied from the openwebui repo)
#   mcpo/                config.json + certs/  (placeholder; install will customise)
#   functions/           Open WebUI Function pipes (Claude provider, etc.)
#   install-offline.sh   sibling installer
#   README.txt           who built it, when, what to do next
#
# Why docker save instead of pulling on the target:
#   - target is air-gapped (no ghcr.io)
#   - even a private registry mirror is extra ops; tarball Just Works
set -euo pipefail

OUT="${1:-./openwebui-offline}"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OPENWEBUI_REPO="${OPENWEBUI_REPO:-/opt/open-webui}"   # source of compose / mcpo / functions

OPENWEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
MCPO_IMAGE="ghcr.io/open-webui/mcpo:main"

mkdir -p "$OUT"

echo "== 1. pull + save open-webui image =="
docker pull "$OPENWEBUI_IMAGE"
docker save "$OPENWEBUI_IMAGE" -o "$OUT/open-webui.tar"
ls -lh "$OUT/open-webui.tar"

echo "== 2. pull + save mcpo image =="
docker pull "$MCPO_IMAGE"
docker save "$MCPO_IMAGE" -o "$OUT/mcpo.tar"
ls -lh "$OUT/mcpo.tar"

echo "== 3. copy compose + mcpo config + functions =="
mkdir -p "$OUT/mcpo/certs" "$OUT/functions"
if [ -f "$OPENWEBUI_REPO/docker-compose.yml" ]; then
    cp "$OPENWEBUI_REPO/docker-compose.yml" "$OUT/docker-compose.yml"
elif [ -f "$REPO_DIR/runbook/templates/docker-compose.yml" ]; then
    cp "$REPO_DIR/runbook/templates/docker-compose.yml" "$OUT/docker-compose.yml"
else
    echo "  WARN: no docker-compose.yml found; generating a minimal one"
    cat > "$OUT/docker-compose.yml" <<'COMPOSE'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: always
    ports: ["3000:8080"]
    volumes: ["open-webui:/app/backend/data"]
    environment:
      - WEBUI_NAME=Open WebUI
      # - OLLAMA_BASE_URL=http://<ollama-host>:11434   ← wire-ollama.sh fills this

  mcpo:
    image: ghcr.io/open-webui/mcpo:main
    container_name: mcpo
    restart: always
    ports: ["8000:8000"]
    volumes:
      - ./mcpo/config.json:/app/config.json:ro
      - ./mcpo/certs/vcf-mcp.pem:/certs/vcf-mcp.pem:ro
    environment:
      - SSL_CERT_FILE=/certs/vcf-mcp.pem
      - REQUESTS_CA_BUNDLE=/certs/vcf-mcp.pem
    command: ["--host","0.0.0.0","--port","8000",
              "--api-key","openwebui-mcpo-secret",
              "--config","/app/config.json"]

volumes:
  open-webui:
COMPOSE
fi

# mcpo placeholder config (wire-mcpo.sh fills with real upstream URL/token)
cat > "$OUT/mcpo/config.json" <<'JSON'
{
  "mcpServers": {
    "vcf-lab": {
      "type": "sse",
      "url": "https://CHANGEME:7000/sse",
      "headers": { "Authorization": "Bearer CHANGEME" }
    }
  }
}
JSON

# functions (Anthropic Claude pipe, etc.) — best-effort copy
if [ -d "$OPENWEBUI_REPO/functions" ]; then
    cp -r "$OPENWEBUI_REPO/functions/." "$OUT/functions/" 2>/dev/null || true
fi

echo "== 4. download Docker .deb packages =="
# Use the official Docker apt repo so the target can dpkg -i offline.
# We trigger get.docker.com so it sets up /etc/apt/sources.list.d/docker.list
# (it's safe to let the script fail at docker-model-plugin; the repo gets added first).
DOCKER_DEBS=( docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin )
if ! ls /etc/apt/sources.list.d/docker.list >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || true   # may fail at docker-model-plugin — apt repo is what we want
fi
apt-get update -qq

mkdir -p "$OUT/docker-debs"
# download-only keeps the deps too; we then move them out of /var/cache
apt-get install -y --download-only --reinstall "${DOCKER_DEBS[@]}" >/dev/null
# also pull pure transitive deps that may not yet be in the cache from this run
for pkg in "${DOCKER_DEBS[@]}"; do
    apt-cache depends "$pkg" 2>/dev/null | awk '/Depends:/ {print $2}' | \
        grep -v '<' | xargs -r -n1 apt-get install -y --download-only --reinstall 2>/dev/null || true
done
cp /var/cache/apt/archives/*.deb "$OUT/docker-debs/" 2>/dev/null || true
# keep just docker + its direct deps; drop docker-model-plugin (focal won't have it,
# and we don't want it either — it's the very thing that breaks the online install).
rm -f "$OUT/docker-debs/docker-model-plugin"*.deb 2>/dev/null || true
ls -1 "$OUT/docker-debs/" | head -20
du -sh "$OUT/docker-debs"

echo "== 5. installer + readme =="
cp "$(dirname "$0")/install-openwebui-offline.sh" "$OUT/install-offline.sh" 2>/dev/null || \
    echo "  (install-openwebui-offline.sh not found at $(dirname "$0"); copy it manually)"
chmod +x "$OUT/install-offline.sh" 2>/dev/null || true

cat > "$OUT/README.txt" <<EOF
Open WebUI + mcpo offline bundle
================================
Built: $(date -u +%FT%TZ) on $(hostname)

Install on target (root):
    tar xzf openwebui-offline-bundle.tgz -C /tmp
    bash /tmp/openwebui-offline/install-offline.sh /tmp/openwebui-offline

What it does:
  1. docker load < open-webui.tar
  2. docker load < mcpo.tar
  3. copy docker-compose.yml + mcpo/ + functions/ to /opt/open-webui/
  4. docker compose up -d  (starts both services)
  5. report status + next steps (wire-ollama.sh, wire-mcpo.sh)

After install, wire up:
  bash wire-ollama.sh <openwebui_host> <ollama_url> [<ollama_url> ...]
  bash wire-mcpo.sh   <openwebui_host> <mcp_host> <mcp_token> [<owui_to_mcpo_token>]
EOF

echo "== DONE =="
du -sh "$OUT"
echo "Next:"
echo "  tar czf openwebui-offline-bundle.tgz -C $(dirname "$OUT") $(basename "$OUT")"
echo "  scp openwebui-offline-bundle.tgz root@<openwebui-target>:/tmp/"
