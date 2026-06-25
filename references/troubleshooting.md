# 排障手册

先 ssh 上机器，主战场是 cloud-init 日志和 compose 状态。

## 本轮 MCP / gateway 问题复盘

这类问题优先从运行环境归属开始排查，不要先改云端服务:

- 当前对话在 Windows 原生 Codex 中时，不要在 WSL 里启动 gateway。WSL 只能用于部署脚本或辅助命令；gateway 要跟随实际 agent 进程所在的 OS。
- runtime 检测要看 active-process 信号和 `.codex/tmp` 这类当前会话路径，不能因为历史存在 `~/.hermes`、`~/.codex` 等目录就判定当前 agent。
- `DIREXIO_AGENT_NODE_ID` 不能复用旧部署的值。脚本只接受包含当前域名的 node id；跨域复用必须显式设置 force。
- `@direxio/local-mcp` 当前按 direct `DIREXIO_DOMAIN`、`DIREXIO_AGENT_TOKEN`、`DIREXIO_AGENT_ROOM_ID`、`DIREXIO_AGENT_NODE_ID` 读取配置。MCP payload 只写 credentials 文件路径会导致服务不可读。
- 如果 `npx` 通过包名直跑没有 JSON-RPC 输出，改用包内 bin 名或本地安装后的 `node node_modules/.../dist/index.js` 验证，先确认 MCP `initialize` 和 `tools/list` 能返回。
- Windows Codex gateway 如果因为 WindowsApps alias 或权限问题无法 spawn `codex`，用 `$env:LOCALAPPDATA\OpenAI\Codex\bin` 动态发现真实 `codex.exe`，并设置 `DIREXIO_CODEX_COMMAND`。发布文档只能使用 `%USERPROFILE%`、`$env:USERPROFILE`、`$HOME`、`CODEX_HOME` 等变量，不要写入某台机器的绝对用户路径。

## 上机看现场

```bash
ssh -i <key.pem> ubuntu@<ip>
sudo cat /var/log/cloud-init-output.log
cd /opt/p2p
docker compose ps
docker compose logs message-server --tail=100
docker compose logs postgres --tail=80
docker compose logs caddy --tail=50
docker compose logs coturn --tail=50
```

## 健康检查超时

首次拉镜像、初始化 PostgreSQL、签 Let's Encrypt 证书可能需要几分钟。仍不过时:

- `exec format error`: 镜像架构不匹配，确认 `MESSAGE_SERVER_IMAGE` 是可在 EC2 架构运行的镜像，默认是 `direxio/message-server:latest`。
- `postgres` 不 healthy: 看 `docker compose logs postgres --tail=80`。
- `message-server` 不 healthy: 看 `docker compose logs message-server --tail=100`，并确认 `/etc/direxio-message-server/message-server.yaml` 已生成。
- 证书签不下来: 确认 80/443 安全组放行，且 `dig +short <domain>` 已解析到当前 EIP。

## owner.json / Portal 未部署

```bash
curl -ski -H 'Origin: http://127.0.0.1:51820' https://<domain>/.well-known/portal/owner.json
docker compose exec caddy ls -l /srv/p2p/wellknown/
sudo ls -l /opt/p2p/wellknown/
```

期望是 HTTP 200、JSON 响应，并有 `Access-Control-Allow-Origin`。文件由 `init-tokens.sh` 根据 `/opt/p2p/bootstrap.json` 生成。

## federation 超时

检查:

```bash
curl -sk https://<domain>/.well-known/matrix/server
```

期望:

```json
{"m.server":"<domain>:443"}
```

## init-tokens.sh 等不到 bootstrap.json

```bash
cd /opt/p2p
DOMAIN=<domain> bash init-tokens.sh
docker compose exec message-server ls -l /var/direxio-message-server/p2p/
docker compose exec message-server cat /var/direxio-message-server/p2p/bootstrap.json
```

- 脚本 CRLF: `sed -i 's/\r$//' init-tokens.sh`。
- 缺 `password`、`access_token`、`agent_token`: 看 `message-server` 日志。
- 宿主文件不存在但容器内存在: 手动重跑 `DOMAIN=<domain> bash init-tokens.sh`。

## 统一 API 鉴权

```bash
curl -sk -X POST https://<domain>/_p2p/query \
  -H "Authorization: Bearer <AGENT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"action":"apis.list","params":{}}'
```

401 通常是 S6 没回填最新 token，按 `token-refresh.md` 检查。

## TURN

先用 `portal.auth` 换统一 access token:

```bash
ACCESS_TOKEN=$(curl -sk -X POST https://<domain>/_p2p/command \
  -H "Content-Type: application/json" \
  -d '{"action":"portal.auth","params":{"password":"<LOGIN_PASSWORD>"}}' | jq -r '.access_token')
curl -sk https://<domain>/_matrix/client/v3/voip/turnServer \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

返回应包含非空 `uris`、`username`、`password`、`ttl`。为空时检查 coturn、安全组 3478/49160-49200、以及 `.env` 中 `TURN_SECRET` 是否同时被 message-server 和 coturn 使用。
