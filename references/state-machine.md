# 部署状态机

`scripts/orchestrate.sh` 是可续跑状态机。默认情况下，`DOMAIN=<domain>` 会把状态和本地桥接文件统一放在 `~/.dirextalk/nodes/<service_id>/`，状态机读取该目录下的 `state.json`，从第一个未完成阶段继续。不带 `DOMAIN` 运行 `bash scripts/orchestrate.sh status` 会扫描 `~/.dirextalk/nodes/*/state.json` 并列出所有本地服务。

## 阶段

- **S0_PREREQ_AWS**: 校验 AWS CLI、凭据和账号身份。
- **S1_PREFLIGHT**: 校验 region、Lightsail 套餐和 Lightsail 可用区，然后选择云提供方；不查询 AWS Free Tier 或免费额度使用情况。默认 Lightsail，默认 AZ 是 `<region>a`；如果默认 AZ 不可用则选择同 region 其他可用 Lightsail AZ；如果 Lightsail 当前 region 没有可用套餐或可用区，且用户没有显式强制 Lightsail，则在 S1 记录选择 EC2。EC2 路径会校验默认 VPC、vCPU 配额、Elastic IP 可用配额和 Ubuntu 24.04 amd64 AMI。
- **S2_DOMAIN**: 确认正式长期域名和 Matrix `server_name` 不可逆绑定。
- **S3_PROVISION**: 按 S1 记录的 provider 创建资源。新部署只接受 deployer 固定的 production split release：message-server、external Agent、Caddy 的 immutable digest 与完整 source revision、唯一的 `https://imadmin.dirextalk.ai` release catalog origin，以及带 `SOURCE_REVISION`/`SOURCE_FILES.sha256` 的 canonical runtime bundle。Server 与 Agent channel 都由 Message Server 从这一个 origin 派生；Agent runtime 不接收单独的 catalog 配置。同时记录独立 updater 的 version/commit/SHA-256 pin。Lightsail 默认创建 Ubuntu 24.04、`$12 / 2GB / 60GB` 实例、密钥对、静态 IP 和防火墙端口；EC2 创建 Ubuntu 24.04 amd64 实例、密钥对、安全组、Elastic IP 和 50 GiB gp3 root EBS。user-data 只安装固定 updater；S3 在固定 SSH host identity 后传输完整 bundle 并触发可续跑 bootstrap。
- **S4_BOOTSTRAP_STACK**: 等云端启动 canonical split stack：message-server、external Agent、双 PostgreSQL、Qdrant、extension/core runners 与独立 Caddy edge，轮询 `https://<domain>/_p2p/health`。
- **S5_INIT_TOKENS**: message-server 在服务初始化时原子生成包含真实 `agent_room_id` 的完整 Portal/Agent 凭据；`bootstrap-production.sh` 通过 receipt-bound `export-portal-bootstrap.sh` 密封导出到宿主 `/var/dirextalk-message-server/p2p/bootstrap.json`。S5 只通过 SSH 读取该导出件并归一化 `password`、`access_token`、`agent_token` 和 `agent_room_id`，不补写凭据或房间状态。这些凭据按一次性/易失凭据处理，使用前必须重新获取当前导出件。
- **S6_WIRE_LOCAL**: 写本地凭据、用 `agent_token` 创建 `@agent:<server>` Matrix session、写 `dirextalk-connect/config.toml`，写 MCP 配置片段，并按策略安装或推荐 `dirextalk-connect`。默认 `auto` 模式会等待 daemon `Running` 且日志出现 `dirextalk-connect is running`；如果日志显示 Agent CLI 缺失、未登录、workspace trust、ACP 启动失败或 agent offline，S6 失败，不会继续报告部署完成。
- **S7_VERIFY_E2E**: 验证 `/_p2p`、Matrix versions、well-known、owner.json+CORS、TURN。最终交付还必须通过现有 `verify runtime`，确认 dirextalk-connect daemon 为 `Running`、日志出现 `dirextalk-connect is running` 且没有 Agent backend error，并通过 MCP runtime checks。

## 云端 Compose

- canonical split 应用项目由 `/var/dirextalk-message-server/deploy/split-agent/compose.yaml` 和受保护的 `/var/dirextalk-message-server/split/.env` 定义，包含独立的 message/Agent PostgreSQL、Qdrant、coturn、初始化 job、message-server、external Agent 与 extension/core runners。
- Caddy 是独立 edge Compose 项目，使用 canonical `deploy/split-agent/edge-compose.yaml`、root-owned `production-ops/edge-compose.override.yaml` 和受保护的 `edge.env`。它对外提供 80/443，反代 Matrix/ProductCore，并通过只读 Unix socket 目录转发 updater public API；不挂 control token。
- `dirextalk-updater`: root-owned systemd host service，状态和 token 分别位于 `/var/lib/dirextalk-updater` 与 `/etc/dirextalk-updater`；不再运行每日 Release discovery timer，服务端版本更新由客户端发起的目标版本任务驱动。

## 完成判据

S7 自动验收通过后应交付:

- App 域名: `<domain>`
- 八位 App 初始化码: 后端 `password` 字段的当前值
- 本地服务凭据: `~/.dirextalk/nodes/<service_id>/credentials.json`
- MCP endpoint 由 `state.json` 与 `dirextalk-connect/config.toml` 的当前消费者持有，不再生成无人消费的 `mcp/env`
- dirextalk-connect 配置: `~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml`
- MCP 配置目录: `~/.dirextalk/nodes/<service_id>/mcp/`
- Matrix bridge 用户: `@agent:<server>`
- 安装命令: `npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest && ~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config <config> --service-name <service_id> --force`
- 启动验证: `~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon status --service-name <service_id>` 和同一 binary 的 `daemon logs --service-name <service_id> -n 120`
- MCP endpoint: `https://<domain>/mcp`; use `DOMAIN=<domain> bash scripts/orchestrate.sh verify mcp_doctor` and `verify mcp_tools` for runtime checks.
- AWS 信息: region、cloud provider、instance id、固定 public IP、Route53 hosted zone、SSH 命令、state.json、destroy 命令
- 自动完成 gate: S0-S7 与 `verify runtime` 全部通过；App 初始化和首次真实聊天属于后续产品使用，不是部署后确认步骤。

## 常见阻断

- DNS 未指向固定 public IP: S3 返回 waiting。Route53 模式下先检查 hosted zone/NS 委托；manual DNS fallback 下用户或 DNS provider automation 设置 A 记录后用 `DNS_READY=1` 续跑。
- `/_p2p/health` 不通: 看 `/var/log/cloud-init-output.log`；应用栈用受保护的 `split/.env` + canonical `deploy/split-agent/compose.yaml` 查 `ps`/`logs message-server`，edge 栈用 `edge.env` + canonical `edge-compose.yaml` + root-owned override 查 `logs caddy`。
- bootstrap 缺字段或 `agent_room_id` 不是真实 Matrix room: 视为当前 message-server/bootstrap contract 失败，保留日志与导出件元数据并停止；不得手工拼凭据或创建 fallback 房间。修复服务端后走正常 fresh reset 或 receipt-bound reconcile。
- TURN 为空: 检查 split 栈的 `coturn` 健康状态、受保护的 `turnserver.conf`/`turn-shared-secret`、stable public IP receipt，以及安全组 3478 tcp+udp 和 49160-49200/udp。
