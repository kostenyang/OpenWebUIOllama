#!/usr/bin/env bash
# 14B-VM 離線安裝
#   sudo bash install-offline.sh <bundle_dir>
#
# bundle_dir 需要(由 ../scripts/prepare-offline-bundle.sh 帶 14B 模型重跑產生):
#   ollama-linux-amd64.tar.zst   官方 tarball (~1.2 GB)
#   zstd.deb                     zstd 套件
#   models/                      phi4:14b 跟 qwen2.5:14b 的 manifest + blobs (~18 GB)
#   ollama.service.override.conf 監聽 0.0.0.0
#
# 完整流程跟 base offline install 一樣,只是 model blobs 包了 14B。
# install 本身的步驟 (zstd + tar + systemd + override + copy blobs) 整段沿用
# 上游 ../scripts/install-offline.sh,這支只多做兩件事:
#   1. resize 磁碟到 200 GB(template 出來只有 49 GB,放不下 18 GB 模型)
#   2. 結尾跑一次 benchmark
set -euo pipefail

BUNDLE="${1:?usage: $0 <bundle_dir>}"
[ -d "$BUNDLE" ] || { echo "$BUNDLE not a dir"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# 1. resize first — base installer copies blobs to /usr/share/ollama; need space
echo "== resize disk to use full 200 GB =="
bash "$(dirname "$0")/resize-disk.sh"

# 2. base offline install (zstd → tar → systemd → blobs → enable)
echo "== base offline install =="
bash "$REPO_DIR/scripts/install-offline.sh" "$BUNDLE"

# 3. benchmark
echo "== benchmark =="
for model in $(ollama list 2>/dev/null | awk 'NR>1 {print $1}'); do
    r=$(curl -sS http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"$model\",\"prompt\":\"reply with: ok\",\"stream\":false}")
    speed=$(python3 -c "import json,sys; r=json.loads('''$r'''); print(round(r.get('eval_count',0)/(r.get('eval_duration',1)/1e9),2))")
    echo "  $model: $speed tok/s"
done

cat <<EOF

== DONE ==
Ollama:  http://$(hostname -I | awk '{print $1}'):11434
Models:  $(ollama list 2>/dev/null | awk 'NR>1 {print $1}' | paste -sd ', ')

Bundle preparation (run on a machine that already has ollama + the models):
  bash $REPO_DIR/scripts/prepare-offline-bundle.sh /tmp/14b-bundle phi4:14b qwen2.5:14b
  tar czf /tmp/ollama-14b-offline-bundle.tgz -C /tmp 14b-bundle
EOF
