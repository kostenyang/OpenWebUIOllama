#!/usr/bin/env bash
# Wire one or more Ollama backends into Open WebUI by setting OLLAMA_BASE_URL.
#   bash wire-ollama.sh <openwebui_host> <ollama_url> [<ollama_url>...]
#
# Examples:
#   bash wire-ollama.sh 10.0.0.64 http://10.0.0.63:11434
#   bash wire-ollama.sh 10.0.0.64 http://10.0.0.63:11434 http://10.0.0.67:11434
#
# This edits /opt/open-webui/docker-compose.yml on <openwebui_host>:
#   - removes any existing OLLAMA_BASE_URL=… line
#   - inserts OLLAMA_BASE_URL=<urls joined by SEMICOLON>
#   - docker compose up -d open-webui (recreate to pick up env change)
#
# Semicolon, not comma: OpenWebUI multi-Ollama uses ';' (verified in lab,
# 2026-05). Comma would silently end up as one URL string and you'd see
# "connection refused" with no obvious reason.
#
# Assumes SSH-keyless root access to <openwebui_host>.  If not, scp the
# script over and run it locally on that host with empty <openwebui_host>.
set -euo pipefail

OWUI="${1:?usage: $0 <openwebui_host> <ollama_url> [<ollama_url>...]}"
shift
[ $# -ge 1 ] || { echo "give at least one ollama url"; exit 1; }

# join with ';' — OpenWebUI's multi-backend separator
JOINED=""
for u in "$@"; do
    [ -z "$JOINED" ] && JOINED="$u" || JOINED="$JOINED;$u"
done

# Run remotely (or locally if OWUI is empty / localhost)
ssh_or_local() {
    if [ -z "$OWUI" ] || [ "$OWUI" = "localhost" ] || [ "$OWUI" = "127.0.0.1" ]; then
        bash -c "$1"
    else
        ssh -o StrictHostKeyChecking=no "root@$OWUI" "$1"
    fi
}

REMOTE_SCRIPT=$(cat <<EOF
set -e
cd /opt/open-webui
cp docker-compose.yml docker-compose.yml.bak.\$(date +%s)

# remove existing OLLAMA_BASE_URL line(s)
sed -i '/OLLAMA_BASE_URL=/d' docker-compose.yml

# insert new one under WEBUI_NAME line (always present in our template)
sed -i '/- WEBUI_NAME=/a\      - OLLAMA_BASE_URL=$JOINED' docker-compose.yml

echo '== compose change =='
grep -E 'WEBUI_NAME|OLLAMA_BASE_URL' docker-compose.yml

echo '== restart open-webui =='
docker compose up -d open-webui 2>&1 | tail -5

# health check
for i in \$(seq 1 30); do
    code=\$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ 2>/dev/null || true)
    [ "\$code" = "200" ] && break
    sleep 2
done

echo '== verify backends seen =='
for u in \$(echo '$JOINED' | tr ';' '\n'); do
    n=\$(docker exec open-webui curl -sS -m 5 "\$u/api/tags" 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("models",[])))' 2>/dev/null || echo '?')
    echo "  \$u — \$n models"
done
EOF
)

ssh_or_local "$REMOTE_SCRIPT"

cat <<EOF

== DONE ==
Open WebUI now polls these Ollama backends:
  $(echo "$JOINED" | tr ';' '\n' | sed 's/^/  /')

Re-run to add more / change list — the script always rewrites the line.
Verify in browser: http://$OWUI:3000/ → New Chat → model dropdown.
EOF
