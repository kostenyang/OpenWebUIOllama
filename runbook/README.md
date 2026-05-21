# 離線安裝 Runbook — 整套 LLM stack 從零到能用

把整套東西(Ollama × N + vcf-mcp + Open WebUI + mcpo)在**沒有外網**的 lab 裡裝起來、接好線的逐步指南。每一步對應 1 個 script,從這份文件 copy 指令就能跑。

---

## 拓撲(目標狀態)

```
         ┌──────────────────────────────┐
         │  user 瀏覽器                  │
         └──────────────┬───────────────┘
                        │ HTTP
              ┌─────────▼─────────┐
              │ Open WebUI :3000  │  10.0.0.64
              │ (Docker)          │
              └──────┬──────┬─────┘
                     │      │
        OLLAMA_BASE_URL    Tool URL
        (semicolon list)   (OpenAPI)
                     │      │
   ┌─────────────┐   │      │   ┌──────────────────┐
   │ ollama base │◀──┘      └──▶│ mcpo :8000       │  同 10.0.0.64
   │ 10.0.0.63   │              │ (Docker)         │
   │ :11434      │              └──────┬───────────┘
   │ 3B–7B 模型  │                     │
   └─────────────┘                     │ HTTPS+SSE (self-signed cert)
                                       │ Bearer token
   ┌─────────────┐                     │
   │ ollama-14b  │                     ▼
   │ 10.0.0.67   │              ┌──────────────────┐
   │ :11434      │              │ vcf-mcp :7000    │  10.0.0.65
   │ 14B 模型    │              │ (systemd unit)   │
   └─────────────┘              └──────┬───────────┘
                                       │
                                       │ Python SDK / SSH
                                       ▼
                              vCenter / SDDC Manager / ESXi
```

3 種 VM(或 4 種 — 含第二台 Ollama),全部 Ubuntu 20.04,template `ubuntu2004temp` clone 出來。

---

## 角色 / VM 規格

| 角色 | IP | vCPU | RAM | Disk | 服務 |
| --- | --- | --- | --- | --- | --- |
| **ollama base** | 10.0.0.63 | 4 | 6 GB | 100 GB | Ollama (3B / 7B) |
| **ollama-14b** *(選用)* | 10.0.0.67 | 12 | 32 GB | 200 GB | Ollama (14B Q4) |
| **mcp-server** | 10.0.0.65 | 4 | 8 GB | 100 GB | vcf-mcp (FastMCP SSE) |
| **openwebui** | 10.0.0.64 | 4 | 4 GB | 100 GB | Open WebUI + mcpo (Docker) |

`ubuntu2004temp` 都用,只在 `deploy-vm.py` 裡改 vCPU/RAM/disk/IP/hostname。

---

## 工作流程概觀

```
[build 機器(有網)]               [air-gapped 目標 VMs]

┌──── 1. 準備 bundles ────┐     ┌──── 3. 安裝 ────┐
│ prep-ollama-bundle.sh   │     │ install-offline │
│ prep-mcp-bundle.sh      │ scp │  (× 4 個 VM)    │
│ prep-openwebui-bundle.sh│────▶│                 │
└─────────────────────────┘     └─────────────────┘
                                          │
                                ┌─────────▼─────────┐
                                │  4. wire-up       │
                                │  wire-ollama.sh   │
                                │  wire-mcpo.sh     │
                                └─────────┬─────────┘
                                          │
                                ┌─────────▼─────────┐
                                │  5. verify.sh     │
                                └───────────────────┘

(2. 部署 VM 在 vCenter 那邊獨立做 — deploy-vm.py)
```

---

## 階段 1 — 準備 bundles(在有網的 build 機器)

需要 build 機器有:Docker(只給 OpenWebUI bundle 用)、`apt-get download` 能用(zstd .deb)、已經裝好 Ollama 跟 vcf-mcp(當 source of truth)。

### 1.1 Ollama bundle(~3.5 GB)

```bash
git clone https://github.com/kostenyang/OpenWebUIOllama.git
cd OpenWebUIOllama

# 用法:prepare-offline-bundle.sh <out_dir> [model ...]
bash scripts/prepare-offline-bundle.sh /tmp/ollama-offline llama3.2:3b qwen2.5:3b
tar czf /tmp/ollama-offline-bundle.tgz -C /tmp ollama-offline
ls -lh /tmp/ollama-offline-bundle.tgz   # ~3.5 GB
```

如果要包 **14B 模型**(額外 ~18 GB):
```bash
bash scripts/prepare-offline-bundle.sh /tmp/ollama-14b-offline phi4:14b qwen2.5:14b
tar czf /tmp/ollama-14b-offline-bundle.tgz -C /tmp ollama-14b-offline
```

> 📄 細節:[`../README.md#4-離線安裝`](../README.md#4-離線安裝),[`../ollama-14b/README.md`](../ollama-14b/README.md)

### 1.2 vcf-mcp bundle(~44 MB)

```bash
# 在現有 mcp-server (10.0.0.65) 上跑(那邊已經有 /opt/vcf-mcp/ 跟 uv-python):
ssh root@10.0.0.65
git clone https://github.com/kostenyang/OpenWebUIOllama.git /opt/setup
bash /opt/setup/mcp/prepare-mcp-offline-bundle.sh /tmp/mcp-offline
tar czf /tmp/mcp-offline-bundle.tgz -C /tmp mcp-offline
ls -lh /tmp/mcp-offline-bundle.tgz   # ~44 MB
```

> 📄 細節:[`../mcp/`](../mcp/),[`../README.md#5-vcf-mcp-offline-安裝`](../README.md#5-vcf-mcp-offline-安裝)

### 1.3 OpenWebUI + mcpo bundle(~2.5 GB)

```bash
# build 機器要有 Docker 才能 docker save
bash runbook/scripts/prep-openwebui-bundle.sh /tmp/openwebui-offline
tar czf /tmp/openwebui-offline-bundle.tgz -C /tmp openwebui-offline
ls -lh /tmp/openwebui-offline-bundle.tgz   # ~2.5 GB
```

[`scripts/prep-openwebui-bundle.sh`](scripts/prep-openwebui-bundle.sh) 會:
- `docker pull` + `docker save` Open WebUI + mcpo 兩個 image
- copy `docker-compose.yml` / `mcpo/config.json` 範本 / `functions/` (Claude pipe 之類)
- 把 install-offline.sh 跟 README 一起塞進去

> 📄 mcpo 設定速查:[`../mcpo/`](../mcpo/)

### 1.4 把所有 bundle 搬到 air-gapped(用 USB / 跨網段 jump host)

```bash
scp /tmp/*-bundle.tgz user@<jump-host>:/srv/bundles/
# 之後從 jump host 進 air-gapped 取得這些檔案
```

---

## 階段 2 — 部署 VMs(vCenter 端)

所有 VM 從 `ubuntu2004temp` clone,用 customization spec 一次設好 hostname / IP / DNS,**不需要手動改 netplan**。

在任何有 pyvmomi 的機器(mcp-server / build 機器)上跑:

```bash
pip3 install 'pyvmomi<8.0'   # Python 3.8 鎖 <8.0;3.10+ 不用鎖

# base ollama (4c/6G/100G @ 10.0.0.63)
python3 scripts/deploy-vm.py

# ollama-14b (12c/32G/200G @ 10.0.0.67) — 選用,要跑 14B 才需要
python3 ollama-14b/scripts/deploy-vm.py
```

mcp-server / openwebui 兩台目前沒有專屬 deploy-vm.py,參考上面兩個的 pyvmomi 模板自己改 `NEW_NAME` / `NEW_IP` / `VCPU` / `MEM_MB` / `DISK_GB`。

> ⚠️ **template 跟 cloned VM 的 datastore 容量要先確認**。我們踩過 SSD3 剩 64 GB 但 clone 要 100 GB → `NoDiskSpace` 失敗,改用 `pcssd2` (427 GB) 才過。`pyvmomi` 部分 datastore moid 寫死在 script 裡,要改。

> 📄 踩雷實錄:[`../ollama-14b/README.md#1-vm-部署細節`](../ollama-14b/README.md#1-vm-部署細節),[`../llmimplementation-notes.html`](../llmimplementation-notes.html)

VM 起來後 SSH 都用 `root` / `1qaz@WSX3edc`(home.lab 預設)。

---

## 階段 3 — 安裝(在目標 VM 上)

### 3.1 ollama base @ 10.0.0.63

```bash
scp /srv/bundles/ollama-offline-bundle.tgz root@10.0.0.63:/tmp/
ssh root@10.0.0.63
tar xzf /tmp/ollama-offline-bundle.tgz -C /tmp/
bash /tmp/ollama-offline/install-offline.sh /tmp/ollama-offline
```

裝完後驗證:
```bash
ollama list                                        # 看到 llama3.2:3b
curl http://localhost:11434/api/tags | head -c 200 # JSON OK
ss -tlnp | grep 11434                              # 0.0.0.0:11434
```

### 3.2 ollama-14b @ 10.0.0.67(選用)

```bash
scp /srv/bundles/ollama-14b-offline-bundle.tgz root@10.0.0.67:/tmp/
ssh root@10.0.0.67
tar xzf /tmp/ollama-14b-offline-bundle.tgz -C /tmp/
# 14b 那台 disk 要先 resize 才能放 18 GB models
git clone https://github.com/kostenyang/OpenWebUIOllama.git /opt/setup
bash /opt/setup/ollama-14b/scripts/install-offline.sh /tmp/ollama-14b-offline
```

### 3.3 vcf-mcp @ 10.0.0.65

```bash
scp /srv/bundles/mcp-offline-bundle.tgz root@10.0.0.65:/tmp/
ssh root@10.0.0.65
tar xzf /tmp/mcp-offline-bundle.tgz -C /tmp/
bash /tmp/mcp-offline/install-mcp-offline.sh /tmp/mcp-offline
```

`install-mcp-offline.sh` 會**自動用目標 IP 重生 SAN cert**(關鍵 — 從別處搬過去的 cert SAN 還是 source IP)。

### 3.4 OpenWebUI + mcpo @ 10.0.0.64

> ⚠️ **Docker 要先裝好**。Ubuntu 20.04 minimal 沒 Docker,`get.docker.com` 又會在 `docker-model-plugin` 那邊死。手動裝:
> ```bash
> curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
> sh /tmp/get-docker.sh || true   # 失敗在 docker-model-plugin,沒關係它已經幫你加 apt repo
> apt-get install -y docker-ce docker-ce-cli containerd.io \
>     docker-compose-plugin docker-buildx-plugin
> systemctl enable --now docker
> ```
> (有外網才能跑 — 完全 air-gapped 的話,把 `docker-ce_*.deb` 等套件也打進 bundle。)

```bash
scp /srv/bundles/openwebui-offline-bundle.tgz root@10.0.0.64:/tmp/
ssh root@10.0.0.64
tar xzf /tmp/openwebui-offline-bundle.tgz -C /tmp/
bash /tmp/openwebui-offline/install-offline.sh /tmp/openwebui-offline
```

裝完後:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:3000/   # 200
docker ps                                                          # open-webui + mcpo 都 Up
```

**這時候立刻**用瀏覽器開 <http://10.0.0.64:3000/> 註冊第一個帳號 → 自動變 admin。**別人比你先註冊 admin 就變別人的**。

---

## 階段 4 — Wire-up(連線設定)

兩台 ollama 沒事接到 OpenWebUI;mcpo 設好 upstream vcf-mcp。

### 4.1 OpenWebUI ↔ Ollama

```bash
# 從 build 機器或 jump host(任何能 SSH 到 OpenWebUI 那台的地方)
bash runbook/scripts/wire-ollama.sh 10.0.0.64 \
    http://10.0.0.63:11434 \
    http://10.0.0.67:11434
```

[`scripts/wire-ollama.sh`](scripts/wire-ollama.sh) 會:
1. ssh 到 10.0.0.64,backup `docker-compose.yml`
2. 砍掉舊的 `OLLAMA_BASE_URL=...` 行
3. 用**分號**(不是逗號!)拼起新的 URL 清單寫進去
4. `docker compose up -d open-webui` recreate
5. 從 container 內 curl 兩個 ollama 的 `/api/tags` 驗證看得到 model

### 4.2 OpenWebUI ↔ mcpo ↔ vcf-mcp

```bash
bash runbook/scripts/wire-mcpo.sh \
    10.0.0.64 \
    10.0.0.65 \
    ILnx5ohq04A92X01Sk9rw9Uvjk8f0Nbd02a8wuIFZbw \
    openwebui-mcpo-secret
#   ^owui      ^mcp       ^mcp_token                              ^OpenWebUI→mcpo token
```

[`scripts/wire-mcpo.sh`](scripts/wire-mcpo.sh) 會:
1. scp upstream `/opt/vcf-mcp/cert.pem` → `/opt/open-webui/mcpo/certs/vcf-mcp.pem`
2. 寫 `/opt/open-webui/mcpo/config.json`(填好 URL + Bearer token)
3. sed 把 `docker-compose.yml` 裡的 `--api-key` 換成 `openwebui-mcpo-secret`
4. `docker compose up -d mcpo` recreate
5. 驗證:`docker logs mcpo` 看 "Successfully connected" + `/openapi.json` paths > 0 + 實際 call 一個 `/ping_host`

### 4.3 在 Open WebUI UI 加 Tool

UI 上手動最後一步(因為 OpenWebUI 沒提供 API 加 Tool):

1. <http://10.0.0.64:3000/> 登入 admin
2. **Admin Panel → Settings → Tools → +**
3. URL: `http://10.0.0.64:8000/vcf-lab`
4. API Key Type: `Bearer`,API Key: `openwebui-mcpo-secret`

加完後 chat 上勾選 `vcf-lab` Tool,LLM 就能呼叫 vCenter / ESXi 等 MCP tools。

> 📄 mcpo 維運速查:[`../mcpo/`](../mcpo/)

---

## 階段 5 — 端對端驗證

```bash
bash runbook/scripts/verify.sh
```

[`scripts/verify.sh`](scripts/verify.sh) 跑這幾組 check:

| 區塊 | 檢查 |
| --- | --- |
| Ollama × 2 | 每台:port 通、`/api/tags` 是 JSON、至少 1 個 model |
| vcf-mcp | port 通、SSE endpoint 立即回 `event:`、cert 有 SAN |
| OpenWebUI | http 200、`open-webui` container Up |
| mcpo | port 通、`/openapi.json` paths > 0、實際 call `ping_host` 成功 |
| Cross-link | OpenWebUI container 內 curl 看得到每台 ollama 的 model |

全部 PASS = 整套上線。

可用 env var 改測試對象(換 lab 就改這些):
```bash
OWUI_HOST=10.0.1.50 MCP_HOST=10.0.1.51 OLLAMA_HOSTS="10.0.1.52 10.0.1.53" \
    bash runbook/scripts/verify.sh
```

---

## 一動一動對照表

| 步驟 | Script | 跑在哪 |
| --- | --- | --- |
| 1.1 Ollama bundle | [`../scripts/prepare-offline-bundle.sh`](../scripts/prepare-offline-bundle.sh) | build 機(有網 + ollama) |
| 1.2 vcf-mcp bundle | [`../mcp/prepare-mcp-offline-bundle.sh`](../mcp/prepare-mcp-offline-bundle.sh) | 現有 mcp-server |
| 1.3 OpenWebUI bundle | [`scripts/prep-openwebui-bundle.sh`](scripts/prep-openwebui-bundle.sh) | build 機(有 Docker) |
| 2.1 deploy ollama VM | [`../scripts/deploy-vm.py`](../scripts/deploy-vm.py) | 有 pyvmomi 的機器 |
| 2.2 deploy ollama-14b VM | [`../ollama-14b/scripts/deploy-vm.py`](../ollama-14b/scripts/deploy-vm.py) | 同上 |
| 3.1 install ollama | [`../scripts/install-offline.sh`](../scripts/install-offline.sh) | target ollama VM |
| 3.2 install ollama-14b | [`../ollama-14b/scripts/install-offline.sh`](../ollama-14b/scripts/install-offline.sh) | target ollama-14b VM |
| 3.3 install vcf-mcp | [`../mcp/install-mcp-offline.sh`](../mcp/install-mcp-offline.sh) | target mcp-server VM |
| 3.4 install OpenWebUI | [`scripts/install-openwebui-offline.sh`](scripts/install-openwebui-offline.sh) | target openwebui VM |
| 4.1 wire ollama | [`scripts/wire-ollama.sh`](scripts/wire-ollama.sh) | 任何能 SSH 到 OpenWebUI 的地方 |
| 4.2 wire mcpo | [`scripts/wire-mcpo.sh`](scripts/wire-mcpo.sh) | 同上 |
| 5. verify | [`scripts/verify.sh`](scripts/verify.sh) | 任何能 reach lab 的地方 |

---

## 預期時間

| 階段 | 第一次 | 重做 |
| --- | --- | --- |
| 1. 準備 bundles | 30–60 min(下載 1.2 GB 的 Ollama tarball 是最慢的部分) | 5 min |
| 2. 部署 VMs | 5 min × N(parallel 也可) | 5 min |
| 3. 安裝 | 3–5 min/VM | 3 min/VM |
| 4. Wire-up | 1–2 min | <1 min |
| 5. Verify | 30 秒 | 30 秒 |
| **總計** | **~1.5–2 小時**(主要卡在下載) | **~20 分鐘** |

---

## Limitations / 待補

- **沒包 Docker .deb**:OpenWebUI VM 還是需要先有 Docker。真 air-gapped 環境要另外打 `docker-ce_*.deb` + `containerd.io_*.deb` + `docker-compose-plugin_*.deb`。
- **沒專屬 mcp-server / openwebui deploy-vm.py**:借 base 那個改一改。要的話可以加。
- **OpenWebUI UI 上的 Tool 設定**是手動(§4.3),OpenWebUI 沒對外 API 暴露 Tool config。
- **單台 lab 適用**:script 假設 root SSH 密碼 `1qaz@WSX3edc` 或 SSH key。換 lab 要改。
