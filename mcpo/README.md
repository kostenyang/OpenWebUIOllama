# mcpo — OpenWebUI ↔ vcf-mcp 的 OpenAPI 代理

`mcpo` 是 [open-webui/mcpo](https://github.com/open-webui/mcpo) 出的小工具,把 MCP 協定(SSE / stdio)的 server 包成 OpenAPI HTTP server,**讓只吃 OpenAPI 的 Open WebUI Tools 也能用 MCP**。

```
[Open WebUI :3000] ──HTTP/OpenAPI──▶ [mcpo :8000] ──HTTPS+SSE──▶ [vcf-mcp :7000]
   同台 (10.0.0.64)                     同台                    10.0.0.65 (self-signed cert)
   docker container                     docker container
```

本目錄不包安裝程式 — mcpo 跟 Open WebUI 一起裝,完整安裝步驟在 [openwebui-repo §7](https://github.com/kostenyang/openwebui#7-進階接-mcp-server--用-mcpo-當-openapi-代理)。這份是**設定速查**:平常維運要改什麼設定、改完要 reload 哪個服務、token 在哪。

---

## 設定散在三個地方

| # | 檔案 / 位置 | 控制什麼 |
| --- | --- | --- |
| 1 | `/opt/open-webui/docker-compose.yml` 的 `mcpo:` block | 容器本身(port、command args、env、volume mount) |
| 2 | `/opt/open-webui/mcpo/config.json` | mcpo 連的上游 MCP servers(URL、token、type) |
| 3 | `/opt/open-webui/mcpo/certs/vcf-mcp.pem` | 信任上游自簽 cert(httpx 要這個) |
| 4 | Open WebUI Admin UI → Settings → Tools | 把 mcpo 加成 Tool(URL + Bearer token) |

### #1 compose entry

```yaml
mcpo:
  image: ghcr.io/open-webui/mcpo:main
  container_name: mcpo
  restart: always
  ports:
    - "8000:8000"
  volumes:
    - ./mcpo/config.json:/app/config.json:ro
    - ./mcpo/certs/vcf-mcp.pem:/certs/vcf-mcp.pem:ro
  environment:
    - SSL_CERT_FILE=/certs/vcf-mcp.pem
    - REQUESTS_CA_BUNDLE=/certs/vcf-mcp.pem
  command: ["--host","0.0.0.0","--port","8000",
            "--api-key","openwebui-mcpo-secret",
            "--config","/app/config.json"]
```

> ⚠️ `command:` 改了之後要 `docker compose up -d mcpo`(**recreate**)才會吃,光 `restart` 沒用 — compose 把 command 當建立時的引數,restart 只重啟舊容器。

### #2 config.json — 上游 MCP servers

```json
{
  "mcpServers": {
    "vcf-lab": {
      "type": "sse",
      "url": "https://10.0.0.65:7000/sse",
      "headers": {
        "Authorization": "Bearer <vcf-mcp-token>"
      }
    }
  }
}
```

加第二個上游?在 `mcpServers` 底下加另一個 key 就好:

```json
{
  "mcpServers": {
    "vcf-lab":    { "type": "sse", "url": "https://10.0.0.65:7000/sse", "headers": {...} },
    "github-mcp": { "type": "sse", "url": "https://other-host:7000/sse", "headers": {...} },
    "local-tool": { "type": "stdio", "command": "uvx", "args": ["my-mcp-server"] }
  }
}
```

`type` 支援:
- `sse` — Server-Sent Events(本 lab vcf-mcp 用這個)
- `streamable_http` — 新版 HTTP transport
- `stdio` — 本地 process,mcpo 自己 fork

config.json 改完:`docker compose restart mcpo`(這個有效,因為 config 從 volume mount 進來)。

### #3 cert — 上游 self-signed 必裝

> ⚠️ Python ≥ 3.10 / httpx 已經**完全不認 CN-only 的 cert**,必須有 `subjectAltName`。 不裝 / SAN 不對 → mcpo log 吐 `[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: IP address mismatch`。

cert 從上游 scp 過來:
```bash
scp root@10.0.0.65:/opt/vcf-mcp/cert.pem \
    /opt/open-webui/mcpo/certs/vcf-mcp.pem
```

上游 cert SAN 不對的話跑 [`../mcp/gen-san-cert.sh`](../mcp/gen-san-cert.sh) 重生。

### #4 Open WebUI 端加 Tool

UI:
1. <http://10.0.0.64:3000/> 登入 admin
2. 右上頭像 → **Admin Panel** → **Settings** → **Tools**
3. **+** 新增:
   - URL: `http://10.0.0.64:8000/vcf-lab`(路徑後面那段 = config.json 裡的 key)
   - API Key Type: `Bearer`
   - API Key: 跟 #1 的 `--api-key` 一致

加完馬上 fetch `openapi.json`,把每個 MCP tool 變成 Open WebUI 看得到的工具。

---

## Token 三層(常搞混)

| 連線 | Token | 哪邊定義 | 哪邊驗證 |
| --- | --- | --- | --- |
| Browser → Open WebUI | (UI 登入 cookie) | OpenWebUI 自己 | OpenWebUI 自己 |
| Open WebUI → mcpo | `openwebui-mcpo-secret` | mcpo `--api-key` | mcpo |
| mcpo → vcf-mcp | `ILnx5...` | mcpo `config.json` `Authorization` header | vcf-mcp `/opt/vcf-mcp/keys.json` |

換哪一層只要動對應的兩端,**剩下兩端不用碰**。

---

## 常見維運場景

### 換上游 MCP token

```bash
# 1. 上游加新 token
ssh root@10.0.0.65
python3 -c 'import json,secrets; \
  d=json.load(open("/opt/vcf-mcp/keys.json")); \
  d["admin"]=secrets.token_urlsafe(32); \
  json.dump(d, open("/opt/vcf-mcp/keys.json","w"), indent=2)'
systemctl restart vcf-mcp

# 2. mcpo 端改 config.json 帶新 token
ssh root@10.0.0.64
vim /opt/open-webui/mcpo/config.json    # 改 Authorization header
docker compose restart mcpo

# 3. 驗證
docker logs mcpo --tail 10               # 看到 "Successfully connected to MCP server: vcf-lab"
curl -s -H 'Authorization: Bearer openwebui-mcpo-secret' \
  http://10.0.0.64:8000/vcf-lab/openapi.json | jq '.paths | keys | length'
```

### 換 OpenWebUI ↔ mcpo 之間 token

```bash
vim /opt/open-webui/docker-compose.yml   # 改 --api-key
cd /opt/open-webui
docker compose up -d mcpo                # recreate (注意不是 restart!)
# 然後 Open WebUI → Admin → Settings → Tools → 編輯該 Tool → 改 API Key
```

### 加第二個上游 MCP server

```bash
vim /opt/open-webui/mcpo/config.json   # 加另一個 mcpServers entry
docker compose restart mcpo
# Open WebUI Admin → Tools → 再 + 加一個,URL=http://10.0.0.64:8000/<新key>
```

### 上游 cert 過期 / SAN 不對

```bash
# 上游 (10.0.0.65) 重生
bash /opt/setup/mcp/gen-san-cert.sh /opt/vcf-mcp 10.0.0.65
systemctl restart vcf-mcp

# openwebui (10.0.0.64) 拉新 cert
scp root@10.0.0.65:/opt/vcf-mcp/cert.pem /opt/open-webui/mcpo/certs/vcf-mcp.pem
docker compose restart mcpo
```

---

## 端對端驗證

```bash
# 1. mcpo 容器跑著嗎
docker ps --format '{{.Names}}\t{{.Status}}' | grep mcpo
# mcpo    Up 5 days

# 2. mcpo 跟上游連得起來?(看 log)
docker logs mcpo --tail 20 | grep -iE "connected|error|fail"
# INFO - Successfully connected to MCP server: vcf-lab

# 3. tool schema 抓得到?
curl -s -H 'Authorization: Bearer openwebui-mcpo-secret' \
  http://10.0.0.64:8000/vcf-lab/openapi.json | jq '.paths | keys | length'
# 10

# 4. 實際呼叫某個 tool 通?
curl -s -X POST -H 'Authorization: Bearer openwebui-mcpo-secret' \
  -H 'Content-Type: application/json' \
  -d '{"host":"10.0.0.1","count":1}' \
  http://10.0.0.64:8000/vcf-lab/ping_host
# "PING 10.0.0.1 ... 1 packets transmitted, 1 received, 0% packet loss..."
```

4 個都過 = mcpo 端整段 OK,可以放心 ship。

---

## 常見壞掉模式

| 症狀 | 原因 | 解法 |
| --- | --- | --- |
| `docker logs mcpo` 吐 `ConnectTimeout` | 上游 vcf-mcp 沒回 TLS handshake | 上游 `systemctl restart vcf-mcp`(SSE session 累積到上限) |
| `IP address mismatch, certificate is not valid for ...` | 上游 cert 只有 CN 沒 SAN | 跑 [`../mcp/gen-san-cert.sh`](../mcp/gen-san-cert.sh) |
| `SSL certificate verify failed` | mcpo 容器沒掛 cert / SSL_CERT_FILE 沒設 | 檢查 #1 的 volume + env |
| `/openapi.json` paths 是 `{}` | mcpo 啟動時 upstream 沒回應,沒拉到 tool schema | 上游修好後 `docker compose restart mcpo` 重抓 |
| Open WebUI Tool 加上去 401 | API Key 跟 mcpo `--api-key` 不一致 | 對齊兩邊 |
| `peer closed connection without sending complete message body` | 上游 vcf-mcp 重啟,mcpo SSE 被切 | 通常 mcpo 會自動重連,看後續 log 有沒有 `Successfully connected` |
| Tool 列表是空的或一直 timeout | 上游 vcf-mcp stale session 太多 | mcp-server 跑 `systemctl restart vcf-mcp`(已加 12h 自動重啟,見 [`../mcp/`](../mcp/)) |

---

## 與本 repo 其他組件的關係

```
ollama (10.0.0.63)         ─┐
ollama-14b (10.0.0.67)     ─┤
                            ├── Open WebUI (10.0.0.64) ──┐
vcf-mcp (10.0.0.65) ── mcpo ┘                            └── user browser
       ↑                              ↑
       本檔講這段                  Tools 從 mcpo OpenAPI 進來
```

- Ollama 的接法走 `OLLAMA_BASE_URL`(分號分隔多 backend),不經過 mcpo
- vcf-mcp tools 一定要過 mcpo(OpenWebUI 沒 native MCP client)
- 換句話說:mcpo 死 = chat 還能聊,只是 VCF tools 用不了
