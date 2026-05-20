#!/usr/bin/env bash
# Prepare an offline-install bundle for Ollama.
#   bash scripts/prepare-offline-bundle.sh [out_dir] [model...]
#
# Default: ./out, model=llama3.2:3b
#
# Must run on a machine WITH internet that has:
#   - apt (Ubuntu / Debian) — for downloading zstd .deb
#   - ollama installed and running — for pulling and exporting the model blobs
#
# Bundle contents (~3.5 GB for llama3.2:3b):
#   <out>/ollama-linux-amd64.tar.zst   official tarball
#   <out>/zstd.deb                     zstd package
#   <out>/models/                      ollama model store (manifests + blobs)
#   <out>/install-offline.sh           copy of the offline installer (so target only needs this dir)
#
# To install on the target VM:
#   tar czf bundle.tgz -C $(dirname out) $(basename out)
#   scp bundle.tgz root@target:/tmp/
#   ssh root@target 'tar xzf /tmp/bundle.tgz -C /tmp && bash /tmp/$(basename out)/install-offline.sh /tmp/$(basename out)'
set -euo pipefail

OUT="${1:-./out}"; shift || true
MODELS=("${@:-llama3.2:3b}")
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$OUT"/{deb,models}

echo "== 1. Ollama tarball (.tar.zst, ~1.5 GB) =="
URL="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst"
if [ ! -f "$OUT/ollama-linux-amd64.tar.zst" ]; then
    curl -fL --retry 3 -o "$OUT/ollama-linux-amd64.tar.zst.tmp" "$URL"
    mv "$OUT/ollama-linux-amd64.tar.zst.tmp" "$OUT/ollama-linux-amd64.tar.zst"
fi
ls -lh "$OUT/ollama-linux-amd64.tar.zst"

echo "== 2. zstd .deb (target needs it before extracting tarball) =="
# Download the zstd package for the target's Ubuntu release.
# Default = focal; pass UBUNTU_REL=jammy etc. if your target is newer.
REL="${UBUNTU_REL:-focal}"
apt-get download zstd \
    -o Dir::Cache::archives="$OUT/deb" \
    -o Debug::NoLocking=true 2>/dev/null \
    || apt-get install -y --download-only --reinstall zstd -o Dir::Cache::archives="$OUT/deb"
mv "$OUT/deb/"zstd*.deb "$OUT/zstd.deb" 2>/dev/null || \
    cp /var/cache/apt/archives/zstd*.deb "$OUT/zstd.deb"
rmdir "$OUT/deb" 2>/dev/null || true
ls -lh "$OUT/zstd.deb"

echo "== 3. model blobs (need a running ollama on this machine) =="
command -v ollama >/dev/null || { echo "install ollama on this machine first"; exit 1; }
systemctl is-active ollama >/dev/null || systemctl start ollama || true

# Find ollama's model dir.  Default: /usr/share/ollama/.ollama/models
SRC_MODELS="$(systemctl show ollama -p Environment 2>/dev/null | grep -oP 'OLLAMA_MODELS=\K[^ ]+' || true)"
SRC_MODELS="${SRC_MODELS:-/usr/share/ollama/.ollama/models}"
[ -d "$SRC_MODELS" ] || { echo "model dir $SRC_MODELS not found"; exit 1; }

for m in "${MODELS[@]}"; do
    echo "  pulling $m"
    ollama pull "$m"
done

# rsync just the manifests + referenced blobs for our models
mkdir -p "$OUT/models/manifests" "$OUT/models/blobs"
for m in "${MODELS[@]}"; do
    name="${m%%:*}"; tag="${m##*:}"
    # manifests/<registry>/<namespace>/<name>/<tag>
    find "$SRC_MODELS/manifests" -path "*/$name/$tag" -print0 | \
        while IFS= read -r -d '' mf; do
            rel="${mf#$SRC_MODELS/}"
            mkdir -p "$OUT/models/$(dirname "$rel")"
            cp "$mf" "$OUT/models/$rel"
            # extract blob digests and copy each
            python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
print(d['config']['digest'])
for l in d['layers']: print(l['digest'])" "$mf" | while read digest; do
                f="$SRC_MODELS/blobs/${digest/:/-}"
                [ -f "$f" ] && cp -n "$f" "$OUT/models/blobs/" || echo "  WARN: blob $digest missing"
            done
        done
done

echo "== 4. copy installer + repo files =="
cp "$0" "$OUT/prepare-offline-bundle.sh"
cp "$REPO_DIR/scripts/install-offline.sh" "$OUT/install-offline.sh"
cp "$REPO_DIR/systemd/ollama.service.override.conf" "$OUT/ollama.service.override.conf"

echo "== DONE =="
du -sh "$OUT"
echo "Next:"
echo "  tar czf ollama-offline-bundle.tgz -C $(dirname "$OUT") $(basename "$OUT")"
echo "  scp ollama-offline-bundle.tgz root@<target>:/tmp/"
