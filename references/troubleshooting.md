# 排障手册

先 ssh 上机器，主战场是 cloud-init 日志和 compose 状态。

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
- Let's Encrypt 429 限流（too many certificates already issued）: 同一域名 7 天内申请超过 5 次会触发。SSH 上机器用 `docker logs p2p-caddy-1 | grep 429` 确认。**临时解决**：在 Caddyfile 的 `{$DOMAIN} {` 后加一行 `tls internal`，重启 Caddy（`docker compose -f /opt/p2p/docker-compose.yml restart caddy`），然后用 `curl -sk --resolve <domain>:443:<EIP> https://<domain>/healthz` 验证。部署完成后恢复原始 Caddyfile 去掉 `tls internal` 并重启 Caddy，Caddy 会在限流解除后自动申请正式证书。详见 `deployment-lessons.md` 的 Let's Encrypt 章节。

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
