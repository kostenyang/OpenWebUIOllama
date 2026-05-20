#!/usr/bin/env bash
# Regenerate the self-signed TLS cert for vcf-mcp with proper SAN entries.
#   bash gen-san-cert.sh <install_dir> <ip> [hostname]
#
# Why: Python ≥ 3.10 / httpx require subjectAltName for IP-based TLS verification.
# A CN-only cert (CN=10.0.0.65) produces:
#   [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: IP address mismatch
# on mcpo / any modern client.
set -euo pipefail

DIR="${1:?usage: $0 <install_dir> <ip> [hostname]}"
IP="${2:?missing ip}"
HOST="${3:-$(hostname -s 2>/dev/null || echo mcp-server)}"

mkdir -p "$DIR"
cd "$DIR"

[ -f cert.pem ] && cp cert.pem cert.pem.bak.$(date +%s)
[ -f key.pem  ] && cp key.pem  key.pem.bak.$(date +%s)

cat > /tmp/san.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $IP
O  = VCF-Lab
[v3]
basicConstraints = critical, CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @san
[san]
IP.1  = $IP
IP.2  = 127.0.0.1
DNS.1 = $HOST
DNS.2 = localhost
EOF

openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
    -keyout key.pem -out cert.pem \
    -config /tmp/san.cnf -extensions v3
chmod 600 key.pem
chmod 644 cert.pem
rm -f /tmp/san.cnf

echo "Cert SAN entries:"
openssl x509 -in cert.pem -noout -ext subjectAltName | tail -1
