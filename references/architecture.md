# 架构原理

本部署器已经适配新版 Dirextalk message-server: AS 业务合并进 Dendrite 单体后端，不再部署独立 `asd` 服务。

## 服务拓扑

```text
公网 443/80 -> Caddy
  ├─ /_matrix/*, /_dendrite/*, /_synapse/* -> message-server:8008
  ├─ /_p2p/*                              -> message-server:8008
  ├─ /_dirextalk/updater/v1/jobs/*        -> /run/dirextalk-updater/http.sock
  ├─ /.well-known/matrix/*                -> Caddy 静态响应
  ├─ /.well-known/portal/*                -> message-server:8008
  └─ /healthz                             -> /_p2p/health

message-server -> PostgreSQL 18
coturn         -> TURN 3478 + 49160-49200/udp
```

- **message-server**: 新部署直接使用 `dirextalk/message-server:latest`，不在本地部署器中访问 message-server GitHub Release；同时承载 Matrix homeserver 和 `/_p2p/query`/`/_p2p/command`，只读挂 updater socket 目录和 control-token file，不挂 Docker socket。
- **PostgreSQL 18**: Matrix 与 Dirextalk 业务表共库持久化，compose 使用 `/var/lib/postgresql`。
- **Caddy**: 唯一 HTTP/TLS 入口，自动签发 Let's Encrypt。
- **dirextalk-updater**: 独立 GitHub 仓库/Release 的 linux/amd64 binary，支持 Ubuntu 22.04 和 24.04；deployer 固定 version/commit/SHA-256，宿主下载校验后作为 root-owned systemd service 安装。它独立于 Compose；Caddy 只读挂其 socket 目录，不接触 control token，也不安装每日 GitHub discovery timer。
- **coturn**: WebRTC TURN relay，Dirextalk message-server 通过 shared-secret 动态签发 TURN 凭证。

## 启动顺序

1. `postgres` healthy。
2. `message-init` 生成 `/etc/dirextalk-message-server/message-server.yaml` 和 signing key，并写入 TURN 配置。
3. `message-server` 启动，加载 Matrix + Dirextalk 业务，读取 `P2P_PORTAL_PASSWORD` 和 `P2P_PORTAL_CREDENTIALS_FILE`。
4. `message-server` 通过 bind mount 直接写宿主 `/var/dirextalk-message-server/p2p/bootstrap.json`。`init-tokens.sh` 调用 `portal.bootstrap`；如果最新服务端没有写入 `agent_room_id`，脚本会通过 Matrix Client API 创建真实 agent room、邀请并加入 `@agent:<server>`，再把 `agent_room_id` 回写到凭据文件。
5. `message-server` 的 `/.well-known/portal/owner.json` handler 动态返回 owner discovery。
6. `caddy` 对外服务 Matrix、Dirextalk API 和 well-known。

## 凭据模型

`/var/dirextalk-message-server/p2p/bootstrap.json` 会包含:

- `password`: 后端字段名；对用户展示时是八位 App 初始化码。
- `access_token`: 当前用户的统一 bearer token，可用于 Matrix `/_matrix/client/*` 和需要用户身份的 Dirextalk 调用。
- `agent_token`: 本地服务凭据中的 agent bearer token；`dirextalk-connect` 对话桥接使用 S6 创建的 `@agent:<server>` Matrix session。
- `agent_room_id`: 真实 Matrix 房间 ID。部署脚本拒绝旧式 `!agent:<domain>` 伪房间。

## 域名模型

Matrix `server_name` 必须是长期真实域名。部署后更换 `DOMAIN` 等同创建新的 homeserver 身份，不要保留旧 PostgreSQL/message-server 数据卷后直接改域名。
