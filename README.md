# Ollama on home.lab — 接 Open WebUI

部署一台獨立 Ollama VM (`ollama.home.lab` / `10.0.0.63`) 跑本地 LLM,然後接上原本就有的 Open WebUI (`10.0.0.64`)。

全程 root SSH 操作,Ubuntu 20.04 (focal),目標 10–15 分鐘搞定(不含模型下載)。

| 項目 | 值 |
| --- | --- |
| Hostname | `ollama.home.lab` |
| IP | `10.0.0.63/23` |
| Gateway | `10.0.0.1` |
| DNS | `10.0.0.200` (KADDNS) |
| OS | Ubuntu 20.04.4 LTS (focal) |
| vCPU / RAM / Disk | 4 vCPU / 6 GB / 100 GB (沿用 `ubuntu2004temp` 樣板) |
| Ollama | v0.6+ (linux-amd64 tarball) |
| API Port | `11434` (對外開 `0.0.0.0`) |
| 模型 | `llama3.2:3b` (CPU-only,~2 GB) |
| 客戶端 | Open WebUI @ `http://10.0.0.64:3000/` |

> ⚠️ **CPU-only 部署**:lab nested VM 沒做 GPU passthrough,Ollama 會自動 fallback 到 CPU。3B 模型可用,7B/8B 模型會明顯變慢,建議 ≤ 4B。
>
> ⚠️ **安全提醒**:本 README 內含 lab-only 的密碼(`1qaz@WSX3edc`、`VMware1!`),只能在內網流通,**不要 fork 到 public 環境**。

---

## 拓撲

```
┌─────────────────────┐   HTTP/OpenAI-API   ┌──────────────────────┐
│ Open WebUI          │ ──────────────────▶ │ Ollama               │
│ 10.0.0.64:3000      │      :11434         │ 10.0.0.63:11434      │
│ (Docker)            │                     │ (systemd unit)       │
└─────────────────────┘                     └──────────────────────┘
        ▲
        │ Browser
        │
      User
```

---

## TL;DR

### A. 一鍵裝(線上)

```bash
# 在新開好的 10.0.0.63 VM 上:
git clone https://github.com/kostenyang/OpenWebUIOllama.git /opt/ollama-setup
cd /opt/ollama-setup
sudo bash scripts/install-online.sh
```

跑完之後:

```bash
ollama list                              # 應該看得到 llama3.2:3b
curl http://10.0.0.63:11434/api/tags     # 從 OpenWebUI 主機驗證
```

然後到 Open WebUI 加 connection(見 [§5](#5-加進-open-webui))。

### B. 離線裝(VM 沒網路)

先在**有網路的另一台機器**準備 offline bundle:

```bash
git clone https://github.com/kostenyang/OpenWebUIOllama.git
cd OpenWebUIOllama
sudo bash scripts/prepare-offline-bundle.sh /tmp/ollama-offline
tar czf ollama-offline-bundle.tgz -C /tmp ollama-offline
```

把 `ollama-offline-bundle.tgz` 跟整個 repo `scp` 到目標 VM,然後:

```bash
tar xzf ollama-offline-bundle.tgz -C /tmp
cd OpenWebUIOllama
sudo bash scripts/install-offline.sh /tmp/ollama-offline
```

詳見 [§4 離線安裝](#4-離線安裝)。

---

## 0. 前置:VM 部署

### 0.1 用 `ubuntu2004temp` 樣板,customization 一次設好 IP/hostname

> 避免「clone 完 IP 撞舊機」這個常見坑 — 直接在 deploy 時掛 customization spec,booted 第一次就是新 IP + 新 hostname,**不用手動改 netplan**。

在 mcp-server (有 pyvmomi 的機器) 上跑:

```bash
ssh root@10.0.0.65   # 任何有 pyvmomi 的機器都可
python3 - <<'PYEOF'
import ssl, time
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

ctx = ssl._create_unverified_context()
si  = SmartConnect(host='10.0.0.101', user='administrator@vsphere.local',
                   pwd='VMware1!', sslContext=ctx)
content = si.RetrieveContent()

def find(t, moid):
    cv = content.viewManager.CreateContainerView(content.rootFolder, [t], True)
    return next((o for o in cv.view if o._moId == moid), None)

template = find(vim.VirtualMachine, 'vm-1183')        # ubuntu2004temp
folder   = find(vim.Folder, 'group-v1525')            # "Linux" folder
cluster  = find(vim.ClusterComputeResource, 'domain-c26')
ds       = find(vim.Datastore, 'datastore-14801')     # SSD3

custom = vim.vm.customization.Specification(
    identity=vim.vm.customization.LinuxPrep(
        hostName=vim.vm.customization.FixedName(name='ollama'),
        domain='home.lab', timeZone='Asia/Taipei', hwClockUTC=True),
    globalIPSettings=vim.vm.customization.GlobalIPSettings(
        dnsSuffixList=['home.lab'],
        dnsServerList=['10.0.0.200', '10.0.0.1']),
    nicSettingMap=[vim.vm.customization.AdapterMapping(
        adapter=vim.vm.customization.IPSettings(
            ip=vim.vm.customization.FixedIp(ipAddress='10.0.0.63'),
            subnetMask='255.255.254.0',
            gateway=['10.0.0.1']))],
    options=vim.vm.customization.LinuxOptions())

spec = vim.vm.CloneSpec(
    location=vim.vm.RelocateSpec(datastore=ds, pool=cluster.resourcePool),
    template=False, powerOn=True, customization=custom)

task = template.CloneVM_Task(folder=folder, name='ollama', spec=spec)
while task.info.state in ('queued','running'):
    print('progress:', task.info.progress, '%'); time.sleep(10)
print('state:', task.info.state)
Disconnect(si)
PYEOF
```

`pyvmomi` 在 Ubuntu 20.04 (Python 3.8) 上要鎖版本:

```bash
pip3 install 'pyvmomi<8.0'   # 8.0+ 需要 Python 3.10+
```

部署完成後,VMware Tools 跑 customization → 重開機,約 1–2 分鐘內 10.0.0.63 會 ping 得到、SSH 開好。

### 0.2 驗證

```bash
ping -c 2 10.0.0.63
ssh root@10.0.0.63 'hostname; ip -4 addr show ens160 | grep inet; getent hosts ollama.com'
# 期望:
#   ollama
#   inet 10.0.0.63/23 brd 10.0.1.255 scope global ens160
#   <ip>  ollama.com   ← DNS 通且有外網
```

### 0.3 (可選) 註冊 DNS

```bash
# 在 DNS server (KADDNS, 10.0.0.200) 上加 A record:ollama.home.lab → 10.0.0.63
```

DNS 不是必須 — Open WebUI 那邊填 IP 也能用。

---

## 1. 裝 Ollama (線上)

### 1.1 安裝 zstd

> ⚠️ **2024 起 Ollama 官方 install script 用 zstd 壓縮 tarball**,Ubuntu 20.04 minimal image 沒裝。沒裝直接跑會吐:
> `ERROR: This version requires zstd for extraction.`

```bash
apt-get update -qq
apt-get install -y -qq zstd curl
```

### 1.2 跑官方 install script

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

script 會做:

1. 偵測 OS / arch (linux-amd64)
2. 從 `https://ollama.com/download/ollama-linux-amd64.tar.zst` 拉 tarball(**約 1.5 GB**,含 CUDA libs,即使 CPU-only 也會下)
3. 解壓到 `/usr/local/bin/ollama` + `/usr/local/lib/ollama/`
4. 建立 `ollama` 系統使用者
5. 寫 systemd unit `/etc/systemd/system/ollama.service`,`systemctl enable --now ollama`

完成後:

```bash
ollama --version
systemctl status ollama --no-pager | head -10
```

### 1.3 改成監聽 `0.0.0.0`(讓 Open WebUI 連得到)

> ⚠️ **預設只 bind `127.0.0.1:11434`**,從 10.0.0.64 連會 connection refused。

```bash
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
systemctl daemon-reload
systemctl restart ollama
ss -tlnp | grep 11434      # 應該是 0.0.0.0:11434
```

| 環境變數 | 用途 |
| --- | --- |
| `OLLAMA_HOST` | bind 位址,預設 `127.0.0.1:11434`,要設 `0.0.0.0:11434` 才能讓外部呼叫 |
| `OLLAMA_ORIGINS` | CORS 白名單,給 web UI 用,`*` 是全開(lab OK,production 別這樣) |
| `OLLAMA_KEEP_ALIVE` | 模型留在記憶體多久(預設 5m),`24h` 避免每次 cold load |
| `OLLAMA_MODELS` | 模型存放路徑,預設 `/usr/share/ollama/.ollama/models` |
| `OLLAMA_NUM_PARALLEL` | 同時處理的 request 數,CPU-only 建議 `1` |

### 1.4 拉模型

CPU-only 機器選小模型 (≤ 4B):

```bash
ollama pull llama3.2:3b              # Meta Llama 3.2, 3B, ~2 GB
# 其他常用:
# ollama pull qwen2.5:3b             # Qwen 2.5, 3B
# ollama pull phi3.5                 # Microsoft Phi 3.5, 3.8B
# ollama pull gemma2:2b              # Google Gemma 2, 2B (最小)
```

拉完看一下:

```bash
ollama list
# NAME                ID              SIZE      MODIFIED
# llama3.2:3b         a80c4f17acd5    2.0 GB    1 minute ago
```

### 1.5 本機驗證

```bash
# CLI
ollama run llama3.2:3b "say hi in 5 words"

# API (OpenAI-compatible 的 /v1/chat/completions 也支援)
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2:3b",
  "prompt": "say hi in 5 words",
  "stream": false
}'
```

---

## 2. 從 Open WebUI 主機驗證可達

在 10.0.0.64 上(或任何同網段的機器):

```bash
curl -s http://10.0.0.63:11434/api/tags | jq '.models[].name'
# "llama3.2:3b"

curl -s http://10.0.0.63:11434/api/generate -d '{
  "model": "llama3.2:3b",
  "prompt": "ping",
  "stream": false
}' | jq -r '.response'
```

連不到的話檢查順序:

1. `ss -tlnp | grep 11434` 是不是 `0.0.0.0` 不是 `127.0.0.1`
2. `ufw status` (本 lab template 預設 disabled,正常不會擋)
3. `journalctl -u ollama -n 50` 看 ollama 有沒有 crash

---

## 3. 加進 Open WebUI

### 3.1 用 Compose env (推薦,持久化)

如果 Open WebUI 是用本 repo [openwebui](https://github.com/kostenyang/openwebui) 的 compose 起的,改 `/opt/open-webui/docker-compose.yml`,在 `open-webui` service 的 `environment:` 區塊加:

```yaml
    environment:
      - WEBUI_NAME=Open WebUI
      - OLLAMA_BASE_URL=http://10.0.0.63:11434
      # 已有的其他 env...
```

再:

```bash
cd /opt/open-webui
docker compose up -d
docker logs open-webui --tail 30 | grep -i ollama
```

### 3.2 從 UI 設定(任何時候都能改)

1. 瀏覽器開 <http://10.0.0.64:3000/>
2. 右上頭像 → **Admin Panel** → **Settings** → **Connections**
3. **Ollama API** 區塊 → **+ Add Connection**:
   - **URL**: `http://10.0.0.63:11434`
   - **API Key**: 留空(Ollama 預設沒驗證)
4. 點旁邊的 **🔄** verify,有看到模型 = OK
5. **Save**

### 3.3 試用

回到主畫面,model 下拉應該多了 `llama3.2:3b`。挑它,開新 chat 問句話。

> 💡 第一次 inference 會 cold-load 模型(2 GB 載到記憶體,CPU-only 機器要 ~10 秒),之後在 `OLLAMA_KEEP_ALIVE` 期間內都會很快。

---

## 4. 離線安裝

### 4.1 準備 offline bundle (有網路的機器)

```bash
sudo bash scripts/prepare-offline-bundle.sh /tmp/ollama-offline
```

這個 script 會抓:

| 項目 | 來源 | 大小 |
| --- | --- | --- |
| `ollama-linux-amd64.tgz` (含 binary + lib) | github.com/ollama/ollama/releases | ~1.5 GB |
| `zstd` `.deb` | apt(focal) | <1 MB |
| `llama3.2:3b` blobs | 從另一台已 pull 好的 Ollama 主機 copy `/usr/share/ollama/.ollama/models` | ~2 GB |

整個打包:

```bash
tar czf ollama-offline-bundle.tgz -C /tmp ollama-offline
ls -lh ollama-offline-bundle.tgz   # ~3.5 GB
```

### 4.2 傳到目標 VM 並安裝

```bash
scp ollama-offline-bundle.tgz root@10.0.0.63:/tmp/
ssh root@10.0.0.63
tar xzf /tmp/ollama-offline-bundle.tgz -C /tmp/
cd /opt/ollama-setup        # repo 的 checkout
sudo bash scripts/install-offline.sh /tmp/ollama-offline
```

`install-offline.sh` 流程:

1. `dpkg -i /tmp/ollama-offline/deb/zstd*.deb`
2. `tar xzf /tmp/ollama-offline/ollama-linux-amd64.tgz -C /usr/local`
3. 建 `ollama` 使用者、寫 systemd unit
4. 套用 `systemd/ollama.service.override.conf` (監聽 0.0.0.0)
5. 把 `/tmp/ollama-offline/models/` rsync 到 `/usr/share/ollama/.ollama/models/`
6. `systemctl enable --now ollama`

完成後一樣 `ollama list` 驗證。

### 4.3 為什麼不直接用 ollama-linux-amd64.tar.zst

`tar.zst` 在 `ollama.com/download/` 是給線上 install script 用的格式,Ubuntu 20.04 minimal 沒 zstd 就解不開。`.tgz` (從 GitHub release 拿) 比較通用,連 BusyBox `tar` 都能解。

---

## 5. 升級 / 換模型 / 移除

### 升級 Ollama

```bash
# 線上
curl -fsSL https://ollama.com/install.sh | sh
systemctl restart ollama

# 離線:重做 §4.1 拉新版 tarball,scp 過去重跑 install-offline.sh
```

模型不會被覆蓋(在 `/usr/share/ollama/.ollama/models`)。

### 換 / 移除模型

```bash
ollama pull qwen2.5:3b
ollama rm llama3.2:3b
ollama list
```

### 完全移除 Ollama

```bash
systemctl disable --now ollama
rm -f /etc/systemd/system/ollama.service
rm -rf /etc/systemd/system/ollama.service.d
rm -rf /usr/local/bin/ollama /usr/local/lib/ollama
rm -rf /usr/share/ollama
userdel ollama
```

---

## 6. 常見問題

| 症狀 | 原因 | 解法 |
| --- | --- | --- |
| `install.sh` 吐 `requires zstd for extraction` | Ubuntu 20.04 minimal 沒 zstd | `apt-get install -y zstd` 再跑一次 |
| 從 Open WebUI 連 `connection refused` | Ollama 只 bind `127.0.0.1` | 套用 §1.3 的 override |
| 第一次 inference 卡 10+ 秒 | 模型 cold-load 到記憶體 | 正常,設 `OLLAMA_KEEP_ALIVE=24h` 之後就快 |
| 7B / 8B 模型很慢 / OOM | CPU-only + 6 GB RAM 撐不住 | 換 ≤ 4B 模型,或加 RAM / GPU |
| Open WebUI verify connection 失敗 | URL 拼錯、port 不對、防火牆擋 | 從 10.0.0.64 的容器內跑 `curl`:`docker exec open-webui curl -s http://10.0.0.63:11434/api/tags` |
| `ollama pull` 中斷 / 慢 | 連 ollama.com 的 layer 拉到一半斷 | 重跑 `ollama pull <model>` 會續傳 |
| 模型佔太多 disk | `/usr/share/ollama/.ollama/models` 累積 | `ollama rm <model>` 或搬到別的 disk:設 `OLLAMA_MODELS=/mnt/...` |
| Customization 沒生效(IP/hostname 沒換) | 樣板裡 `open-vm-tools` 沒裝 / 太舊 | template 那邊裝好 `open-vm-tools` 再 convert template |

---

## 檔案結構

```
.
├── README.md                                 本檔
├── llmimplementation-notes.html              逐步部署實錄(時間軸)
├── scripts/
│   ├── deploy-vm.py                          pyvmomi 部署 ollama VM (§0.1)
│   ├── install-online.sh                     §1 全包,zstd → install.sh → override → pull
│   ├── prepare-offline-bundle.sh             §4.1 在有網機器抓 bundle
│   └── install-offline.sh                    §4.2 在目標 VM 用 bundle 裝
├── netplan/
│   └── 00-installer-config.yaml              靜態 IP 範本 (template customization 已自動套用,這份只是參考)
├── systemd/
│   └── ollama.service.override.conf          §1.3 的 override(讓 ollama 監聽 0.0.0.0)
└── .gitignore
```
