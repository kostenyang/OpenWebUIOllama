#!/usr/bin/env bash
# Wire mcpo on <openwebui_host> to a vcf-mcp upstream:
#   1. scp upstream cert.pem to /opt/open-webui/mcpo/certs/vcf-mcp.pem
#   2. write /opt/open-webui/mcpo/config.json with the right URL + token
#   3. (if --api-key given) set OpenWebUI↔mcpo token in docker-compose.yml
#   4. docker compose up -d mcpo  (recreate)
#   5. verify schema fetch + tool call
#
# Usage:
#   bash wire-mcpo.sh <openwebui_host> <mcp_host> <mcp_token> [<owui_to_mcpo_token>]
#
# Example:
#   bash wire-mcpo.sh 10.0.0.64 10.0.0.65 ILnx5...token openwebui-mcpo-secret
#
# After this, in Open WebUI UI:
#   Admin Panel → Settings → Tools → + Add
#     URL:    http://<openwebui_host>:8000/vcf-lab
#     Bearer: <owui_to_mcpo_token>   (default: openwebui-mcpo-secret)
set -euo pipefail

OWUI="${1:?usage: $0 <openwebui_host> <mcp_host> <mcp_token> [<owui_to_mcpo_token>]}"
MCP="${2:?need mcp_host}"
MCPTOKEN="${3:?need mcp_token}"
OWUI_TOKEN="${4:-openwebui-mcpo-secret}"

SSHPASS_BIN=$(command -v sshpass || true)
SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -o StrictHostKeyChecking=no"

# Use sshpass if available + DEFAULT_SSH_PASS env var set; otherwise rely on key auth.
if [ -n "$SSHPASS_BIN" ] && [ -n "${DEFAULT_SSH_PASS:-}" ]; then
    SSH="sshpass -p $DEFAULT_SSH_PASS $SSH"
    SCP="sshpass -p $DEFAULT_SSH_PASS $SCP"
fi

run_owui() {
    if [ "$OWUI" = "localhost" ] || [ "$OWUI" = "127.0.0.1" ]; then
        bash -c "$1"
    else
        $SSH "root@$OWUI" "$1"
    fi
}

echo "== 1. fetch upstream cert from $MCP =="
TMP=$(mktemp -d)
$SCP "root@$MCP:/opt/vcf-mcp/cert.pem" "$TMP/vcf-mcp.pem"
ls -la "$TMP/vcf-mcp.pem"

echo "== 2. ship cert + write config.json on $OWUI =="
# Defensive: if the target path is a directory (Docker bind-mount gotcha when
# the file didn't exist at compose-up time), nuke it first.
run_owui "if [ -d /opt/open-webui/mcpo/certs/vcf-mcp.pem ]; then \
    echo '  removing stale cert directory'; \
    rm -rf /opt/open-webui/mcpo/certs/vcf-mcp.pem; \
fi"
$SCP "$TMP/vcf-mcp.pem" "root@$OWUI:/opt/open-webui/mcpo/certs/vcf-mcp.pem"
rm -rf "$TMP"

run_owui "mkdir -p /opt/open-webui/mcpo && cat > /opt/open-webui/mcpo/config.json <<JSON
{
  \"mcpServers\": {
    \"vcf-lab\": {
      \"type\": \"sse\",
      \"url\": \"https://$MCP:7000/sse\",
      \"headers\": {
        \"Authorization\": \"Bearer $MCPTOKEN\"
      }
    }
  }
}
JSON
chmod 600 /opt/open-webui/mcpo/config.json"

echo "== 3. (optional) align OpenWebUI↔mcpo token in compose =="
run_owui "cd /opt/open-webui && cp docker-compose.yml docker-compose.yml.bak.\$(date +%s) && \
sed -i 's|\"--api-key\",\"[^\"]*\"|\"--api-key\",\"$OWUI_TOKEN\"|' docker-compose.yml && \
grep -E 'api-key' docker-compose.yml | head -2"

echo "== 4. recreate mcpo =="
run_owui "cd /opt/open-webui && docker compose up -d mcpo 2>&1 | tail -5"

echo "== 5. verify =="
# give mcpo a few seconds to connect upstream
sleep 5
run_owui "echo '--- mcpo log (last 10) ---'; docker logs mcpo --tail 10 2>&1 | grep -iE 'connected|error|fail' || true"
run_owui "echo '--- /openapi.json tool count ---'; \
curl -s -H 'Authorization: Bearer $OWUI_TOKEN' http://127.0.0.1:8000/vcf-lab/openapi.json | \
python3 -c 'import json,sys; print(len(json.load(sys.stdin).get(\"paths\",{})), \"tools\")'"
run_owui "echo '--- live tool call: ping_host 10.0.0.1 ---'; \
curl -s -X POST -H 'Authorization: Bearer $OWUI_TOKEN' -H 'Content-Type: application/json' \
  -d '{\"host\":\"10.0.0.1\",\"count\":1}' http://127.0.0.1:8000/vcf-lab/ping_host | head -c 300"

cat <<EOF


== DONE ==
mcpo:        http://$OWUI:8000/vcf-lab
upstream:    https://$MCP:7000/sse
OWUI token:  $OWUI_TOKEN

Add to Open WebUI UI:
  Admin Panel → Settings → Tools → + Add
    URL:    http://$OWUI:8000/vcf-lab
    Bearer: $OWUI_TOKEN
EOF
