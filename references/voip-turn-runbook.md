# VoIP / TURN relay 运维契约

Dirextalk production split 栈自建 coturn，使用 shared-secret 动态签发短期凭据。
当前只提供 `turn:3478` 的 UDP/TCP，不提供 `turns:5349`；UDP relay
范围固定为 `49160-49200`。TURN 直连宿主网络，不经 Caddy。

## 生产实现

- canonical 应用 Compose 位于
  `deploy/split-agent/compose.yaml`。`coturn` 使用 host network 和 immutable
  image digest，只从 Compose secret 读取受保护的 `turnserver.conf`。
- `bootstrap-production.sh` 从 updater 记录的 stable public IPv4 receipt
  注入 `DIREXTALK_TURN_EXTERNAL_IP`，然后由 canonical
  `provision-local.sh` 生成 mode-0400 的 `turnserver.conf` 和
  `turn-shared-secret`。密钥不进入 Compose 插值、环境变量或 argv。
- canonical `initialize-message-server.sh` 从同一 secret file 读取密钥，
  将 24 小时 lifetime、UDP/TCP TURN URI 和 shared secret 写入受保护的
  message-server 配置。
- AWS 入站规则放行 `3478/tcp`、`3478/udp` 和
  `49160-49200/udp`。Caddy edge Compose 不定义 TURN 路由。

## 验收

基础部署验收由 S7 调用
`/_matrix/client/v3/voip/turnServer`，要求返回非空 `turn:` URI、username、
password 和正 ttl。这只证明凭据契约有效。

VoIP 专项验收仍需 Alice/Bob 真机互拨，并在 WebRTC internals 中确认
`relay` ICE candidate。只有 host/srflx candidate 或通话一直“正在连接”，
不能算通过。

## 故障排查

1. 确认 S7 的 `turnServer` 结果。返回空对象通常表示
   message-server TURN 配置未生效；返回凭据但 relay 失败，优先检查
   coturn、stable public IP 和 AWS 入站规则。
2. 使用受保护的 canonical split 项目查看状态：
   ```bash
   sudo docker compose \
     --env-file /var/dirextalk-message-server/split/.env \
     -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml \
     ps coturn message-server
   sudo docker compose \
     --env-file /var/dirextalk-message-server/split/.env \
     -f /var/dirextalk-message-server/deploy/split-agent/compose.yaml \
     logs --tail=120 coturn message-server
   ```
3. 核对安全组的 `3478` tcp+udp 和 `49160-49200/udp`，以及
   `/var/dirextalk-message-server/stable-public-ip` 是否与当前固定公网 IP
   一致。不要输出 `turn-shared-secret` 或完整 TURN 凭据。
4. 如需修复，使用 root-owned `production-ops/reconcile-production.sh`
   和正常 orchestrator resume 路径。不直接编辑受保护的 split
   Compose、edge Compose/Caddy 或密钥文件。
