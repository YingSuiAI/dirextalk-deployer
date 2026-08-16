# 架构原理

本部署器已经适配新版 Dirextalk message-server: AS 业务合并进 Dendrite 单体后端，不再部署独立 `asd` 服务。

## 服务拓扑

```text
公网 443/80 -> Caddy
  ├─ /agent/v1/*                         -> agent:8082
  ├─ /_matrix/*, /_dendrite/*, /_synapse/* -> message-server:8008
  ├─ /_p2p/*                              -> message-server:8008
  ├─ /_dirextalk/updater/v1/jobs/*        -> /run/dirextalk-updater/http.sock
  ├─ /.well-known/matrix/*                -> Caddy 静态响应
  └─ /.well-known/portal/*                -> message-server:8008

message-server -> PostgreSQL 18
coturn         -> TURN 3478 + 49160-49200/udp
```

- **message-server**: 新部署使用 `latest` release channel，并核对 version/revision 与真实二进制版本；承载 Matrix homeserver 和 ProductCore，并通过固定内部边界访问 external Agent。
- **Agent**: 使用独立的 `latest` release channel，并核对 revision 与三个真实二进制版本；与 Message Server 共用单一 PostgreSQL/pgvector 容器，但使用隔离的非超级用户角色、database 和私有数据库网络，并拥有 extension/core runners 与更新 wrapper。客户端通过同域 `/agent/v1/*` 访问 Agent 数据面，Caddy 在内部网络转发到 `agent:8082`；Agent 端口不直接发布到公网。
- **PostgreSQL 18 + pgvector**: 单一容器和持久化卷；message-server 与 Agent 使用相互隔离的非超级用户角色、database 和私有数据库网络，只有 Agent database 启用 `vector` extension。
- **Caddy**: 独立 edge Compose 项目的唯一 HTTP/TLS 入口，自动签发 Let's Encrypt。
- **dirextalk-updater**: 独立 GitHub 仓库/Release 的 linux/amd64 binary；production split 主机要求 Ubuntu 24.04+、systemd >= 254。deployer 固定 version/commit/SHA-256，宿主下载校验后作为 root-owned systemd service 安装。它独立于 Compose；Caddy 只读挂其 socket 目录，不接触 control token，也不安装每日 GitHub discovery timer。
- **coturn**: WebRTC TURN relay，Dirextalk message-server 通过 shared-secret 动态签发 TURN 凭证。

## 启动顺序

1. `postgres` healthy。
2. `message-init` 生成 `/etc/dirextalk-message-server/message-server.yaml` 和 signing key，并写入 TURN 配置。
3. `Agent` 完成迁移并进入 healthy；其 HTTP 数据面只监听容器网络端口 `8082`。
4. `message-server` 在 Agent healthy 后启动，加载 Matrix + Dirextalk 控制面，读取 `P2P_PORTAL_PASSWORD` 和 `P2P_PORTAL_CREDENTIALS_FILE`。
5. `message-server` 在受保护数据卷内原子生成包含真实 `agent_room_id` 的完整 Portal/Agent 凭据。canonical `export-portal-bootstrap.sh` 校验容器与 stack 归属后，将当前凭据密封导出到宿主 `/var/dirextalk-message-server/p2p/bootstrap.json`；Deployer 不补写凭据或房间状态。
6. `message-server` 的 `/.well-known/portal/owner.json` handler 动态返回 owner discovery。
7. `caddy` 对外服务 Agent 数据面、Matrix、Dirextalk API、静态站点和 well-known；`/agent/v1/*` 的 SSE 响应关闭代理缓冲，其他既有路由保持独立。

## 凭据模型

`/var/dirextalk-message-server/p2p/bootstrap.json` 会包含:

- `password`: 后端字段名；对用户展示时是八位 App 初始化码。
- `access_token`: 当前用户的统一 bearer token，可用于 Matrix `/_matrix/client/*` 和需要用户身份的 Dirextalk 调用。
- `agent_token`: 本地服务凭据中的 agent bearer token；`dirextalk-connect` 对话桥接使用 S6 创建的 `@agent:<server>` Matrix session。
- `agent_room_id`: 真实 Matrix 房间 ID。部署脚本拒绝旧式 `!agent:<domain>` 伪房间。

## 域名模型

Matrix `server_name` 必须是长期真实域名。部署后更换 `DOMAIN` 等同创建新的 homeserver 身份，不要保留旧 PostgreSQL/message-server 数据卷后直接改域名。
