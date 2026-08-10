# 架构原理

本部署器已经适配新版 Dirextalk message-server: AS 业务合并进 Dendrite 单体后端，不再部署独立 `asd` 服务。

## 服务拓扑

```text
公网 443/80 -> Caddy
  ├─ /_matrix/*, /_dendrite/*, /_synapse/* -> message-server:8008
  ├─ /_p2p/*                              -> message-server:8008
  ├─ /_dirextalk/updater/v1/jobs/*        -> /run/dirextalk-updater/http.sock
  ├─ /.well-known/matrix/*                -> Caddy 静态响应
  └─ /.well-known/portal/*                -> message-server:8008

message-server -> PostgreSQL 18
coturn         -> TURN 3478 + 49160-49200/udp
```

- **message-server**: 新部署使用 deployer 固定的 immutable digest/source revision；承载 Matrix homeserver 和 ProductCore，并通过固定内部边界访问 external Agent。
- **Agent**: 独立 immutable image；与 Message Server 共用单一 PostgreSQL/pgvector 容器，但使用隔离的非超级用户角色、database 和私有数据库网络，并拥有 extension/core runners 与更新 wrapper；Flutter 不直接连接它。
- **PostgreSQL 18 + pgvector**: 单一容器和持久化卷；message-server 与 Agent 使用相互隔离的非超级用户角色、database 和私有数据库网络，只有 Agent database 启用 `vector` extension。
- **Caddy**: 独立 edge Compose 项目的唯一 HTTP/TLS 入口，自动签发 Let's Encrypt。
- **dirextalk-updater**: 独立 GitHub 仓库/Release 的 linux/amd64 binary；production split 主机要求 Ubuntu 24.04+、systemd >= 254。deployer 固定 version/commit/SHA-256，宿主下载校验后作为 root-owned systemd service 安装。它独立于 Compose；Caddy 只读挂其 socket 目录，不接触 control token，也不安装每日 GitHub discovery timer。
- **coturn**: WebRTC TURN relay，Dirextalk message-server 通过 shared-secret 动态签发 TURN 凭证。

## 启动顺序

1. `postgres` healthy。
2. `message-init` 生成 `/etc/dirextalk-message-server/message-server.yaml` 和 signing key，并写入 TURN 配置。
3. `message-server` 启动，加载 Matrix + Dirextalk 业务，读取 `P2P_PORTAL_PASSWORD` 和 `P2P_PORTAL_CREDENTIALS_FILE`。
4. `message-server` 在受保护数据卷内原子生成包含真实 `agent_room_id` 的完整 Portal/Agent 凭据。canonical `export-portal-bootstrap.sh` 校验容器与 stack 归属后，将当前凭据密封导出到宿主 `/var/dirextalk-message-server/p2p/bootstrap.json`；Deployer 不补写凭据或房间状态。
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

## Agent Cloud Worker edge 基础契约

Agent Cloud Worker 的 `WorkerControl`、`Model Relay` 和受控 HTTPS
`CONNECT` proxy 都保持端到端 TLS。Worker edge 只读取 TLS ClientHello 的
SNI 后透传原始 TCP 字节，不能终止 TLS 后再建立第二条 TLS 连接。

private 拓扑使用同 Region、default VPC 内的独立 edge EC2、EIP、
官方 HAProxy Alpine immutable image 和 edge-local Squid。它不占用或改动 S2
Lightsail 上现有 Caddy 的 `:443`：三个公网 A 记录指向 edge EIP；private
hosted zone 的同名 A 记录指向 edge private IP。当前开发规则让长期 edge SG 对
部署时显式指定并回读验证的私有 Worker 子网 CIDR 放行全协议/全端口；它不接受
`0.0.0.0/0` 或公网 CIDR。edge 主机上的 HAProxy 仍只监听 `443`，并将三个互异
SNI 分别透传到 S2 private IP 的
`10443`/`11443` 和 edge 本机 Squid TLS listener；未知或缺少 SNI 直接拒绝。

`worker-edge-compose.yaml` 只接受官方 HAProxy Alpine immutable digest 和经
message split bundle 构建、验证并以 digest 固定的 Squid Alpine image。
`verify-worker-edge-image.sh` 在激活前通过 `haproxy -vv` 和对渲染配置执行
`haproxy -c` 验证镜像与配置。该基础包默认不启动，也不创建 AWS 资源。
Compose 同时运行 Squid service，并只在 edge 主机的 `127.0.0.1` 暴露受控 TLS
CONNECT listener；Squid image 和 exact-FQDN policy 由 owning message split
edge bundle 提供。缺少该 service 及其 allow-list/readback gate 时，Worker
edge 能力保持关闭。

该基础包不是自动激活路径。激活前还必须由 owning Agent/Compose contract
提供三个互不复用的 TLS listener、证书/信任摘要和 Squid policy，完成
三个 public/private DNS 记录和安全组规则，并验证 fresh-state TLS、gRPC、relay 和 CONNECT
路径。部署 Region 通过 `DIREXTALK_WORKER_EDGE_REGION` 显式传入，不能固定为
某一区域。`DIREXTALK_WORKER_EDGE_ROUTE_MODE=private` 需要不可变私网路径证明；
另一个允许值是部署时显式选择的 `controlled-public`。该模式可以让 edge 与
S2 位于不同 Region；HAProxy 只把 WorkerControl/Model Relay 的 SNI 流量送往
经过回读的 S2 public IP `10443`/`11443`，Lightsail firewall 只允许经过回读的
edge EIP `/32`。这不是 private 模式失败后的 fallback，运行时不得在两种模式间
静默切换。

`read-worker-edge-evidence.sh` 在每个 AWS read 前重新验证 STS account，按不可变
Lightsail ARN/support code、edge instance ID、EIP allocation、hosted zone 和 edge SG ID
读取资源，并要求所有 run-owned 资源带精确 owner/account-generation/run-id tags。
它同时回读 public/private DNS、Lightsail control listener firewall、edge SG 精确的
私有 Worker 子网 CIDR 全协议/全端口入站、DNS/TLS-only 出站规则和最终 backend 地址；长期
evidence 不读取或声称验证一次性 Worker SG 的 egress。随后它原子写入 mode `0600` 的
`dirextalk-worker-edge-evidence-v3`。`render-worker-edge.sh` 只接受这份 evidence，
再次绑定 account、owner/generation、两个 Region、route mode 和全部 endpoint 后，
把实际文件 SHA-256 写进 HAProxy 配置。当前 Lightsail VPC peering 为 `false`，所以
只能使用明确的 `controlled-public`，不能声称 private 可达。
