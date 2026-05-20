#!/usr/bin/env bash
# Build an offline-install bundle for vcf-mcp (the lab's FastMCP SSE server).
#   bash mcp/prepare-mcp-offline-bundle.sh [out_dir]
# Default out_dir: ./mcp-offline
#
# Run on the existing mcp-server (10.0.0.65) where:
#   /opt/vcf-mcp/                              ← server code + venv + cert/key/keys.json
#   /root/.local/share/uv/python/cpython-3.11* ← uv-managed Python 3.11
#   /etc/systemd/system/vcf-mcp.service        ← systemd unit
#
# The bundle is fully self-contained: a target VM does not need apt, pip, uv,
# or internet to install — only `tar` (always present) and openssl (for the
# fresh SAN cert; pre-installed on Ubuntu minimal).
set -euo pipefail

OUT="${1:-./mcp-offline}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_SRC="/root/.local/share/uv/python/cpython-3.11.15-linux-x86_64-gnu"
MCP_SRC="/opt/vcf-mcp"
UNIT_SRC="/etc/systemd/system/vcf-mcp.service"

mkdir -p "$OUT"

# ── sanity ─────────────────────────────────────────────────────────────
[ -d "$PYTHON_SRC" ] || { echo "Python 3.11 not at $PYTHON_SRC"; exit 1; }
[ -d "$MCP_SRC"    ] || { echo "vcf-mcp not at $MCP_SRC";       exit 1; }
[ -f "$UNIT_SRC"   ] || { echo "systemd unit missing";          exit 1; }

echo "== 1. python311.tgz (uv-managed Python 3.11, ~96 MB raw) =="
# preserve symlinks; --absolute-names so the path inside the tar matches target
tar czf "$OUT/python311.tgz" \
    -C "$(dirname "$PYTHON_SRC")" "$(basename "$PYTHON_SRC")"

echo "== 2. vcf-mcp.tgz (code + venv + keys.json + cert, exclude bak/cache) =="
tar czf "$OUT/vcf-mcp.tgz" \
    --exclude='__pycache__' \
    --exclude='*.bak*' \
    --exclude='*.pyc' \
    -C "$(dirname "$MCP_SRC")" "$(basename "$MCP_SRC")"

echo "== 3. systemd unit + repo files =="
cp "$UNIT_SRC"                                  "$OUT/vcf-mcp.service"
cp "$REPO_DIR/mcp/install-mcp-offline.sh"       "$OUT/install-mcp-offline.sh"
cp "$REPO_DIR/mcp/gen-san-cert.sh"              "$OUT/gen-san-cert.sh"
cp "$0"                                         "$OUT/prepare-mcp-offline-bundle.sh"
chmod +x "$OUT"/*.sh

cat > "$OUT/README.txt" <<EOF
vcf-mcp offline bundle
======================
Built: $(date -u +%FT%TZ) on $(hostname)
From:  $MCP_SRC + $PYTHON_SRC

Install on target (root):
    tar xzf mcp-offline-bundle.tgz -C /tmp
    bash /tmp/mcp-offline/install-mcp-offline.sh /tmp/mcp-offline [--ip <new_ip>]

What it does:
  1. untar python311.tgz to /root/.local/share/uv/python/
  2. untar vcf-mcp.tgz   to /opt/vcf-mcp/
  3. regenerate cert.pem with SAN matching the target IP (if --ip given)
  4. install systemd unit + enable + start
EOF

echo "== DONE =="
du -sh "$OUT"
echo "Next:"
echo "  tar czf mcp-offline-bundle.tgz -C $(dirname "$OUT") $(basename "$OUT")"
