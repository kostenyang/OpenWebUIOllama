#!/usr/bin/env bash
# Install vcf-mcp from an offline bundle on a fresh Ubuntu 20.04 VM.
#   bash install-mcp-offline.sh <bundle_dir> [--ip <self_ip>] [--no-cert]
#
# bundle_dir must contain:
#   python311.tgz
#   vcf-mcp.tgz
#   vcf-mcp.service
#   gen-san-cert.sh
#
# --ip <self_ip>  regenerate SAN cert with this IP (default: detected from `hostname -I`)
# --no-cert       reuse the cert.pem inside vcf-mcp.tgz (cert SAN may not match new IP — TLS may fail)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

BUNDLE="${1:?usage: $0 <bundle_dir> [--ip <self_ip>] [--no-cert]}"
shift
SELF_IP=""
REGEN_CERT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --ip)       SELF_IP="$2"; shift 2 ;;
        --no-cert)  REGEN_CERT=0; shift ;;
        *)          echo "unknown arg: $1"; exit 1 ;;
    esac
done
[ -n "$SELF_IP" ] || SELF_IP="$(hostname -I | awk '{print $1}')"
echo "Target IP for cert: $SELF_IP"

cd "$BUNDLE"
for f in python311.tgz vcf-mcp.tgz vcf-mcp.service; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

echo "== 1. extract uv-managed Python 3.11 =="
mkdir -p /root/.local/share/uv/python
tar xzf python311.tgz -C /root/.local/share/uv/python
# create the unversioned symlink the venv's interpreter symlink points at
ln -sfT /root/.local/share/uv/python/cpython-3.11.15-linux-x86_64-gnu \
        /root/.local/share/uv/python/cpython-3.11-linux-x86_64-gnu

echo "== 2. extract /opt/vcf-mcp =="
tar xzf vcf-mcp.tgz -C /opt
# sanity: venv interpreter should resolve
/opt/vcf-mcp/venv/bin/python3 --version

echo "== 3. cert =="
if [ "$REGEN_CERT" = "1" ]; then
    bash gen-san-cert.sh /opt/vcf-mcp "$SELF_IP"
else
    echo "  (skipped, --no-cert)"
fi

echo "== 4. systemd unit =="
install -m 644 vcf-mcp.service /etc/systemd/system/vcf-mcp.service
systemctl daemon-reload
systemctl enable --now vcf-mcp

# wait for port 7000
for i in $(seq 1 20); do
    ss -tlnp 2>/dev/null | grep -q ':7000' && break
    sleep 1
done

echo "== 5. verify =="
ss -tlnp | grep ':7000' || { echo "NOT LISTENING"; journalctl -u vcf-mcp -n 30 --no-pager; exit 1; }
systemctl is-active vcf-mcp

# pull token out of keys.json for the user
TOKEN=$(python3 -c 'import json; d=json.load(open("/opt/vcf-mcp/keys.json")); print(list(d.values())[0] if d else "(empty)")' 2>/dev/null || echo '(parse failed)')

cat <<EOF

== DONE ==
vcf-mcp:  https://$SELF_IP:7000/sse  (self-signed)
Token:    Bearer $TOKEN

Smoke test (from any host on the same network):
  curl -sk -H 'Authorization: Bearer $TOKEN' \\
       https://$SELF_IP:7000/sse  -m 5 | head -3
  # expect first SSE event within ~1s

Edit /opt/vcf-mcp/keys.json to add/rotate tokens, then:
  systemctl restart vcf-mcp
EOF
