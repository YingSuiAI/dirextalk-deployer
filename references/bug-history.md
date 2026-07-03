# 踩坑记录(按修复 PR 归类)

部署链路上所有真实踩过的坑。**已全部修进 `scripts/` 下的部署文件**,新部署不会再撞;
列在这里是为了:① 理解每个设计决策的来由;② 若有人改坏了哪处,能快速定位回退点。

## Legacy pre-Dirextalk message-server 仓库

### AS PR #4 — 镜像多架构
- **症状**:ARM 架构 EC2(t4g 系列)`docker pull` 后 `exec format error`。
- **根因**:镜像只 build 了 amd64。
- **修复**:CI 用 buildx 出 `amd64+arm64` 多架构镜像。legacy pre-Dirextalk AS 镜像已是多架构。

### AS PR #5 — 容器化体验
- **卷权限**:命名卷默认 root:700,AS 降权到 asd(UID 10001)后打不开 sqlite → `SQLITE_CANTOPEN`。
  修复:entrypoint chown `/var/dirextalk-message-server` `/data` 后再 `su-exec asd`。
- **无健康检查**:compose 无法判断 AS 就绪。修复:Dockerfile 加 `HEALTHCHECK` 探 `:9090/healthz`。
- **registration 路径写死**:registration.yaml 落在 cwd 不可配。修复:加 `RegistrationPath` 配置项。

### AS PR #5 遗留 — GHA 缓存(⚠️ 未合主干)
- **症状**:长时 arm64 build 时 Azure cache 的 SAS token 过期 → `403 AuthenticationFailed`,CI 失败。
- **影响**:**只影响"重新打 AS 镜像"**;部署默认用已发布的 public 镜像,不打包就不踩。
- **状态**:提交过 cache-disable 修复,但没进 PR #5 的 squash-merge。**待补一个独立 PR。**

## 部署脚本

### ops PR #2 — 一键部署主体
依次撞过、已全部修掉:
1. **docker compose 插件不在 Amazon Linux**(且早期下错架构 x86 装到 ARM)→ 改用 `get.docker.com` 装,自带 compose v2。
2. **asd.yaml chmod 600** 让容器内 asd 读不到 → cloud-init write_files 用 0600 但属主对。
3. **Dendrite SQLite broken**(element-hq/dendrite#3435,`near "SEQUENCE" syntax error`)→ 加 `postgres:16-alpine`,Dendrite 连 PG。
4. **Caddyfile `email {$ACME_EMAIL}` 为空** → `wrong argument count`。修复:删掉默认 email 块,Caddy 自动签不需要 email。
5. **Dendrite 启动早于 AS 写 registration** → 竞态。修复:compose `depends_on: asd service_healthy` + `postgres service_healthy`。
6. **旧 init-tokens.sh 经 Caddy 308 跳转** → HTTP 初始化失败。当前流程改为在 message-server 健康后等待 bind-mounted `/var/dirextalk-message-server/p2p/bootstrap.json`。
7. **init-tokens.sh CRLF** → `pipefail: invalid option name`。修复:文件存为 LF(`sed -i 's/\r$//'`)。

### ops PR #3 — owner.json 发现
- **症状**:client 探 `/.well-known/portal/owner.json` 得 404 → 误报 "Portal 未部署"。
- **历史根因**:旧 AS 没有 owner.json HTTP handler,只能靠 deployer 写静态文件再让 Caddy serve。
- **当前修复**:新版 message-server 在 `/.well-known/portal/owner.json` 提供动态 handler 并带 CORS；Caddy 直接 reverse proxy 到 message-server。deployer 不再写 `owner.json` 文件,也不再挂载 wellknown 静态目录。

### ops VoIP — 通话连不上 = 没 TURN relay
- **症状**:语音/视频通话信令(`m.call.*`)互通,但 WebRTC 连不上;`/_matrix/client/v3/voip/turnServer` 返回 `{}`,ICE 只有 host/srflx 无 relay → 跨 NAT/防火墙必失败。**纯后端缺口,非前端。**
- **修复**(第一版明文 turn:3478,不上 TLS):
  - compose 加 `coturn`(`network_mode: host` + `--use-auth-secret` + `--static-auth-secret=${TURN_SECRET}` + `--external-ip=${PUBLIC_IP}` + `--min/max-port 49160-49200`)。
  - s3 安全组开 `3478 udp/tcp` + `49160-49200/udp`。
  - user-data 从 IMDS public-ipv4 落 `PUBLIC_IP`,随机生成 `TURN_SECRET`,都写进 .env。
  - dendrite entrypoint 追加 `client_api.turn`(`turn_shared_secret` 同 TURN_SECRET + `turn_uris` turn:DOMAIN:3478 udp/tcp)→ homeserver 动态签短期凭证。
  - S7 加 turnServer 非空校验。
- **重部署勿删**:coturn/端口/turn 段已固化进 skill;后续简化部署时不要删,否则铲掉重起会再丢通话能力。
- **难查点**:Dendrite 的 `turn_shared_secret` 必须 == coturn `--static-auth-secret`(都来自 .env `TURN_SECRET`),不一致 → turnServer 返回凭证但 relay 拒绝。详见 `voip-turn-runbook.md`。

## 机型/内存类
- **机型默认 t3.small(2GB)**:postgres + dendrite + asd + caddy 四容器同机,2GB 实测能稳跑,不靠 swap。
  想更省钱可换 t3.micro(1GB),但 1GB 跑 4 容器 + 首次拉镜像易 OOM,届时需在 cloud-init 装 Docker 前
  自配 2GB swap(`/swapfile`,`vm.swappiness=10`)兜底。默认不开,避免无谓复杂度。
- **架构固定 x86/amd64**:状态机 S3 的 AMI 锁 `.../amd64/...`,机型默认 t3.small,**不走 ARM**——
  规避 AS PR #4 那类"单架构镜像在 ARM 上 `exec format error`"的坑(虽然现镜像已多架构,x86 更省心)。

## 真·全新账号 + macOS 端到端实测踩坑(2026-06-01,已全部修)
这批来自一次真实"干净 macOS + 全新 AWS 账号"跑 skill 的实测,是之前没做过的端到端验证:
- **macOS 默认 bash 3.2 不支持 `declare -A`**:`orchestrate.sh` 一启动就崩。修:阶段→脚本映射改用 `case`(`phase_file()`),不再用关联数组。
- **S0 只认 AK/SK,本机有 `AWS_PROFILE` 也误判"没凭证"**:修:直接 `aws sts get-caller-identity` 判断凭证有效性(支持 profile/AK/SK/角色),仅在 sts 失败且既无 AK/SK 也无 AWS_PROFILE 时才算等用户。
- **user-data 超 16384 字节硬上限**:三份部署文件各自 base64 内联会超限,AWS 报 `User data is limited to 16384 bytes`。修:打成一个 `bundle.tar.gz` 单条内联,开机 runcmd 第一步解包到 `/var/dirextalk-message-server`。实测降到 ~11KB。
- **AS 读不到 `asd.yaml`(`permission denied`)**:把只读配置叠挂进 `/var/dirextalk-message-server` 与降权用户 cwd 冲突。修:`asd.yaml` 改挂 `/etc/p2p/asd.yaml`,`--config` 指向新路径;`/var/dirextalk-message-server` 只作共享运行输出目录。
- **EC2 自带 `*.compute.amazonaws.com` 签不了 Let's Encrypt**(`rejectedIdentifier`)。历史修复曾给验收/试用流程加过 `<公网IP>.sslip.io` 临时域名,用于绕过 EC2 默认域名不能签证书的问题。当前正式部署接口已经移除该路径:没有最终域名时 S2 直接阻断,不创建 EC2;Matrix `server_name` 必须使用用户长期持有并能管理 DNS 的正式域名。
- **宿主机读不到凭据文件**:message-server 在容器内写 `/var/dirextalk-message-server/p2p/bootstrap.json`,宿主机 S5 无法直接读取 Docker named volume。修:compose 把容器 `/var/dirextalk-message-server/p2p` bind 到宿主同路径,S5 用 `ssh ... sudo cat /var/dirextalk-message-server/p2p/bootstrap.json`。
- **旧 HTTP 初始化抢跑 Dendrite**:早期脚本主动发初始化请求,Dendrite 没 ready 时会返回 500,但脚本可能误判成功。当前流程已移除主动初始化请求,由 AS 启动成功后自行写 `bootstrap.json`;`init-tokens.sh` 只等待文件完整,失败即不写 `.deploy-done`,状态机如实反映失败。
- **(client 侧,不在本仓库)** `/_as/auth` 返回容器内网 `http://dendrite:8008`,App 在用户机访问不到 → 前端遇到 `dendrite` 这类内部 host 时回退到用户输入的公网 Portal 地址。

## 机型/内存类(承上)

## 本机/环境类(不在仓库,属操作经验)
- **本地代理截断 AWS/lark 的 TLS**:AWS 公共前置已 `export NO_PROXY="*"` 并 unset 代理。lark-cli 用 `LARK_CLI_NO_PROXY=1`。
- **PowerShell 生成 SSH key 时 `-N '""'`** 把字面 `"` 当密码 → 加密私钥登录失败。正确:`-N ''`(单引号空)。
