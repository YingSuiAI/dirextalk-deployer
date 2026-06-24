# Direxio Deployer

`direxio-deployer` 是一个用于部署 Direxio message server 的通用 Agent Skill。Claude Code、Codex/OpenAI、Gemini、Cursor、GitHub Copilot、OpenClaw、Hermes 或其他能读取 `SKILL.md` 并执行 shell 命令的智能体，都可以按同一套流程部署、续跑、验收和销毁服务。

它把部署问诊、跨平台工具准备、AWS 基础设施编排、DNS 等待、新版 message-server 初始化、密码交付、本地凭据写入、Direxio MCP/plugin 环境回填、runtime-specific 目标记录和最终验收合并为一个根目录内自包含的 skill。

## 内容

- `SKILL.md`: 智能体主入口、确认规则、部署/销毁流程和交付格式。
- `scripts/`: 状态机、AWS/EC2/DNS/cloud-init/验证/销毁脚本。
- `references/`: 工具准备、部署续跑、agent 目标目录、运行时 wiring、状态机、架构、排障和恢复说明。
- `agents/`: 面向不同智能体运行时的展示元数据和识别说明。

## Skill 安装位置

在已有项目或 workspace 中安装本 skill 时，优先按当前智能体运行时 clone 到项目内目录，例如 Codex 使用 `PROJECT_ROOT/.codex/skills/direxio-deployer`，Claude Code 使用 `PROJECT_ROOT/.claude/skills/direxio-deployer`，Cursor 使用 `PROJECT_ROOT/.cursor/skills/direxio-deployer`。不要用复制式安装替代项目内安装，因为复制会丢掉 `.git`，后续无法 `git pull`、查看 commit 或追踪本地补丁。

完整运行时目录、全局 fallback 和 MCP/plugin 配置目标见 `references/agent-targets.md`。只有没有项目目标，或用户明确要求全局安装时，才使用各运行时的全局 skills 目录。

## 部署原则

- 只部署到真实、长期域名。
- Matrix `server_name` 一旦绑定，后续换域名等同新 homeserver。
- AWS 资源会产生费用，部署前必须让用户明确确认。
- 用户侧 DNS 模式会在 Elastic IP 创建后暂停，等待用户更新 A 记录。
- 当前后端是 `direxio/message-server` 单体服务，Matrix 与 P2P API 共用 8008。
- 当前后端使用 `password` 作为 IM 登录信息；本地凭据保留统一的 `access_token` 和 agent 专用的 `agent_token`。
- 多节点公开频道互通由客户端请求参数携带目标节点 `_p2p` 基地址，部署器不再写入固定远端节点表。
- 部署完成后会按服务域名持久化当前 MCP 和插件所需的 `DIREXIO_DOMAIN`、`DIREXIO_AGENT_TOKEN`、`DIREXIO_AGENT_ROOM_ID`、`DIREXIO_AGENT_NODE_ID` 到 `~/.direxio/nodes/<service_id>/`，并记录 `@direxio/local-mcp`、`@direxio/agent-plugins`、runtime-specific skill clone 目录和按节点隔离的 MCP/config payload 目标。
- 部署器支持部署后 agent 安装策略：`DIREXIO_AGENT_INSTALL=skip|recommend|auto`，默认 `recommend`。只有 `auto` 会尝试执行 `npx -y -p @direxio/agent-plugins@latest direxio-agent-install --node-id <agent_node_id> --credentials-file ~/.direxio/nodes/<service_id>/credentials.json --write`。gateway 模式只会重启同一节点的 gateway，不影响其他本地节点。
- gateway 原生内置 `mcp.messages.send` 发送能力，会直接调用 `/_p2p/command`，不依赖 `@direxio/local-mcp`。

## 最小命令

在仓库根目录运行：

```bash
AWS_DEFAULT_REGION=us-east-1 \
DOMAIN=im.example.com \
DOMAIN_MODE=user \
CONFIRM_DOMAIN_BINDING=1 \
INSTANCE_TYPE=t3.small \
MESSAGE_SERVER_IMAGE=direxio/message-server:latest \
bash scripts/orchestrate.sh
```

部署后一条龙推荐模式：

```bash
DIREXIO_AGENT_INSTALL=recommend bash scripts/orchestrate.sh
```

部署后自动安装/写入当前 agent 配置：

```bash
DIREXIO_AGENT_INSTALL=auto \
DIREXIO_AGENT_PLATFORM=auto \
DIREXIO_AGENT_INSTALL_MODE=recommended \
bash scripts/orchestrate.sh
```

可选平台：`auto`、`codex`、`claude-code`、`gemini`、`cursor`、`copilot`、`openclaw`、`hermes`、`generic`。

可选安装模式：`recommended`、`mcp`、`native`、`gateway`。OpenClaw 和 Hermes 的 recommended 模式是 `native`；Codex 是 `gateway`；不支持本地长进程的平台是 `mcp`。

查看状态：

```bash
bash scripts/orchestrate.sh status
```

销毁已记录资源：

```bash
bash scripts/destroy.sh
```

## Agent 识别

智能体应优先读取 `SKILL.md`。当用户提出部署、续跑、排障、验证、销毁、回填 agent 凭据或安装 Direxio MCP/plugin 时，应使用本 skill。

部署后 S6 会检测当前运行时，例如 Codex、Claude Code、Gemini、Cursor、GitHub Copilot、OpenClaw 或 Hermes。S7 通过后，执行 agent 必须询问用户是否要为检测到的运行时自动安装/配置 Direxio 插件和 MCP 服务；只有用户明确同意后才修改当前智能体配置。

非交互部署可用 `DIREXIO_AGENT_INSTALL=auto` 显式授权自动安装。OpenClaw/Hermes 这类支持长进程的平台优先使用原生插件/配置；Claude Code、Cursor、Gemini、Copilot 等不托管本地长进程的平台使用 MCP-only 或外置 gateway。

S6 会在 `state.json` 里记录 `agent_skill_install_path`、`agent_global_skill_install_path`、`agent_mcp_config_path` 和 `agent_install_target_summary`，执行 agent 应按这些字段和 `references/agent-targets.md` 操作，不要默认使用 Codex 目录。

部署后可直接用 gateway 原生发送测试消息：

```bash
source ~/.direxio/nodes/<service_id>/env
npx -y -p @direxio/agent-plugins@latest direxio-agent-gateway send --room "$DIREXIO_AGENT_ROOM_ID" --message "hello"
```

## 验证

```bash
bash tests/skill_structure_test.sh
bash tests/s6_wire_local_test.sh
bash tests/render_userdata_remote_nodes_test.sh
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
git diff --check
```
