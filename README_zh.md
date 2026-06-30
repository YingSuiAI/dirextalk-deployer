# Direxio Deployer

`direxio-deployer` 是用于部署生产 Direxio message server 的通用 Agent Skill，并通过 Direxio 专用 Matrix 桥接把本地 agent room 接到当前 agent。当前本地桥接只支持 `direxio-connect`，安装包是 `direxio-connent`，源码仓库是 `YingSuiAI/direxio-connect`。S6 也会给 Codex、OpenClaw、Hermes 这类支持 MCP 的宿主写入服务级 MCP 配置片段。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS/EC2/DNS/cloud-init/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、cc-connect wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## 部署前准备

- 准备 AWS 账号、AWS access key CSV 或 profile，以及真实长期域名或子域名。
- deployer 创建的 AWS 资源在销毁前可能持续计费。
- `SKILL.md` 是给智能体看的运行手册，详细部署规则、确认门禁、运行时 wiring 和恢复流程都放在那里。

## Skill 安装和更新

通过 npm 安装 deployer skill，再把它写入当前智能体运行时的 skill 目录。默认推荐 project-local 安装，让部署 skill 跟随当前 workspace。

POSIX shell：

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex --scope project --project .
```

Windows PowerShell：

```powershell
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex --scope project --project .
```

在同一个宿主运行时中更新已安装 skill：

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex --scope project --project .
```

根据当前运行时替换 agent 名称：`codex`、`claudecode`、`gemini`、`cursor`、`copilot`、`openclaw`、`hermes`、`opencode`、`qoder`、`reasonix`，或使用 `references/agent-targets.md` 中列出的其他目标。只有明确想安装到宿主级目录时才使用 `--scope global`：

```bash
direxio-deployer skill install --agent codex --scope global
```

安装器会在目标目录写入 `.direxio-skill-install.json`，并拒绝覆盖没有该 manifest 的既有目录，除非显式传入 `--force`。如需固定版本，先安装指定 npm 版本：

```bash
npm install -g direxio-deployer@0.1.0
direxio-deployer skill update --agent codex --scope project --project .
```

这个 CLI 由 Node 实现，并使用当前宿主的原生路径。Windows 下写入 Windows 路径；Linux、macOS、Git Bash 或 WSL 下写入对应运行时能读取的路径。

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
