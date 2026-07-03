# Troubleshooting

## dirextalk-connect Bridge

- `agent_room_id` must be a real Matrix room id beginning with `!`. Values like `!agent:<domain>` are legacy pseudo ids and must be fixed by redeploying or restarting a current message-server build.
- Current message-server images require `P2P_PORTAL_PASSWORD` and an explicit `portal.bootstrap` call. The cloud `init-tokens.sh` script is responsible for that call and for creating a real Matrix agent room when the backend credentials file does not already include `agent_room_id`.
- `agent.matrix_session.create` must return `@agent:<server>`. If it returns `@owner:<server>`, deploy a message-server build that includes agent Matrix session support.
- `dirextalk-connect/config.toml` must contain one Matrix platform and the same `room_id` as S5/S6 state.
- `dirextalk-connect daemon status --service-name <service_id>` checks the local bridge process for the current Dirextalk node. If no daemon is installed, run the command printed in S6 state `connect_install_command`.
- In `DIREXTALK_AGENT_INSTALL=auto`, S6 also reads `dirextalk-connect daemon logs --service-name <service_id> -n 120`. It waits for `dirextalk-connect is running` and fails on Agent startup errors such as missing Cursor Agent CLI, login/auth/trust failures, ACP session initialization failure, or agent offline state. Fix the local agent runtime, then rerun orchestrate to reinstall/restart and verify the daemon before reporting deployment success.
- If npm install fails, verify `npm view dirextalk-connect` and that the GitHub release contains the matching `dirextalk-connect` binary asset.

## Matrix Checks

The deployed homeserver should answer:

```bash
curl -k https://<domain>/_matrix/client/versions
```

The local bridge should use the Matrix session file at:

```text
~/.dirextalk/nodes/<service_id>/dirextalk-connect/matrix-session.json
```

Do not hand-edit the access token unless S6 cannot create a session; rerun S6 after refreshing server credentials.
