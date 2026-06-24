# 部署状态机

`scripts/orchestrate.sh` 是可续跑状态机。它读取 `$P2P_WORKDIR/state.json`，从第一个未完成阶段继续。

## 阶段

- **S0_PREREQ_AWS**: 校验 AWS CLI、凭据和账号身份。
- **S1_PREFLIGHT**: 校验 region、默认 VPC、vCPU 配额、Ubuntu amd64 AMI。
- **S2_DOMAIN**: 确认正式长期域名和 Matrix `server_name` 不可逆绑定。
- **S3_PROVISION**: 创建 EC2、密钥对、安全组、Elastic IP，渲染 cloud-init。默认镜像 `MESSAGE_SERVER_IMAGE=direxio/message-server:latest`。
- **S4_BOOTSTRAP_STACK**: 等 cloud-init 安装 Docker 并启动 `postgres:18 + message-server + caddy + coturn`，轮询 `https://<domain>/healthz`。
- **S5_INIT_TOKENS**: SSH 读取 `/opt/p2p/bootstrap.json`，归一化 `password`、`access_token`、`agent_token`、`agent_room_id`。
- **S6_WIRE_LOCAL**: 写 `~/.direxio/nodes/<service_id>/credentials.json` 和服务 env，记录当前 agent runtime。
- **S7_VERIFY_E2E**: 验证 `/_p2p`、Matrix versions、well-known、owner.json+CORS、TURN。

## 云端 compose

新版不再部署独立 AS/asd。compose 服务为:

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
- 环境变量: `DIREXIO_DOMAIN`、`DIREXIO_AGENT_TOKEN`、`DIREXIO_AGENT_ROOM_ID`
- 集成目标: `@direxio/local-mcp` 和 `@direxio/agent-plugins`
- AWS 信息: region、instance id、Elastic IP、SSH 命令、state.json、destroy 命令

## 常见阻断

- DNS 未指向 EIP: S3 返回 waiting，用户设置 A 记录后用 `DNS_READY=1` 续跑。
- `/healthz` 不通: 看 `/var/log/cloud-init-output.log` 和 `docker compose logs message-server`。
- bootstrap 缺字段: 重跑 `DOMAIN=<domain> bash /opt/p2p/init-tokens.sh`，再看容器内 `/var/direxio-message-server/p2p/bootstrap.json`。
- TURN 为空: 检查 `TURN_SECRET`、coturn、安全组 3478 和 49160-49200/udp。
