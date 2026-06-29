# 架构原理

本部署器已经适配新版 Direxio message-server: AS 业务合并进 Dendrite 单体后端，不再部署独立 `asd` 服务。

## 服务拓扑

```text
公网 443/80 -> Caddy
  ├─ /_matrix/*, /_dendrite/*, /_synapse/* -> message-server:8008
  ├─ /_p2p/*                              -> message-server:8008
  ├─ /.well-known/matrix/*                -> Caddy 静态响应
  ├─ /.well-known/portal/*                -> /opt/p2p/wellknown 静态文件
  └─ /healthz                             -> /_p2p/health

message-server -> PostgreSQL 18
coturn         -> TURN 3478 + 49160-49200/udp
```

- **message-server**: `direxio/message-server:latest`，同时承载 Matrix homeserver 和 `/_p2p/query`/`/_p2p/command`。
- **PostgreSQL 18**: Matrix 与 P2P 业务表共库持久化，compose 使用 `/var/lib/postgresql`。
- **Caddy**: 唯一 HTTP/TLS 入口，自动签发 Let's Encrypt。
- **coturn**: WebRTC TURN relay，Direxio message-server 通过 shared-secret 动态签发 TURN 凭证。

## 启动顺序

1. `postgres` healthy。
2. `message-init` 生成 `/etc/direxio-message-server/message-server.yaml` 和 signing key，并写入 TURN 配置。
3. `message-server` 启动，加载 Matrix + P2P 业务，读取 `P2P_PORTAL_PASSWORD` 和 `P2P_PORTAL_CREDENTIALS_FILE`。
4. `init-tokens.sh` 调用 `portal.bootstrap`，从容器复制凭据到宿主 `/opt/p2p/bootstrap.json`。如果最新服务端没有写入 `agent_room_id`，脚本会通过 Matrix Client API 创建真实 agent room、邀请并加入 `@agent:<server>`，再把 `agent_room_id` 回写到宿主和容器凭据文件。
5. `init-tokens.sh` 生成 `/opt/p2p/wellknown/owner.json`。
6. `caddy` 对外服务 Matrix、P2P API 和 well-known。

## 凭据模型

`/opt/p2p/bootstrap.json` 会包含:

- `password`: 后端字段名；对用户展示时是八位 App 初始化码。
- `access_token`: 当前用户的统一 bearer token，可用于 Matrix `/_matrix/client/*` 和需要用户身份的 P2P 调用。
- `agent_token`: 本地服务凭据中的 agent bearer token；`direxio-connect` 对话桥接使用 S6 创建的 `@agent:<server>` Matrix session。
- `agent_room_id`: 真实 Matrix 房间 ID。部署脚本拒绝旧式 `!agent:<domain>` 伪房间。

## 域名模型

Matrix `server_name` 必须是长期真实域名。部署后更换 `DOMAIN` 等同创建新的 homeserver 身份，不要保留旧 PostgreSQL/message-server 数据卷后直接改域名。
