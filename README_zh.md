# Direxio Deployer

`direxio-deployer` 是用于部署生产 Direxio message server 的通用 Agent Skill，并通过 Direxio 专用 Matrix 桥接把本地 agent room 接到当前 agent。当前本地桥接只支持 `direxio-connect`，安装包是 `@direxio/connent`，源码仓库是 `YingSuiAI/connect`。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS/EC2/DNS/cloud-init/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、cc-connect wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## 部署原则

- 只部署到真实、长期域名。
- Matrix `server_name` 一旦绑定，后续换域名等同新 homeserver。
- AWS 资源会产生费用，部署前必须让用户明确确认。
- 用户侧 DNS 模式会在 Elastic IP 创建后暂停，等待用户更新 A 记录。
- 当前后端是 `direxio/message-server` 单体服务，Matrix 与 P2P API 共用 8008。
- cloud-init 会生成 `P2P_PORTAL_PASSWORD`；`init-tokens.sh` 会调用 `portal.bootstrap`，并在后端凭据文件没有真实房间时创建 Matrix agent room。
- 从服务端同步的 `password` 和 owner `access_token` 按一次性/易失凭据处理；登录或调接口前先重新拉取服务器 `/opt/p2p/bootstrap.json`，不要复用旧输出。
- S6 会拒绝 `!agent:<domain>` 这类旧伪房间，只接受 message-server 创建的真实 Matrix `agent_room_id`。
- S6 会通过 `agent.matrix_session.create` 创建 `@agent:<server>` Matrix session，写入 Matrix-only `cc-connect/config.toml`，并把 bridge 限制在当前 `agent_room_id`。
- `DIREXIO_CC_CONNECT_AGENT` 用来选择本地 `direxio-connect` agent 类型。支持值与 connent/connect 一致：`acp`、`antigravity`、`claudecode`、`codex`、`copilot`、`cursor`、`devin`、`gemini`、`iflow`、`kimi`、`opencode`、`pi`、`qoder`、`reasonix`、`tmux`。
- 当本地 agent 可执行文件不能从 PATH 找到时，设置 `DIREXIO_CC_CONNECT_AGENT_CMD` 或 `DIREXIO_<AGENT>_COMMAND`。Codex Desktop 在 Windows 下也可以继续使用 `DIREXIO_CODEX_COMMAND`。
- `DIREXIO_AGENT_INSTALL=auto` 会安装 `@direxio/connent` 并执行 `direxio-connect daemon install --config <config> --force`。默认 `recommend` 只记录并打印命令。

## 最小命令

在仓库根目录运行：

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
如果 `DIREXIO_AGENT_PLATFORM=auto` 无法唯一识别当前运行时，显式设置 `DIREXIO_CC_CONNECT_AGENT`。

查看状态：

```bash
bash scripts/orchestrate.sh status
DOMAIN=<domain> bash scripts/orchestrate.sh status
```

销毁已记录资源：

```bash
DOMAIN=<domain> bash scripts/destroy.sh
```

销毁时只会在 `direxio-connect daemon status` 返回的 `WorkDir` 等于当前服务的
`~/.direxio/nodes/<service_id>/cc-connect` 目录时停止本地 daemon，然后删除该
service 目录。

## 本地 Bridge

S6 会在 `~/.direxio/nodes/<service_id>/` 下写入：

```text
credentials.json
env
cc-connect/config.toml
cc-connect/data/
cc-connect/matrix-session.json
```

手动安装：

```bash
npm install -g @direxio/connent
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --force
direxio-connect daemon status
```

语音输入在配置 STT provider key 后可用。设置 `DIREXIO_SPEECH_API_KEY` 或 `DIREXIO_SPEECH_QWEN_API_KEY` 等 provider 专用变量后，S6 会在 `cc-connect/config.toml` 写入 `[speech] enabled = true`。

Homebrew 文档使用：

```bash
brew install direxio-connect
```

源码构建：

```bash
git clone https://github.com/YingSuiAI/connect.git
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
