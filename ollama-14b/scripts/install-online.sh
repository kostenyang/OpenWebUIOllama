#!/usr/bin/env bash
# 14B-VM 線上一鍵裝:zstd → install.sh → override → pull 14B 模型 → 報告
# 上游 ../scripts/install-online.sh 已經做完前面三段,這支只負責「14B 特有」的部分。
#
#   sudo bash install-online.sh
#
# pull 進來:
#   phi4:14b      Microsoft Phi-4, ~9 GB
#   qwen2.5:14b   Alibaba Qwen 2.5, ~9 GB
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

# 1. base install (handled by parent repo install-online.sh, default model llama3.2:3b)
echo "== base install (zstd + ollama + systemd override) =="
bash "$REPO_DIR/scripts/install-online.sh" llama3.2:3b

# 2. resize disk (template ships with only 49 GB usable, 14B models need more headroom)
echo "== resize disk to use full 200 GB =="
bash "$(dirname "$0")/resize-disk.sh"

# 3. pull 14B models
for model in phi4:14b qwen2.5:14b; do
    echo "== pull $model =="
    ollama pull "$model"
done
ollama list

# 4. benchmark each
echo "== benchmark =="
for model in phi4:14b qwen2.5:14b; do
    r=$(curl -sS http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"$model\",\"prompt\":\"reply with: ok\",\"stream\":false}")
    speed=$(python3 -c "import json,sys; r=json.loads('''$r'''); print(round(r.get('eval_count',0)/(r.get('eval_duration',1)/1e9),2))")
    echo "  $model: $speed tok/s"
done

cat <<EOF

== DONE ==
Ollama:  http://$(hostname -I | awk '{print $1}'):11434
Models:  phi4:14b, qwen2.5:14b

Next:
  - Add to Open WebUI: comma-extend OLLAMA_BASE_URL on 10.0.0.64
       OLLAMA_BASE_URL=http://10.0.0.63:11434,http://10.0.0.67:11434
    or Admin Panel → Settings → Connections → Ollama API → + Add
       URL: http://$(hostname -I | awk '{print $1}'):11434
EOF
