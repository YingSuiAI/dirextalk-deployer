# 部署状态机

`scripts/orchestrate.sh` 是可续跑状态机。默认情况下，`DOMAIN=<domain>` 会把状态和本地桥接文件统一放在 `~/.direxio/nodes/<service_id>/`，状态机读取该目录下的 `state.json`，从第一个未完成阶段继续。不带 `DOMAIN` 运行 `bash scripts/orchestrate.sh status` 会扫描 `~/.direxio/nodes/*/state.json` 并列出所有本地服务。

## 阶段

- **S0_PREREQ_AWS**: 校验 AWS CLI、凭据和账号身份。
- **S1_PREFLIGHT**: 校验 region、默认 VPC、vCPU 配额、Ubuntu amd64 AMI。
- **S2_DOMAIN**: 确认正式长期域名和 Matrix `server_name` 不可逆绑定。
- **S3_PROVISION**: 创建 EC2、密钥对、安全组、Elastic IP，渲染 cloud-init。默认镜像 `MESSAGE_SERVER_IMAGE=direxio/message-server:latest`。
- **S4_BOOTSTRAP_STACK**: 等 cloud-init 安装 Docker 并启动 `postgres:18 + message-server + caddy + coturn`，轮询 `https://<domain>/healthz`。
- **S5_INIT_TOKENS**: SSH 读取云端 `init-tokens.sh` 生成的 `/opt/p2p/bootstrap.json`，归一化 `password`、`access_token`、`agent_token`、真实 `agent_room_id`。云端脚本会先调用 `portal.bootstrap`，并在服务端未返回房间时用 Matrix Client API 创建和回写真实 agent room。`password` 和 owner `access_token` 按一次性/易失凭据处理；需要登录或用 token 调接口前，必须重新从服务器拉取最新 `/opt/p2p/bootstrap.json`，不要复用旧输出。
- **S6_WIRE_LOCAL**: 写本地凭据、创建 `@agent:<server>` Matrix session、写 `cc-connect/config.toml`，写 MCP 配置片段，并按策略安装或推荐 `direxio-connect`。
- **S7_VERIFY_E2E**: 验证 `/_p2p`、Matrix versions、well-known、owner.json+CORS、TURN。

## 云端 compose

- `postgres`: PostgreSQL 18，数据卷 `/var/lib/postgresql`。
- `message-init`: 生成 Direxio message-server 配置和 TURN 配置。
- `message-server`: 运行 Matrix + P2P 统一后端，公开容器内 8008。
- `caddy`: 对外 80/443，反代 `/_matrix/*` 和 `/_p2p/*`。
- `coturn`: TURN relay。

## 完成判据

部署完成后应交付:

- IM 地址: `https://<domain>`
- 登录密码: `password`
- 本地服务凭据: `~/.direxio/nodes/<service_id>/credentials.json`
- 环境文件: `~/.direxio/nodes/<service_id>/env`
- cc-connect 配置: `~/.direxio/nodes/<service_id>/cc-connect/config.toml`
- MCP 配置目录: `~/.direxio/nodes/<service_id>/mcp/`
- Matrix bridge 用户: `@agent:<server>`
- 安装命令: `npm install -g @direxio/connent@1.3.10 && direxio-connect daemon install --config <config> --service-name <service_id> --force`
- MCP 检查命令: `DIREXIO_CREDENTIALS_FILE=<credentials.json> direxio-mcp doctor --json`
- AWS 信息: region、instance id、Elastic IP、SSH 命令、state.json、destroy 命令

## 常见阻断

- DNS 未指向 EIP: S3 返回 waiting，用户设置 A 记录后用 `DNS_READY=1` 续跑。
- `/healthz` 不通: 看 `/var/log/cloud-init-output.log` 和 `docker compose logs message-server`。
- bootstrap 缺字段: 在实例上重跑 `sudo sh -lc 'cd /opt/p2p && DOMAIN=<domain> bash /opt/p2p/init-tokens.sh'`，再看宿主 `/opt/p2p/bootstrap.json` 和容器内 `/var/direxio-message-server/p2p/bootstrap.json`。
- `agent_room_id` 缺失或是旧伪 ID: 确认 `.env` 有 `P2P_PORTAL_PASSWORD`，然后重跑 `/opt/p2p/init-tokens.sh`；脚本应创建真实 Matrix room 并回写。
- TURN 为空: 检查 `TURN_SECRET`、coturn、安全组 3478 和 49160-49200/udp。
