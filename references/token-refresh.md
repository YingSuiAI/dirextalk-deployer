# token 回填

每次重部署或清空数据卷后，`password` 和 token 都会变化。状态机 S6 会自动回填；手动恢复时按这里检查。

## 远端凭据

EC2 机器内 `/opt/p2p/bootstrap.json`:

```json
{
  "version": 1,
  "owner_user_id": "@owner:im.example.com",
  "user_id": "@owner:im.example.com",
  "homeserver": "https://im.example.com",
  "access_token": "<ACCESS_TOKEN>",
  "agent_token": "<AGENT_TOKEN>",
  "password": "<LOGIN_PASSWORD>",
  "agent_room_id": "!agent:im.example.com"
}
```

取回:

```bash
ssh -i <key.pem> ubuntu@<ip> 'sudo cat /opt/p2p/bootstrap.json' > bootstrap.json
```

## 本地服务凭据

`~/.direxio/nodes/<service_id>/credentials.json`:

```json
{
  "profiles": {
    "default": {
      "password": "<LOGIN_PASSWORD>",
      "access_token": "<ACCESS_TOKEN>",
      "agent_room_id": "!agent:im.example.com",
      "direxio_domain": "https://im.example.com",
      "direxio_agent_token": "<AGENT_TOKEN>",
      "direxio_agent_room_id": "!agent:im.example.com",
      "direxio_agent_node_id": "<agent_node_id>"
    }
  }
}
```

权限必须是 `0600`:

```bash
chmod 600 ~/.direxio/nodes/<service_id>/credentials.json
```

S6 也会写 `~/.direxio/nodes/<service_id>/env`，当前 MCP/plugin 变量为 `DIREXIO_DOMAIN`、`DIREXIO_AGENT_TOKEN`、`DIREXIO_AGENT_ROOM_ID` 和 `DIREXIO_AGENT_NODE_ID`。

## 验证

```bash
curl -skf https://<domain>/healthz && echo OK
curl -sk https://<domain>/.well-known/portal/owner.json
curl -sk -X POST https://<domain>/_p2p/query \
  -H "Authorization: Bearer <AGENT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"action":"apis.list","params":{}}'
```
