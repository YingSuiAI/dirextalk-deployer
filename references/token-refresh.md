# Token Refresh

每次重部署或清空数据卷后，`password`、owner `access_token`、`agent_token` 和 direxio-connect Matrix session 都会变化。状态机 S6 会自动回填；手动恢复时按这里检查。

从服务端同步过来的 `password` 和 owner `access_token` 必须按一次性/易失凭据处理。`password` 是后端字段名，对用户展示时必须叫八位 App 初始化码。用户完成初始化或 token exchange 后，服务端可能立刻重置这些值；任何需要再次获取初始化码，或需要用 `access_token` 调 owner 身份 API/Matrix Client API，或需要用 `agent_token` 调 `agent.matrix_session.create` 的操作，都必须先重新从服务器拉取最新 `/opt/p2p/bootstrap.json`，再更新本地 `credentials.json`。不要复用聊天记录、旧 `state.json`、旧 `credentials.json` 或历史部署输出里的 password/access token。

现有节点执行 `scripts/update.sh` 只做镜像刷新和远端服务重启，不清理应用卷，也不重置本地 `password`、`access_token`、`agent_token`、`agent_room_id`、`user_confirmations`、`runtime_checks`、direxio-connect daemon 状态或 MCP artifacts。除非验证发现远端确实重新生成了 bootstrap credentials，否则 update 后不要强制续跑 S4-S7。

执行 `scripts/reset-app-data.sh`、清理应用挂载卷或重新部署服务后，本地旧证据必须作废。脚本会清掉旧 `password`、`access_token`、`agent_token`、`agent_room_id`、`user_confirmations` 和 `runtime_checks`，把 `agent_install_status` 和 `mcp_install_status` 标成 `refresh_pending`，并只在 `WorkDir` 匹配当前 service 时停止对应的本地 bridge（stops only the matching service-scoped direxio-connect daemon），再把 S4-S7 标回 pending。这样旧的用户确认、MCP discovery、Agent runtime probe、旧 bridge 安装状态或 MCP 安装状态不会被误用到重置后的节点。后续必须续跑 `scripts/orchestrate.sh`，让 S5/S6/S7 重新生成本地 credentials/MCP snippets，并默认自动重新安装/重启 direxio-connect 和 direxio-mcp，再通过 `verify runtime` 写入当前证据。

## 远端凭据

EC2 机器内 `/opt/p2p/bootstrap.json`:

```json
{
  "version": 1,
  "owner_user_id": "__OWNER_USER_ID__",
  "user_id": "__OWNER_USER_ID__",
  "homeserver": "https://__DOMAIN__",
  "access_token": "<ACCESS_TOKEN>",
  "agent_token": "<AGENT_TOKEN>",
  "password": "<APP_INITIALIZATION_CODE>",
  "agent_room_id": "__ROOM_ID__"
}
```

取回:

```bash
ssh -i <key.pem> ubuntu@<ip> 'sudo cat /opt/p2p/bootstrap.json' > bootstrap.json
```

如果刚执行过 App 初始化、`portal.auth`、手动接口调用、S5/S6 重跑，或者不确定本地凭据是否最新，先执行上面的取回命令，再读取 `password` 字段对应的八位初始化码或 `access_token`。

## 本地服务凭据

`~/.direxio/nodes/<service_id>/credentials.json`:

```json
{
  "profiles": {
    "default": {
      "password": "<APP_INITIALIZATION_CODE>",
      "access_token": "<ACCESS_TOKEN>",
      "agent_room_id": "__ROOM_ID__",
      "direxio_domain": "https://__DOMAIN__",
      "direxio_agent_token": "<AGENT_TOKEN>",
      "direxio_agent_room_id": "__ROOM_ID__",
      "direxio_agent_node_id": "<agent_node_id>"
    }
  }
}
```

权限必须是 `0600`:

```bash
chmod 600 ~/.direxio/nodes/<service_id>/credentials.json
```

S6 也会写：

```text
~/.direxio/nodes/<service_id>/env
~/.direxio/nodes/<service_id>/direxio-connect/matrix-session.json
~/.direxio/nodes/<service_id>/direxio-connect/config.toml
```

刷新后重新安装或重启本地 bridge：

```bash
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/direxio-connect/config.toml --service-name <service_id> --force
direxio-connect daemon status --service-name <service_id>
```

## 验证

```bash
curl -skf https://<domain>/healthz && echo OK
curl -sk https://<domain>/.well-known/portal/owner.json
curl -sk https://<domain>/_matrix/client/versions
```
