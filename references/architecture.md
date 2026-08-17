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

- **message-server**: 每个 fresh deployment 从 Docker Hub `latest` 发现当前版本，核对对应稳定 `vX.Y.Z` 标签、source revision 与 linux/amd64 manifest digest，并在创建基础设施前冻结到 `state.json`；retry/resume 不重新解析。运行时继续使用该稳定版本标签。它承载 Matrix homeserver 和 ProductCore，并通过固定内部边界访问 external Agent。
- **Agent**: 每个 fresh deployment 通过独立 `latest` 通道完成相同的稳定标签、source revision 与 linux/amd64 manifest digest 校验，并与 Message Server snapshot 原子冻结；existing node 保留已有 receipt。Cloud Worker 的主机区域只来自已验证部署主机的不可变区域，不读取上传凭据的默认区域，也不跨区域 fallback。它与 Message Server 共用单一 PostgreSQL/pgvector 容器，但使用隔离的非超级用户角色、database 和私有数据库网络，并拥有 extension/core runners 与更新 wrapper。客户端通过同域 `/agent/v1/*` 访问 Agent 数据面，Caddy 在内部网络转发到 `agent:8082`；Agent 端口不直接发布到公网。
- **PostgreSQL 18 + pgvector**: 单一容器和持久化卷；message-server 与 Agent 使用相互隔离的非超级用户角色、database 和私有数据库网络，只有 Agent database 启用 `vector` extension。
- **Caddy**: 独立 edge Compose 项目的唯一 HTTP/TLS 入口，自动签发 Let's Encrypt。
- **dirextalk-updater**: 独立 GitHub 仓库/Release 的 linux/amd64 binary；production split 主机要求 Ubuntu 24.04+、systemd >= 254。deployer 固定 version/commit/SHA-256，宿主下载校验后作为 root-owned systemd service 安装。fresh deployment 写入 `watchdog_enabled=false`：保留 root-owned control plane 和显式 update/recovery job，但不启动常驻 Docker-event/轮询修复 watchdog。它独立于 Compose；Caddy 只读挂其 socket 目录，不接触 control token，也不安装每日 GitHub discovery timer。
- **生产运行拓扑**: `dirextalk-deployer/scripts/cloud-init/split/runtime` 是 Compose、宿主生命周期、镜像更新与恢复 wrapper 的唯一源码；Message Server 与 Agent 仓库只发布各自正式版本镜像。
- **coturn**: WebRTC TURN relay，Dirextalk message-server 通过 shared-secret 动态签发 TURN 凭证。

## 启动顺序

1. `postgres` healthy。
2. `message-server-init` 生成 Message Server 配置以及 Capability CA、证书、方向 token 和 grant signing key。
3. `message-server` 在 `postgres`、`coturn` 和初始化 job 就绪后启动并先通过健康检查；它不依赖 Agent 运行时健康。
4. Deployer 随后显式启动 `agent-secret-init`、`agent-migrate`、extension/core runners 和 `agent`；`agent-secret-init` 将已绑定主机区域的受保护配置写入 `agent_config_material`，Agent HTTP 数据面只监听容器网络端口 `8082`。
5. 若 Agent 路径失败但同一个 receipt-bound Message Server 仍健康，fresh bootstrap 保留 IM、继续启动 Edge 并导出凭据，返回 `3`。受保护恢复会跳过已成功的 Agent job，按精确容器 ID 重跑未成功的 `agent-secret-init`、`agent-migrate`，再停止三项 Agent 长驻容器、重建 runner cgroup 委派并只启动 Agent 路径；Message Server/基础设施失败返回 `1` 并清理 fresh stack。
6. `message-server` 在受保护数据卷内原子生成包含真实 `agent_room_id` 的完整 Portal/Agent 凭据。canonical `export-portal-bootstrap.sh` 校验容器与 stack 归属后，将当前凭据密封导出到宿主 `/var/dirextalk-message-server/p2p/bootstrap.json`；Deployer 不补写凭据或房间状态。
7. `message-server` 的 `/.well-known/portal/owner.json` handler 动态返回 owner discovery。
8. `caddy` 对外服务 Agent 数据面、Matrix、Dirextalk API、静态站点和 well-known；`/agent/v1/*` 的 SSE 响应关闭代理缓冲，其他既有路由保持独立。

## 凭据模型

`/var/dirextalk-message-server/p2p/bootstrap.json` 会包含:

- `password`: 后端字段名；对用户展示时是八位 App 初始化码。
- `access_token`: 当前用户的统一 bearer token，可用于 Matrix `/_matrix/client/*` 和需要用户身份的 Dirextalk 调用。
- `agent_token`: 本地服务凭据中的 agent bearer token；`dirextalk-connect` 对话桥接使用 S6 创建的 `@agent:<server>` Matrix session。
- `agent_room_id`: 真实 Matrix 房间 ID。部署脚本拒绝旧式 `!agent:<domain>` 伪房间。

## 域名模型

Matrix `server_name` 必须是长期真实域名。部署后更换 `DOMAIN` 等同创建新的 homeserver 身份，不要保留旧 PostgreSQL/message-server 数据卷后直接改域名。
