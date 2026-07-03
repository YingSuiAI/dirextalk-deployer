# Direxio Deployer

`direxio-deployer` 是用于部署生产 Direxio message server 的通用 Agent Skill，并通过 Direxio 专用 Matrix 桥接把本地 agent room 接到当前 agent。当前本地桥接只支持 `direxio-connect`，安装包是 `direxio-connent`，源码仓库是 `YingSuiAI/direxio-connect`。S6 也会给 Codex、Cursor、OpenClaw、Hermes 这类支持 MCP 的宿主写入服务级 MCP 配置片段。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS Lightsail/EC2/DNS/user-data/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、direxio-connect wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## 部署前准备

- 准备 AWS 账号、AWS access key CSV 或 profile，以及真实长期域名或子域名。
- deployer 创建的 AWS 资源在销毁前可能持续计费。新部署默认优先使用 Lightsail 12 美元/月 Linux 套餐。未使用过 Lightsail 的用户一般会有三个月免费额度；新用户注册 AWS 一般有 100-200 美元的免费额度。一切以 AWS 官方实时政策为准。S1 会在确认前查询 Lightsail 套餐和可用区；如果要手工查可用区，使用 `aws lightsail get-regions --include-availability-zones --output json`，裸 `get-regions` 可能不返回可用区明细。如果所选 region 没有可用 Lightsail 资源，推荐和选择会切到 EC2。需要显式 EC2 时设置 `DIREXIO_CLOUD_PROVIDER=ec2`，新建 EC2 默认使用 50 GiB gp3 root EBS 卷。
- `SKILL.md` 是给智能体看的运行手册，详细部署规则、确认门禁、运行时 wiring 和恢复流程都放在那里。

## Skill 安装和更新

通过 npm 安装 deployer skill，再把它写入当前智能体运行时的 skill 目录。默认安装到所选智能体运行时的全局 skill 目录；只有在明确希望跟随某个仓库或 workspace 时，才指定 project-local 安装。

GitHub 仓库保留测试用于维护和 CI，但发布到 npm 的包以及安装到智能体 skill 目录的副本不包含 `tests/`，以减小用户安装体积。

如果你想让 Codex 一句话安装并开始部署，不要说“安装 skills <GitHub 链接>”。那会触发 GitHub skill 安装器，而不是 npm 管理的安装器。推荐只说短句，把仓库地址作为读取 README 的位置，并让 agent 按 README 中的 npm 安装规则执行：

```text
请阅读 https://github.com/YingSuiAI/direxio-deployer 的 README，并按其中 npm 安装规则安装 skill，然后部署 Direxio，域名 __DOMAIN__。
```

Agent 读到这句后应执行下方 npm 安装命令；不要改用 GitHub skill installer。

POSIX shell：

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
```

Windows PowerShell：

```powershell
npm install -g direxio-deployer@latest
direxio-deployer skill install --agent codex
```

在同一个宿主运行时中更新已安装 skill：

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex
```

根据当前运行时替换 agent 名称：`codex`、`claudecode`、`gemini`、`cursor`、`copilot`、`openclaw`、`hermes`、`opencode`、`qoder`、`reasonix`，或使用 `references/agent-targets.md` 中列出的其他目标。只有明确想安装到某个项目目录时才使用 `--scope project --project <path>`：

```bash
direxio-deployer skill install --agent codex --scope project --project .
```

安装器会在目标目录写入 `.direxio-skill-install.json`，并拒绝覆盖没有该 manifest 的既有目录，除非显式传入 `--force`。普通安装和更新使用 `@latest`：

```bash
npm install -g direxio-deployer@latest
direxio-deployer skill update --agent codex
```

这个 CLI 由 Node 实现，并使用当前宿主的原生路径。Windows 下写入 Windows 路径；Linux、macOS、Git Bash 或 WSL 下写入对应运行时能读取的路径。

## 最小命令

从 AWS CSV 导入并验证一个部署 profile。root access key 是首次部署最快路径，
但权限极高；请安全保存 CSV，部署后轮换或删除密钥。临时
`DirexioDeployer` IAM 用户更安全，但 AWS 控制台步骤更多：

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv direxio-deployer us-east-1
export AWS_PROFILE=direxio-deployer
bash scripts/aws-credentials.sh verify direxio-deployer
```

在仓库根目录运行：

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --cloud-provider lightsail \
  --domain-mode user
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

`DIREXIO_CLOUD_PROVIDER=lightsail` 可省略，因为 Lightsail 是默认选择。如需保留的 EC2 部署路径，添加 `DIREXIO_CLOUD_PROVIDER=ec2`。EC2 可继续设置 `INSTANCE_TYPE=t3.small` 或更大的显式规格，并默认使用 50 GiB gp3 root EBS 卷。如果默认 Lightsail 在当前 region 没有可用套餐或可用区，S1 会在 provisioning 前把选择记录为 EC2。除非在排查 AWS 返回值，否则让 S1 自动检测 Lightsail 可用性；安全的手工命令是 `aws lightsail get-regions --include-availability-zones --output json`。

Windows 用户使用 PowerShell 入口。它会选择 Git Bash 执行云端 phase，同时给本地 `direxio-connect` 写入 Windows 可直接使用的路径：

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:DOMAIN_MODE = "user"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:DIREXIO_CLOUD_PROVIDER = "lightsail"
$env:MESSAGE_SERVER_IMAGE = "direxio/message-server:latest"
.\scripts\orchestrate.ps1
```

仅写入并推荐本地 bridge 和 MCP：

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

默认会自动安装本地 bridge 和 MCP。只有自动检测不明确时才需要显式设置 runtime：

```bash
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_CONNECT_AGENT=claudecode \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

可选安装模式：`recommended`、`direxio-connect`。
如果 `DIREXIO_AGENT_PLATFORM=auto` 无法唯一识别当前运行时，显式设置 `DIREXIO_CONNECT_AGENT`。S6 会为生成的 agent options 默认写入 `mode = "yolo"`；如果 `DIREXIO_CONNECT_AGENT_OPTIONS_TOML` 或 `DIREXIO_CURSOR_MODE` 显式提供 `mode`，仍以显式值为准。Windows 上的 Cursor 接线使用 `%LOCALAPPDATA%\cursor-agent\agent.cmd`。若 `agent.cmd status` 显示未登录，先交互执行一次 `agent.cmd login`，然后重新运行 deployer，它会刷新配置并重启 daemon。需要触发 OpenClaw 或 Hermes 默认配置时，设置 `DIREXIO_AGENT_PLATFORM=openclaw` 或 `DIREXIO_AGENT_PLATFORM=hermes`；只设置 `DIREXIO_CONNECT_AGENT=acp` 会进入通用 ACP，需要手动提供 options。OpenClaw Gateway ACP 默认写入 `["acp", "--session", "agent:main:main"]`，让 `openclaw acp` 从 `~/.openclaw/openclaw.json` 自动发现 Gateway。需要强制指定 Gateway 时，完成 pairing 后从当前 OpenClaw runtime 同时填写 `DIREXIO_OPENCLAW_ACP_URL`、`DIREXIO_OPENCLAW_ACP_TOKEN_FILE` 和 `DIREXIO_OPENCLAW_ACP_SESSION`。只有需要完整覆盖 OpenClaw ACP args 数组时才使用 `DIREXIO_OPENCLAW_ACP_ARGS_TOML`；Hermes 自定义参数用 `DIREXIO_HERMES_ACP_ARGS_TOML`，S6 会自动在前面加上 `hermes-acp-adapter -- <hermes-command>`。

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
`~/.direxio/nodes/<service_id>/direxio-connect` 目录时停止并卸载本地 daemon，然后删除该
service 目录。

更新现有节点但不删除数据：

```bash
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=direxio/message-server:latest bash scripts/update.sh
```

镜像刷新只重启远端服务，不重置本地 credentials、`direxio-connect`、MCP
配置、用户确认和 runtime checks。

重置应用数据但保留 EC2、DNS、固定 IP 和 Caddy TLS：

```bash
DIREXIO_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
DIREXIO_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

清理应用数据卷后，后续 orchestrate 会重新生成本地 credentials/MCP 配置，
并默认自动重新安装/重启 `direxio-connect` 和 `direxio-mcp`；如需只写文件，
显式设置 `DIREXIO_AGENT_INSTALL=recommend` 或 `skip`。

## 本地 Bridge

S6 会在 `~/.direxio/nodes/<service_id>/` 下写入：

```text
credentials.json
env
direxio-connect/config.toml
direxio-connect/data/
direxio-connect/matrix-session.json
mcp/codex.toml
mcp/openclaw.md
mcp/openclaw-server.json
mcp/hermes.mcp.json
mcp/mcp-servers.json
```

手动安装：

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/direxio-connect direxio-connent@latest
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon status --service-name <service_id>
~/.direxio/nodes/<service_id>/direxio-connect/direxio-connect daemon logs --service-name <service_id> -n 120
```

默认 `DIREXIO_AGENT_INSTALL=auto` 时，S6 会等待 daemon 状态为 `Running`，并在最近日志中看到 `direxio-connect is running` 后才把本地 wiring 标记完成。日志中如果出现 Cursor Agent CLI 未安装、未登录/认证失败、workspace trust、ACP 启动失败或 agent offline 等错误，S6 会失败并保留 `connect_install_status=install_failed`，不会直接报告部署成功。

默认 `DIREXIO_AGENT_INSTALL=auto` 时，S6 会把 MCP 安装到当前 service 目录。生成的 MCP client 片段默认直接通过 stdio 启动该 service-scoped `direxio-mcp`。S6 还会尝试安装服务级 `direxio-mcp` daemon 作为可选 HTTP proxy 入口；如果 Windows 拒绝创建计划任务，stdio 片段仍然可用。手动恢复命令：

```bash
npm install --prefix ~/.direxio/nodes/<service_id>/mcp direxio-mcp@latest
DIREXIO_CREDENTIALS_FILE=~/.direxio/nodes/<service_id>/credentials.json ~/.direxio/nodes/<service_id>/mcp/direxio-mcp doctor --json
~/.direxio/nodes/<service_id>/mcp/direxio-mcp daemon install --service-name <service_id> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --host 127.0.0.1 --port 19757
~/.direxio/nodes/<service_id>/mcp/direxio-mcp daemon status --service-name <service_id> --json
```

S6 只会写当前检测到的 runtime 对应的 MCP 片段：Codex 写 `mcp/codex.toml`，Cursor 写 `mcp/cursor.mcp.json`，OpenClaw 写 `mcp/openclaw.md` 和 `mcp/openclaw-server.json`，Hermes 写 `mcp/hermes.mcp.json`，其他支持 MCP 的 agent runtime 写 `mcp/mcp-servers.json`。生成的 MCP client 片段会通过 stdio 直接运行当前 service 的 `direxio-mcp`，并设置 `DIREXIO_CREDENTIALS_FILE` 指向当前服务的 credentials，因此客户端不依赖 daemon 就能拉起 MCP 工具进程。Cursor 可读取项目级 `.cursor/mcp.json` 或全局 `~/.cursor/mcp.json`，但 S6 默认不写这两个位置，因为配置里包含本机 credentials 路径；添加片段后需要重启 Cursor，或在 Cursor MCP 设置里 reload/enable 该 server。OpenClaw 使用 `mcp/openclaw.md` 中生成的 `openclaw mcp set` 命令读取 `mcp/openclaw-server.json`；不要把 MCP JSON 直接粘贴到 `~/.openclaw/openclaw.json`。

语音输入在配置 STT provider key 后可用。设置 `DIREXIO_SPEECH_API_KEY` 或 `DIREXIO_SPEECH_QWEN_API_KEY` 等 provider 专用变量后，S6 会在 `direxio-connect/config.toml` 写入 `[speech] enabled = true`。

Homebrew 文档使用：

```bash
brew install direxio-connect
```

源码构建：

```bash
git clone https://github.com/YingSuiAI/direxio-connect.git
cd connect
make build AGENTS=<direxio-connect-agent> PLATFORMS_INCLUDE=matrix
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
