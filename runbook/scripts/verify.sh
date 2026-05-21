#!/usr/bin/env bash
# End-to-end health check for the LLM stack.
#   bash verify.sh
#
# Optional env overrides (defaults match home.lab):
#   OWUI_HOST=10.0.0.64
#   MCP_HOST=10.0.0.65
#   OLLAMA_HOSTS="10.0.0.63 10.0.0.67"
#   OWUI_TO_MCPO_TOKEN=openwebui-mcpo-secret
#
# Each step prints PASS / FAIL and a one-liner; exit code is 0 if all pass.
set -uo pipefail

OWUI_HOST="${OWUI_HOST:-10.0.0.64}"
MCP_HOST="${MCP_HOST:-10.0.0.65}"
OLLAMA_HOSTS="${OLLAMA_HOSTS:-10.0.0.63 10.0.0.67}"
OWUI_TO_MCPO_TOKEN="${OWUI_TO_MCPO_TOKEN:-openwebui-mcpo-secret}"

PASS=0; FAIL=0
chk() {
    local name="$1"; shift
    local detail
    if detail=$("$@" 2>&1); then
        printf '  ✅ %-45s %s\n' "$name" "$(echo "$detail" | head -1 | cut -c1-50)"
        PASS=$((PASS+1))
    else
        printf '  ❌ %-45s %s\n' "$name" "$(echo "$detail" | head -1 | cut -c1-50)"
        FAIL=$((FAIL+1))
    fi
}

echo "=== Ollama backends ==="
for h in $OLLAMA_HOSTS; do
    chk "$h:11434 reachable"      timeout 3 bash -c "</dev/tcp/$h/11434"
    chk "$h /api/tags returns json" bash -c "curl -fsS http://$h:11434/api/tags | python3 -c 'import json,sys; json.load(sys.stdin)'"
    chk "$h has at least 1 model"   bash -c "[ \$(curl -fsS http://$h:11434/api/tags | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"models\"]))') -gt 0 ]"
done

echo "=== vcf-mcp ==="
chk "$MCP_HOST:7000 reachable"       timeout 3 bash -c "</dev/tcp/$MCP_HOST/7000"
chk "$MCP_HOST SSE responds"         bash -c "curl -fsk -m 5 https://$MCP_HOST:7000/sse | head -1 | grep -q 'event:'"
chk "$MCP_HOST cert has SAN"         bash -c "echo | openssl s_client -connect $MCP_HOST:7000 -servername $MCP_HOST 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q 'IP Address'"

echo "=== OpenWebUI ==="
chk "$OWUI_HOST:3000 returns 200"    bash -c "[ \$(curl -fsS -o /dev/null -w '%{http_code}' http://$OWUI_HOST:3000/) = 200 ]"
chk "$OWUI_HOST docker open-webui up" bash -c "ssh -o StrictHostKeyChecking=no root@$OWUI_HOST 'docker ps --format \"{{.Names}}\" | grep -q open-webui'"

echo "=== mcpo ==="
chk "$OWUI_HOST:8000 reachable"      timeout 3 bash -c "</dev/tcp/$OWUI_HOST/8000"
chk "mcpo /openapi.json has tools"   bash -c "[ \$(curl -fsS -H 'Authorization: Bearer $OWUI_TO_MCPO_TOKEN' http://$OWUI_HOST:8000/vcf-lab/openapi.json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get(\"paths\",{})))') -gt 0 ]"
chk "mcpo → vcf-mcp live tool call"  bash -c "curl -fsS -X POST -H 'Authorization: Bearer $OWUI_TO_MCPO_TOKEN' -H 'Content-Type: application/json' -d '{\"host\":\"10.0.0.1\",\"count\":1}' http://$OWUI_HOST:8000/vcf-lab/ping_host | grep -q 'packets transmitted'"

echo "=== OpenWebUI sees Ollama backends ==="
for h in $OLLAMA_HOSTS; do
    chk "OWUI → $h:11434 /api/tags"   bash -c "ssh -o StrictHostKeyChecking=no root@$OWUI_HOST 'docker exec open-webui curl -fsS -m 5 http://$h:11434/api/tags' | python3 -c 'import json,sys; json.load(sys.stdin)'"
done

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && echo "🎉 stack is healthy" || echo "⚠️  $FAIL check(s) failed — see above"
exit $FAIL
