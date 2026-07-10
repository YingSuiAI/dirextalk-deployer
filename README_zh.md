# Dirextalk Deployer

`dirextalk-deployer` 是用于部署生产 Dirextalk message server 的通用 Agent Skill，并通过 Dirextalk 专用 Matrix 桥接把本地 agent room 接到当前 agent。当前本地桥接只支持 `dirextalk-connect`，安装包是 `dirextalk-connect`，源码仓库是 `YingSuiAI/dirextalk-connect`。MCP capability 与 bridge agent 支持分开声明；S6 写入 canonical 远端 HTTP MCP 描述，不会假设每个 bridge agent 都能消费 MCP。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS Lightsail/EC2/DNS/user-data/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、dirextalk-connect wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## 部署前准备

- 准备 AWS 账号、AWS access key CSV 或 profile，以及真实长期域名或子域名。当前 AWS 账号存在匹配的公共 Route53 Hosted Zone 时，deployer 会自动使用 Route53；否则会在取得固定公网 IP 后才提示添加外部 DNS A 记录。
- deployer 创建的 AWS 资源在销毁前可能持续计费。新部署默认优先使用 Lightsail 12 美元/月 Linux 套餐。未使用过 Lightsail 的用户一般会有三个月免费额度；新用户注册 AWS 一般有 100-200 美元的免费额度。一切以 AWS 官方实时政策为准。如果没有配置 region，deployer 会根据本机时区推荐默认 AWS region，并且非交互式运行也会使用该推荐；可用 `AWS_DEFAULT_REGION`、`AWS_REGION`、AWS profile region 或 `DIREXTALK_DEFAULT_REGION` 覆盖。S1 会在确认前查询 Lightsail 套餐和可用区；如果要手工查可用区，使用 `aws lightsail get-regions --include-availability-zones --output json`，裸 `get-regions` 可能不返回可用区明细。如果所选 region 没有可用 Lightsail 资源，S1 不会自动切换到 EC2；它会记录 EC2 费用估算，并等待操作者选择其他 Lightsail 可用 region/zone，或显式设置 `DIREXTALK_CLOUD_PROVIDER=ec2`。新建 EC2 默认使用 50 GiB gp3 root EBS 卷。
- `SKILL.md` 是给智能体看的运行手册，详细部署规则、确认门禁、运行时 wiring 和恢复流程都放在那里。

## Skill 安装和更新

通过 npm 安装 deployer skill，再把它写入当前智能体运行时的 skill 目录。默认安装到所选智能体运行时的全局 skill 目录；只有在明确希望跟随某个仓库或 workspace 时，才指定 project-local 安装。

GitHub 仓库保留测试用于维护和 CI，但发布到 npm 的包以及安装到智能体 skill 目录的副本不包含 `tests/`，以减小用户安装体积。

普通用户场景下，GitHub 仓库只是文档和源码位置，不是 skill 安装路径。不要为了安装或使用 skill 去 clone `YingSuiAI/dirextalk-deployer`。只有在开发 deployer、本地打 patch，或明确要求 project-local 安装时，才 clone 这个仓库。

如果你想让 Codex 一句话安装并开始部署，不要说“安装 skills <GitHub 链接>”或“把这个 GitHub 仓库安装成 skill”。那可能触发 GitHub skill 安装器、仓库 clone 或 project-local copy，而不是 npm 管理的安装器。推荐只说短句，把仓库地址作为读取 README 的位置，并让 agent 按 README 中的 npm 安装规则执行：

```text
请阅读 https://github.com/YingSuiAI/dirextalk-deployer 的 README，并按其中 npm 安装规则安装 skill，然后部署 Dirextalk，域名 __DOMAIN__。
```

Agent 读到这句后应执行下方 npm 安装命令；不要改用 GitHub skill installer。

如果 Codex 已经能在可用 skills 中看到 `dirextalk-deployer`，直接要求它使用已安装的 skill。如果看不到，先安装或刷新：

POSIX shell：

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
```

Windows PowerShell：

```powershell
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill install --agent codex
```

在同一个宿主运行时中更新已安装 skill：

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill update --agent codex
```

根据当前运行时替换 agent 名称：`codex`、`claudecode`、`gemini`、`cursor`、`copilot`、`openclaw`、`hermes`、`opencode`、`qoder`、`reasonix`，或使用 `references/agent-targets.md` 中列出的其他目标。只有明确想安装到某个项目目录时才使用 `--scope project --project <path>`：

```bash
dirextalk-deployer skill install --agent codex --scope project --project .
```

安装器会在目标目录写入 `.dirextalk-skill-install.json`，并拒绝覆盖没有该 manifest 的既有目录，除非显式传入 `--force`。普通安装和更新使用 `@latest`：

```bash
npm install -g dirextalk-deployer@latest
dirextalk-deployer skill update --agent codex
```

这个 CLI 由 Node 实现，并使用当前宿主的原生路径。Windows 下写入 Windows 路径；Linux、macOS、Git Bash 或 WSL 下写入对应运行时能读取的路径。

## 最小命令

导入凭据前，先确认：

- **是否已经有 AWS 账号？** 如果没有，先在 AWS 注册账号，完成邮箱/手机验证、绑定支付方式、选择 Basic support plan，等待账号激活，然后创建 AWS Budget 或账单告警。
- **是否已经有可控域名或子域名？** 如果没有，先注册或准备域名。不要询问 DNS 在哪里管理：deployer 会自动查询当前 AWS 账号中匹配的公共 Route53 Hosted Zone；查不到时继续按外部 DNS 部署，并在固定公网 IP 创建后提示需要添加的 A 记录。

从 AWS CSV 导入并验证一个部署 profile。root access key 是首次部署最快路径，
但权限极高；请安全保存 CSV，部署后轮换或删除密钥。临时
`DirextalkDeployer` IAM 用户更安全，但 AWS 控制台步骤更多：

```bash
bash scripts/aws-credentials.sh import-csv /path/to/accessKeys.csv dirextalk-deployer us-east-1
export AWS_PROFILE=dirextalk-deployer
bash scripts/aws-credentials.sh verify dirextalk-deployer
```

在仓库根目录运行：

```bash
bash scripts/pricing-estimate.sh \
  --region us-east-1 \
  --cloud-provider lightsail \
  --domain-mode route53
```

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=__DOMAIN__ \
CONFIRM_DOMAIN_BINDING=1 \
bash scripts/orchestrate.sh
```

正常部署会解析最新已发布的稳定 GitHub Release，校验 manifest checksum，并把不可变的
version、镜像 digest、image reference 和 manifest digest 写入 `state.json`。宿主 updater
由独立的 [`dirextalk-updater`](https://github.com/YingSuiAI/dirextalk-updater) Release 提供：
Ubuntu 24.04 x86_64 宿主直接下载 deployer 固定的 `v1.0.0` 资产，使用 deployer 内固定的
SHA-256 校验后原子安装。本机不需要 Go，S3 也不会再通过 SSH 复制 updater 二进制。
deployer 的 Node selector 使用固定版本的成熟 `semver` 包严格解析每条 `upgrade_from`，
并拒绝包含目标版本的约束；接受/拒绝语料覆盖 canonical Go validator 使用的约束形式。
跨版本兼容性证据仍以独立 updater 和 message-server Release CI 为权威。

`DIREXTALK_CLOUD_PROVIDER=lightsail` 可省略，因为 Lightsail 是默认选择。如需保留的 EC2 部署路径，添加 `DIREXTALK_CLOUD_PROVIDER=ec2`。EC2 可继续设置 `INSTANCE_TYPE=t3.small` 或更大的显式规格，并默认使用 50 GiB gp3 root EBS 卷。如果默认 Lightsail 在当前 region 没有可用套餐或可用区，S1 会记录 EC2 费用估算，但不会自动切换到 EC2；请选择其他 Lightsail 可用 region/zone，或显式用 `DIREXTALK_CLOUD_PROVIDER=ec2` 重新运行。如果未配置 region，非交互式运行会使用本机时区推荐；可用 `DIREXTALK_DEFAULT_REGION` 或标准 AWS region 设置覆盖。除非在排查 AWS 返回值，否则让 S1 自动检测 Lightsail 可用性；安全的手工命令是 `aws lightsail get-regions --include-availability-zones --output json`。

Windows 用户使用 PowerShell 入口。它会选择 Git Bash 执行云端 phase，同时给本地 `dirextalk-connect` 写入 Windows 可直接使用的路径：

```powershell
$env:AWS_DEFAULT_REGION = "us-east-1"
$env:DOMAIN = "__DOMAIN__"
$env:CONFIRM_DOMAIN_BINDING = "1"
$env:DIREXTALK_CLOUD_PROVIDER = "lightsail"
.\scripts\orchestrate.ps1
```

仅写入并推荐本地 bridge 和 MCP：

```bash
DIREXTALK_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

默认会自动安装本地 bridge 和 MCP。只有自动检测不明确时才需要显式设置 runtime：

```bash
DIREXTALK_AGENT_PLATFORM=auto \
DIREXTALK_CONNECT_AGENT=claudecode \
DIREXTALK_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

可选安装模式：`recommended`、`dirextalk-connect`。
如果 `DIREXTALK_AGENT_PLATFORM=auto` 无法唯一识别当前运行时，显式设置 `DIREXTALK_CONNECT_AGENT`。S6 会为生成的 agent options 默认写入 `mode = "yolo"`；如果 `DIREXTALK_CONNECT_AGENT_OPTIONS_TOML` 或 `DIREXTALK_CURSOR_MODE` 显式提供 `mode`，仍以显式值为准。Windows 上的 Cursor 接线使用 `%LOCALAPPDATA%\cursor-agent\agent.cmd`；OpenCode 会优先查找 PATH 中的 `opencode` 和 npm 全局 `opencode-ai` 包，也可用 `DIREXTALK_OPENCODE_COMMAND` 显式指定。若 `agent.cmd status` 显示未登录，先交互执行一次 `agent.cmd login`，然后重新运行 deployer。运行中的 OpenClaw/Hermes 宿主即使启动 Codex 等 child，MCP 所有权仍属于宿主；只有显式 `DIREXTALK_AGENT_PLATFORM=<child>` 才绕过自动宿主检测。OpenClaw Gateway ACP 默认写入 `["acp", "--session", "agent:main:main"]` 并自动发现 Gateway；显式连接必须同时提供 URL、token file 和 session。脚本拒绝完整替换 OpenClaw args 或用通用命令覆盖宿主 bridge。Hermes 可用 `DIREXTALK_HERMES_ACP_ARGS_TOML` 添加 child 参数，但固定保留 adapter/profile 前缀。

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

销毁时只会在 `dirextalk-connect daemon status --service-name <service_id>` 返回的 `WorkDir` 等于当前服务的
`~/.dirextalk/nodes/<service_id>/dirextalk-connect` 目录时停止并卸载本地 daemon，然后删除该
service 目录。

更新现有节点但不删除数据：

```bash
DIREXTALK_ALLOW_MESSAGE_SERVER_IMAGE_OVERRIDE=1 \
DOMAIN=<domain> MESSAGE_SERVER_IMAGE=dirextalk/message-server:<debug-tag> bash scripts/update.sh
```

这是显式 debug/legacy override，不是正常生产升级路径。镜像刷新只重启远端服务，不重置本地 credentials、`dirextalk-connect`、MCP
配置、用户确认和 runtime checks。

重置应用数据但保留 EC2、DNS、固定 IP 和 Caddy TLS：

```bash
DIREXTALK_RESET_APP_DATA_CONFIRM=1 DOMAIN=<domain> bash scripts/reset-app-data.sh
DIREXTALK_EXISTING_STATE_ACTION=continue DOMAIN=<domain> bash scripts/orchestrate.sh
```

清理应用数据卷后，后续 orchestrate 会重新生成本地 credentials/MCP 配置，
并默认自动重新安装/重启 `dirextalk-connect`；如需只写文件，
显式设置 `DIREXTALK_AGENT_INSTALL=recommend` 或 `skip`。MCP 使用服务端 HTTP endpoint，
不再安装本地 MCP CLI。

## 本地 Bridge

S6 会在 `~/.dirextalk/nodes/<service_id>/` 下写入：

```text
credentials.json
dirextalk-connect/config.toml
dirextalk-connect/data/
dirextalk-connect/matrix-session.json
mcp/README.md
mcp/openclaw.md
mcp/hermes.md
```

POSIX Bash 手动安装：

```bash
npm install --prefix ~/.dirextalk/nodes/<service_id>/dirextalk-connect dirextalk-connect@latest
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon install --config ~/.dirextalk/nodes/<service_id>/dirextalk-connect/config.toml --service-name <service_id> --force
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon status --service-name <service_id>
~/.dirextalk/nodes/<service_id>/dirextalk-connect/dirextalk-connect daemon logs --service-name <service_id> -n 120
```

Windows PowerShell 手动安装：

```powershell
$serviceDir = Join-Path $env:USERPROFILE '.dirextalk\nodes\<service_id>'
$runtimeDir = Join-Path $serviceDir 'dirextalk-connect'
$connect = Join-Path $runtimeDir 'dirextalk-connect.cmd'
npm install --prefix $runtimeDir dirextalk-connect@latest
& $connect daemon install --config (Join-Path $runtimeDir 'config.toml') --service-name '<service_id>' --force
& $connect daemon status --service-name '<service_id>'
& $connect daemon logs --service-name '<service_id>' -n 120
```

默认 `DIREXTALK_AGENT_INSTALL=auto` 时，S6 会等待 daemon 状态为 `Running`，并在最近日志中看到 `dirextalk-connect is running` 后才把本地 wiring 标记完成。日志中如果出现 Cursor Agent CLI 未安装、未登录/认证失败、workspace trust、ACP 启动失败或 agent offline 等错误，S6 会失败并保留 `connect_install_status=install_failed`，不会直接报告部署成功。

默认 `DIREXTALK_AGENT_INSTALL=auto` 时，S6 不安装本地 MCP CLI。canonical 配置直接连接 `https://<domain>/mcp` 并使用当前服务的 agent token；不需要本地 MCP daemon、proxy 或监听端口。S6 会记录 `session`、`project`、`host-managed`、`conditional` 或 `unsupported`，未声明的 runtime fail-closed。

capability registry 与 dirextalk-connect 对齐，并通常按实际选中的 connect agent 判定 capability；检测到 OpenClaw 或 Hermes 宿主时始终为 `host-managed`，且只允许 ACP bridge，非 ACP override 会失败关闭。MCP 分别归其原生 registry，connect 只负责会话桥接。ACP、Claude Code、Codex、Copilot、Gemini、Kimi、OpenCode、Qoder 为 `session`；Antigravity、Cursor、iFlow 为 `host-managed`；Devin、Pi、Reasonix、tmux 为 `unsupported`。`unsupported` 和未知选择都会失败关闭；协议词汇仍保留 `project` 与 `conditional`，但当前没有 backend 使用。S6 不生成 generic JSON fallback。

host-managed 选择仍保留说明 artifact，但不会把 canonical MCP URL/token 字段写入 `dirextalk-connect/config.toml`。在 `auto` 模式下，S6 会在启动 bridge 前等待操作者完成宿主 enrollment，并以 `DIREXTALK_MCP_HOST_READY=1` 重跑。OpenClaw 必须通过不带秘密 argv 的 `openclaw mcp probe <server-name> --json`；Hermes 使用每节点独立 HERMES_HOME/profile，并在同一 scope 通过 `hermes -p <profile> mcp test <server-name>`。其他没有官方 probe 的 host-managed backend 明确记录为 operator-confirmed，并仍需后续 runtime verification。S6 从不自动修改宿主 registry，也不把 token 放入进程 argv。

语音输入在配置 STT provider key 后可用。设置 `DIREXTALK_SPEECH_API_KEY` 或 `DIREXTALK_SPEECH_QWEN_API_KEY` 等 provider 专用变量后，S6 会在 `dirextalk-connect/config.toml` 写入 `[speech] enabled = true`。

Homebrew 文档使用：

```bash
brew install dirextalk-connect
```

源码构建：

```bash
git clone https://github.com/YingSuiAI/dirextalk-connect.git
cd connect
make build AGENTS=<dirextalk-connect-agent> PLATFORMS_INCLUDE=matrix
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
