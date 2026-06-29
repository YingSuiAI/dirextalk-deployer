# Direxio Deployer

`direxio-deployer` 是用于部署生产 Direxio message server 的通用 Agent Skill，并通过 Direxio 专用 Matrix 桥接把本地 agent room 接到当前 agent。当前本地桥接只支持 `direxio-connect`，安装包是 `direxio-connent`，源码仓库是 `YingSuiAI/direxio-connect`。S6 也会给 Codex、OpenClaw、Hermes 这类支持 MCP 的宿主写入服务级 MCP 配置片段。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS/EC2/DNS/cloud-init/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、cc-connect wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## 部署原则

- 只部署到真实、长期域名。
- Matrix `server_name` 一旦绑定，后续换域名等同新 homeserver。
- AWS 资源会产生费用，部署前必须让用户明确确认。
- Route53 模式会复用或创建 hosted zone，记录 NS nameservers，自动 upsert A 记录，并等待 DNS 生效。
- 用户侧 DNS 模式只是没有 DNS provider 自动化时的 fallback；它会在 Elastic IP 创建后暂停，等待 A 记录指向新 IP。
- 当前后端是 `direxio/message-server` 单体服务，Matrix 与 P2P API 共用 8008。
- cloud-init 会生成 `P2P_PORTAL_PASSWORD`；`init-tokens.sh` 会调用 `portal.bootstrap`，并在后端凭据文件没有真实房间时创建 Matrix agent room。
- 从服务端同步的 `password` 和 owner `access_token` 按一次性/易失凭据处理；后端字段 `password` 对用户来说是八位 App 初始化码。展示初始化码或调接口前先重新拉取服务器 `/opt/p2p/bootstrap.json`，不要复用旧输出。
- S6 会拒绝 `!agent:<domain>` 这类旧伪房间，只接受 message-server 创建的真实 Matrix `agent_room_id`。
- S6 会通过 `agent.matrix_session.create` 创建 `@agent:<server>` Matrix session，写入 Matrix-only `cc-connect/config.toml`，并把 bridge 限制在当前 `agent_room_id`。
- S6 会在 `~/.direxio/nodes/<service_id>/mcp/` 下写入 MCP client 配置片段。MCP 通过 `DIREXIO_CREDENTIALS_FILE` 指向同一个服务级 `credentials.json`；cc-connect 仍然只使用直接 Matrix 配置。
- `DIREXIO_CC_CONNECT_AGENT` 用来选择本地 `direxio-connect` agent 类型。支持值与 connent/connect 一致：`acp`、`antigravity`、`claudecode`、`codex`、`copilot`、`cursor`、`devin`、`gemini`、`iflow`、`kimi`、`opencode`、`pi`、`qoder`、`reasonix`、`tmux`。
- `DIREXIO_AGENT_PLATFORM` 表示正在执行部署 skill 的宿主运行时；`DIREXIO_CC_CONNECT_AGENT` 表示 `direxio-connect` 要启动的本地 agent 后端。检测到 OpenClaw 或 Hermes 运行时时，S6 会通过通用 `acp` agent 写入桥接配置，不会写成 connect 原生 `type = "openclaw"` 或 `type = "hermes"`。OpenClaw 会写入 `cmd = "openclaw"`，但必须由当前 agent/operator 提供真实 Gateway URL、token-file 和 ACP session；Hermes 默认写入 `cmd = "direxio-connect"`、`args = ["hermes-acp-adapter", "--", "hermes", "acp"]`，通过兼容层避免 Hermes 推理文本被当成用户可见回复。
- 当本地 agent 可执行文件不能从 PATH 找到时，设置 `DIREXIO_CC_CONNECT_AGENT_CMD` 或 `DIREXIO_<AGENT>_COMMAND`。Codex Desktop 在 Windows 下也可以继续使用 `DIREXIO_CODEX_COMMAND`；OpenClaw 支持 `DIREXIO_OPENCLAW_COMMAND`；Hermes 使用 `DIREXIO_HERMES_COMMAND` 指定 adapter 后面的子进程命令，只有 adapter 命令本身不是 `direxio-connect` 时才需要 `DIREXIO_HERMES_ACP_ADAPTER_COMMAND`。
- `DIREXIO_AGENT_INSTALL=auto` 会安装 `direxio-connent` 并执行 `direxio-connect daemon install --config <config> --service-name <service_id> --force`。默认 `recommend` 只记录并打印命令。自动安装只有在 `direxio-connect daemon status --service-name <service_id>` 返回 `Status: Running` 且近期 daemon 日志没有 ACP session 初始化失败时才记为 installed，否则 S6 会记录 `agent_install_status=install_failed`。

## 最小命令

从 AWS CSV 导入并验证一个部署 profile。推荐使用临时 `DirexioDeployer` IAM
用户；如果操作者明确选择 root access key，也允许继续：

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer us-east-1
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
```

在仓库根目录运行：

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --instance-type t3.small \
  --disk-gb 8 \
  --domain-mode user
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

Windows 用户使用 PowerShell 入口。它会选择 Git Bash 执行云端 phase，同时给本地 `direxio-connect` 写入 Windows 可直接使用的路径：

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:INSTANCE_TYPE = "t3.small"
$env:MESSAGE_SERVER_IMAGE = "direxio/message-server:latest"
.\scripts\orchestrate.ps1
```

仅写入并推荐本地 bridge：

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

自动安装本地 bridge：

```bash
DIREXIO_AGENT_INSTALL=auto \
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_CC_CONNECT_AGENT=claudecode \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

可选安装模式：`recommended`、`cc-connect`。
如果 `DIREXIO_AGENT_PLATFORM=auto` 无法唯一识别当前运行时，显式设置 `DIREXIO_CC_CONNECT_AGENT`。需要触发 OpenClaw 或 Hermes 默认配置时，设置 `DIREXIO_AGENT_PLATFORM=openclaw` 或 `DIREXIO_AGENT_PLATFORM=hermes`；只设置 `DIREXIO_CC_CONNECT_AGENT=acp` 会进入通用 ACP，需要手动提供 options。OpenClaw Gateway ACP 必须在完成 pairing 后，从当前 OpenClaw runtime 填写 `DIREXIO_OPENCLAW_ACP_URL`、`DIREXIO_OPENCLAW_ACP_TOKEN_FILE` 和 `DIREXIO_OPENCLAW_ACP_SESSION`。只有需要完整覆盖 OpenClaw ACP args 数组时才使用 `DIREXIO_OPENCLAW_ACP_ARGS_TOML`；Hermes 自定义参数用 `DIREXIO_HERMES_ACP_ARGS_TOML`，S6 会自动在前面加上 `hermes-acp-adapter -- <hermes-command>`。

查看状态：

```bash
bash scripts/orchestrate.sh status
DOMAIN=<domain> bash scripts/orchestrate.sh status
```

销毁已记录资源：

```bash
DOMAIN=<domain> bash scripts/destroy.sh
```

Windows 用户使用 PowerShell 销毁入口：

```powershell
$env:DOMAIN = "<domain>"
.\scripts\destroy.ps1
```

销毁时只会在 `direxio-connect daemon status --service-name <service_id>` 返回的 `WorkDir` 等于当前服务的
`~/.direxio/nodes/<service_id>/cc-connect` 目录时停止并卸载本地 daemon，然后删除该
service 目录。

更新现有节点但不删除数据：

```bash
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=direxio/message-server:latest bash scripts/update.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

重置应用数据但保留 EC2、DNS、固定 IP 和 Caddy TLS：

```bash
DIREXIO_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
P2P_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

## 本地 Bridge

S6 会在 `~/.direxio/nodes/<service_id>/` 下写入：

```text
credentials.json
env
cc-connect/config.toml
cc-connect/data/
cc-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

手动安装：

```bash
npm install -g direxio-connent
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

MCP 安装和检查：

```bash
npm install -g direxio-mcp
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json direxio-mcp doctor --json
```

Codex 使用 `mcp/codex.toml`，Hermes 使用 `mcp/hermes.mcp.json`。OpenClaw 使用 `mcp/openclaw.md` 中生成的 `openclaw mcp set` 命令读取 `mcp/openclaw-server.json`；不要把 MCP JSON 直接粘贴到 `~/.openclaw/openclaw.json`。

语音输入在配置 STT provider key 后可用。设置 `DIREXIO_SPEECH_API_KEY` 或 `DIREXIO_SPEECH_QWEN_API_KEY` 等 provider 专用变量后，S6 会在 `cc-connect/config.toml` 写入 `[speech] enabled = true`。

Homebrew 文档使用：

```bash
brew install direxio-connect
```

源码构建：

```bash
git clone https://github.com/YingSuiAI/direxio-connect.git
cd connect
make build AGENTS=<cc-connect-agent> PLATFORMS_INCLUDE=matrix
```

## 验证

```bash
bash tests/skill_structure_test.sh
bash tests/default_paths_test.sh
bash tests/s6_wire_local_test.sh
bash tests/destroy_local_bridge_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```
