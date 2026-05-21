# Ollama-14B — 大模型 VM

第二台 Ollama VM,專門跑 **14B Q4 等級的模型**(Phi-4、Qwen 2.5)。base 那台 (`10.0.0.63`) 只有 6 GB RAM 撐不住,所以另開一台肉一點的。

| 項目 | base ollama (10.0.0.63) | **ollama-14b (10.0.0.67)** |
| --- | --- | --- |
| Hostname | `ollama` | `ollama-14b` |
| IP | `10.0.0.63/23` | **`10.0.0.67/23`** |
| vCPU | 4 | **12** |
| RAM | 6 GB | **32 GB** |
| Disk | 100 GB | **200 GB** |
| 預設模型 | llama3.2:3b / qwen2.5:3b | **phi4:14b / qwen2.5:14b** |
| tok/s 預估 | 20–25 (3B) | 10–13 (14B, 12 vCPU) |

兩台都接到同一個 Open WebUI (`10.0.0.64`),由 `OLLAMA_BASE_URL` 同時帶兩個 URL,**model 下拉會把兩台的模型混在一起**,使用者選哪個就跑哪台。

---

## TL;DR

### A. 線上裝(VM 有外網)

```bash
# 1. 部署 VM(在有 pyvmomi 的機器上,例如 mcp-server)
ssh root@10.0.0.65
git clone https://github.com/kostenyang/OpenWebUIOllama.git /opt/setup
python3 /opt/setup/ollama-14b/scripts/deploy-vm.py
# 等 ~2 分鐘,SSH 到 10.0.0.67 就 open

# 2. 一鍵裝 Ollama + 拉 phi4 / qwen2.5 + benchmark
ssh root@10.0.0.67
git clone https://github.com/kostenyang/OpenWebUIOllama.git /opt/setup
sudo bash /opt/setup/ollama-14b/scripts/install-online.sh
```

### B. 離線裝

要在有網的機器先打 bundle(model 也帶過去 — 14B blobs ~18 GB):

```bash
# 在 base ollama (10.0.0.63) 已經 pull 過 phi4:14b + qwen2.5:14b 的話:
bash scripts/prepare-offline-bundle.sh /tmp/14b-bundle phi4:14b qwen2.5:14b
tar czf /tmp/ollama-14b-offline-bundle.tgz -C /tmp 14b-bundle
# 注意:bundle 約 19 GB!

# scp 到 air-gapped 目標
scp /tmp/ollama-14b-offline-bundle.tgz root@<target>:/tmp/
ssh root@<target>
tar xzf /tmp/ollama-14b-offline-bundle.tgz -C /tmp/
sudo bash /opt/setup/ollama-14b/scripts/install-offline.sh /tmp/14b-bundle
```

詳見 base repo 的 [§4 離線安裝](../README.md#4-離線安裝),這裡的 install-offline.sh 只是包了 base + resize + benchmark。

---

## 0. 為什麼要另開一台

base ollama VM (10.0.0.63) 跑 14B 模型會:

| 觀察 | 原因 |
| --- | --- |
| OOM 或開始 swap | 6 GB RAM 放不下 ~12 GB 推論需求 |
| <2 tok/s | 4 vCPU 不夠 14B 矩陣乘法 |
| 模型載入幾分鐘 | 100 GB disk 只 49 GB 可用,blobs 都搬不進去 |

所以這台**升 3 倍 CPU、5 倍 RAM、2 倍 disk**,專門給 14B 用。base 那台留給 3B 系列(latency 低、cold load 快)。

---

## 1. VM 部署細節

### 1.1 一個 clone task 同時做完三件事

[scripts/deploy-vm.py](scripts/deploy-vm.py) 把 customization spec + config-spec(改 CPU/RAM/disk)綁在同一個 `CloneVM_Task` 裡:

```python
config_spec = vim.vm.ConfigSpec(
    numCPUs=12, numCoresPerSocket=12,
    memoryMB=32768,
    deviceChange=[disk_spec],   # 100 → 200 GB
)
spec = vim.vm.CloneSpec(
    location=..., template=False, powerOn=True,
    customization=custom,   # hostname/IP/DNS
    config=config_spec,     # CPU/RAM/disk
)
template.CloneVM_Task(folder=folder, name='ollama-14b', spec=spec)
```

省一次 ReconfigVM 來回。

### 1.2 Disk 大但檔案系統沒跟著大

`ubuntu2004temp` 出來的 layout:

```
sda            100 GB
├─sda1         1 MB    (BIOS boot)
├─sda2         1.5 GB  /boot
└─sda3         98.5 GB LVM PV
   └─ubuntu-lv 49.3 GB  /   ← 只佔 PV 一半!
```

clone 之後 sda 變 200 GB,但 sda3 / PV / LV / ext4 都沒變。手動跑 [scripts/resize-disk.sh](scripts/resize-disk.sh):

```bash
growpart /dev/sda 3            # sda3: 98.5 GB → 198.5 GB
pvresize /dev/sda3             # PV 跟著大
lvextend -l +100%FREE ...      # LV 吃光 PV free
resize2fs /dev/mapper/...      # ext4 線上擴張
```

跑完 `df -h /` 從 49 GB 變 ~195 GB。`install-online.sh` 跟 `install-offline.sh` 已經內建在最前面呼叫。

---

## 2. 模型挑選

### Phi-4 (Microsoft, 14.7B)

| | |
| --- | --- |
| Size | 9.1 GB (Q4_K_M) |
| RAM 推論 | ~11 GB |
| 強項 | reasoning、邏輯題、英文寫作 |
| 弱項 | 中文一般,知識面英文化 |

### Qwen 2.5 (Alibaba, 14B)

| | |
| --- | --- |
| Size | 9.0 GB (Q4_K_M) |
| RAM 推論 | ~11 GB |
| 強項 | **中文最強(繁簡都好)**、tool calling、長 context (128K) |
| 弱項 | reasoning 略遜 phi4 |

兩個都拉,日常英文用 phi4,中文用 qwen2.5。

### 其他 14B 候選(沒裝,需要可以後補)

| Model | Size | 備註 |
| --- | --- | --- |
| `mistral-nemo:12b` | 7.1 GB | Mistral + NVIDIA,英文/法文 |
| `gemma2:9b` (9B 但接近 14B 質感) | 5.5 GB | Google,輕量 |
| `deepseek-r1:14b` | 9.0 GB | reasoning,會先 `<think>` |
| `qwen2.5-coder:14b` | 9.0 GB | 程式碼專用 |

---

## 3. 接到 Open WebUI(多 Ollama backend)

OpenWebUI 的 `OLLAMA_BASE_URL` 用 **`;`** 分隔多個 URL(注意是分號,不是逗號!):

```yaml
# /opt/open-webui/docker-compose.yml
services:
  open-webui:
    environment:
      - OLLAMA_BASE_URL=http://10.0.0.63:11434;http://10.0.0.67:11434
```

```bash
cd /opt/open-webui
docker compose up -d open-webui
```

OpenWebUI 啟動時會同時對兩個 URL 跑 `/api/tags`,把回來的 model 全部 merge 到下拉。

> ⚠️ 同名 model(例如兩台都有 `llama3.2:3b`)只會顯示一個,優先用清單順序第一個。要分辨來源可以在某一台 model 上加 alias。

也可以從 UI 加:Admin Panel → Settings → Connections → Ollama API → **+ Add Connection** → `http://10.0.0.67:11434`。比較零散但不用改 compose。

---

## 4. Benchmark 實測

**vCenter nested VM @ Intel i5-10400 (host) / 12 vCPU / 32 GB RAM / Q4_K_M:**

| Model | Size | 實測 tok/s | 備註 |
| --- | --- | --- | --- |
| `phi4:14b` | 9.1 GB | **2.84** | 12 cores 都 100%,純 CPU bound |
| `qwen2.5:14b` | 9.0 GB | **2.97** | 同上 |

> ⚠️ **比裸機慢很多**。Phi-4 在裸機 i5-10400 預期 10+ tok/s,nested ESXi 上掉到 ~3 tok/s。原因猜:nested virt 失去 host CPU 的 AVX-512 / 某些向量指令、L3 cache 隔離效率差。**有 GPU 還是請走 GPU**,CPU 只是 fallback。
>
> 同樣的 model 在這台跟 base ollama (10.0.0.63, 4 vCPU/6 GB RAM) 比:那台跑 14B 會 swap + 1 tok/s 或直接 OOM,這台至少能用。

第一次 inference cold-load 9 GB 進 RAM,會多 ~10 秒。設 `OLLAMA_KEEP_ALIVE=24h` 之後不會再 reload。同時 load 兩個 14B 會吃 18 GB RAM,32 GB 還剩 ~10 GB 給 OS + buff/cache,**OK 但不要再加第三個 14B**。

---

## 5. 常見問題(14B 特有)

| 症狀 | 原因 | 解法 |
| --- | --- | --- |
| `df -h /` 還是 49 GB | 沒跑 resize-disk.sh | 補跑 `bash scripts/resize-disk.sh` |
| `ollama pull phi4:14b` 卡在 9 GB 那塊 | 網路斷或 ollama.com layer 拉一半 | 重跑同個 command,layer 是 content-addressed 會續傳 |
| 14B chat 第一次 10 秒沒反應 | cold load 9 GB 到 RAM | 正常;設 `OLLAMA_KEEP_ALIVE=24h` |
| 推論時 RAM 用滿開始 swap | 同時 load 兩個 14B(超出 32 GB) | `OLLAMA_MAX_LOADED_MODELS=1` 強迫只 load 一個 |
| Open WebUI 看不到 .67 的 model | URL 用逗號而非分號 | 改 `;` 分隔(逗號是 OPENAI_BASE_URL 才對) |
| 兩台同名 model 只顯示一個 | OpenWebUI 預設 dedup | UI 上 alias 改名,或乾脆別讓兩台名字一樣 |

---

## 檔案結構

```
ollama-14b/
├── README.md                     本檔
├── scripts/
│   ├── deploy-vm.py              §1 pyvmomi clone + reconfig
│   ├── resize-disk.sh            §1.2 growpart + pvresize + lvextend + resize2fs
│   ├── install-online.sh         §A 線上一鍵裝(復用 ../scripts/install-online.sh + 拉 14B)
│   └── install-offline.sh        §B 離線裝(復用 ../scripts/install-offline.sh + resize + bench)
```
