# 部署状态机

`scripts/orchestrate.sh` 是可续跑状态机。默认情况下，`DOMAIN=<domain>` 会把状态和本地桥接文件统一放在 `~/.dirextalk/nodes/<service_id>/`，状态机读取该目录下的 `state.json`，从第一个未完成阶段继续。不带 `DOMAIN` 运行 `bash scripts/orchestrate.sh status` 会扫描 `~/.dirextalk/nodes/*/state.json` 并列出所有本地服务。

## 阶段

- **S0_PREREQ_AWS**: 校验 AWS CLI、凭据和账号身份。
- **S1_PREFLIGHT**: 校验 region、Lightsail 套餐和 Lightsail 可用区，然后选择云提供方；不查询 AWS Free Tier 或免费额度使用情况。默认 Lightsail，默认 AZ 是 `<region>a`；如果默认 AZ 不可用则选择同 region 其他可用 Lightsail AZ；如果 Lightsail 当前 region 没有可用套餐或可用区，且用户没有显式强制 Lightsail，则在 S1 记录选择 EC2。EC2 路径会校验默认 VPC、vCPU 配额、Elastic IP 可用配额和 Ubuntu 24.04 amd64 AMI。
- **S2_DOMAIN**: 确认正式长期域名和 Matrix `server_name` 不可逆绑定。
- **S3_PROVISION**: 按 S1 记录的 provider 创建资源。新部署直接选择 `dirextalk/message-server:latest`，在 `state.json.server_release` 记录 `source=default_latest`、`version=latest` 和镜像引用，不访问 message-server GitHub Release；每次新部署由容器运行时拉取当时发布的 latest 镜像。同时记录独立 updater 的 version/commit/SHA-256 pin。Lightsail 路径创建 Ubuntu 24.04 实例、密钥对、静态 IP 和防火墙端口；EC2 创建 Ubuntu 24.04 amd64 实例、密钥对、安全组、Elastic IP 和 50 GiB gp3 root EBS。两条路径的 user-data 都包含 bootstrap；在校验宿主为 Ubuntu 22.04 或 24.04 x86_64 后，bootstrap 直接下载固定 updater Release URL、核对 deployer 固定 SHA-256 并原子安装。S3 只通过 SSH 触发可续跑 bootstrap，不复制二进制。`MESSAGE_SERVER_IMAGE` 只在同时设置 `DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1` 的 debug/legacy 部署中可用。
- **LEGACY_ADOPT**: 不属于普通 S3 resume。仅 `scripts/adopt-legacy-node.sh` 在 dry-run 证明固定 d1 v0.15.2/digest/Compose/host-Caddy 拓扑并收到精确确认后，写入 `server_release.source=legacy_adopted`，生成 `/var/dirextalk-message-server` 不可变视图并调用同一 updater resume。流程不 pull、不 recreate 在线镜像；Caddy 只新增 public jobs 路由，validate/reload 失败恢复原文件。
- **S4_BOOTSTRAP_STACK**: 等云端 user-data 安装 Docker 并启动 `postgres:18 + message-server + caddy + coturn`，轮询 `https://<domain>/healthz`。
- **S5_INIT_TOKENS**: SSH 读取云端 `init-tokens.sh` 生成的 `/var/dirextalk-message-server/p2p/bootstrap.json`，归一化 `password`、`access_token`、`agent_token`、真实 `agent_room_id`。云端脚本会先调用 `portal.bootstrap`，用 `agent_token` 创建 `@agent:<server>` Matrix session，再用 owner Matrix token 创建房间并邀请/加入 agent，最后回写真正的 agent room。`password`、owner `access_token` 和 `agent_token` 按一次性/易失凭据处理；需要登录或用 token 调接口前，必须重新从服务器拉取最新 `/var/dirextalk-message-server/p2p/bootstrap.json`，不要复用旧输出。
- **S6_WIRE_LOCAL**: 写本地凭据、用 `agent_token` 创建 `@agent:<server>` Matrix session、写 `dirextalk-connect/config.toml`，写 MCP 配置片段，并按策略安装或推荐 `dirextalk-connect`。默认 `auto` 模式会等待 daemon `Running` 且日志出现 `dirextalk-connect is running`；如果日志显示 Agent CLI 缺失、未登录、workspace trust、ACP 启动失败或 agent offline，S6 失败，不会继续报告部署完成。
- **S7_VERIFY_E2E**: 验证 `/_p2p`、Matrix versions、well-known、owner.json+CORS、TURN。

## 云端 compose

- `postgres`: PostgreSQL 18，数据卷 `/var/lib/postgresql`。
- `message-init`: 生成 Dirextalk message-server 配置和 TURN 配置。
- `message-server`: 运行 Matrix + Dirextalk 统一后端，公开容器内 8008。
- `caddy`: 对外 80/443，反代 `/_matrix/*`、`/_p2p/*`，并通过只读挂载的 Unix socket 目录转发 updater public API；不挂 control token，也不依赖 message-server healthy 才启动。
- `dirextalk-updater`: root-owned systemd host service，状态和 token 分别位于 `/var/lib/dirextalk-updater` 与 `/etc/dirextalk-updater`；不再运行每日 Release discovery timer，服务端版本更新由客户端发起的目标版本任务驱动。
- `coturn`: TURN relay。

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
- 用户确认 gates: App 初始化、消息闭环、Agent/MCP runtime 验证仍需单独记录。

## 常见阻断

- DNS 未指向固定 public IP: S3 返回 waiting。Route53 模式下先检查 hosted zone/NS 委托；manual DNS fallback 下用户或 DNS provider automation 设置 A 记录后用 `DNS_READY=1` 续跑。
- `/healthz` 不通: 看 `/var/log/cloud-init-output.log` 和 `docker compose logs message-server`。
- bootstrap 缺字段: 在实例上重跑 `sudo sh -lc 'cd /var/dirextalk-message-server && DOMAIN=<domain> bash /var/dirextalk-message-server/init-tokens.sh'`，再看宿主 `/var/dirextalk-message-server/p2p/bootstrap.json` 和容器内 `/var/dirextalk-message-server/p2p/bootstrap.json`。
- `agent_room_id` 缺失或是旧伪 ID: 确认 `.env` 有 `P2P_PORTAL_PASSWORD`，然后重跑 `/var/dirextalk-message-server/init-tokens.sh`；脚本应创建真实 Matrix room 并回写。
- TURN 为空: 检查 `TURN_SECRET`、coturn、安全组 3478 和 49160-49200/udp。
