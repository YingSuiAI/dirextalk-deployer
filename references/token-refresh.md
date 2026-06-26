# Token Refresh

每次重部署或清空数据卷后，`password`、owner `access_token`、`agent_token` 和 cc-connect Matrix session 都会变化。状态机 S6 会自动回填；手动恢复时按这里检查。

从服务端同步过来的 `password` 和 owner `access_token` 必须按一次性/易失凭据处理。用户登录成功后，服务端可能立刻重置这些值；任何需要再次获取登录密码，或需要用 `access_token` 调 `/_p2p/command`、Matrix Client API 等接口的操作，都必须先重新从服务器拉取最新 `/opt/p2p/bootstrap.json`，再更新本地 `credentials.json`。不要复用聊天记录、旧 `state.json`、旧 `credentials.json` 或历史部署输出里的 password/access token。

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
  "password": "<LOGIN_PASSWORD>",
  "agent_room_id": "__ROOM_ID__"
}
```

取回:

```bash
ssh -i <key.pem> ubuntu@<ip> 'sudo cat /opt/p2p/bootstrap.json' > bootstrap.json
```

如果刚执行过前端登录、`portal.auth`、手动接口调用、S5/S6 重跑，或者不确定本地凭据是否最新，先执行上面的取回命令，再读取 `password` 或 `access_token`。

## 本地服务凭据

`~/.direxio/nodes/<service_id>/credentials.json`:

```json
{
  "profiles": {
    "default": {
      "password": "<LOGIN_PASSWORD>",
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
~/.direxio/nodes/<service_id>/cc-connect/matrix-session.json
~/.direxio/nodes/<service_id>/cc-connect/config.toml
```

刷新后重新安装或重启本地 bridge：

```bash
direxio-connect daemon install --config ~/.direxio/nodes/<service_id>/cc-connect/config.toml --force
direxio-connect daemon status
```

## 验证

```bash
curl -skf https://<domain>/healthz && echo OK
curl -sk https://<domain>/.well-known/portal/owner.json
curl -sk https://<domain>/_matrix/client/versions
```
