# VoIP / TURN relay 部署方案(已落地)

> 来源:飞书《20260603 - VoIP 通话连接缺口》。**已按决策实现**:方案 A 自建 coturn、第一版仅明文 `turn:3478`(udp+tcp,不上 TLS)、UDP relay 收窄 `49160-49200`。代码见 PR `feat/voip-turn-coturn`。
> ⚠️ VoIP 专项验收的硬标准:真机互拨一通,WebRTC internals 看到 **relay** ICE candidate(S7 的 turnServer 非空只是必要条件)。基础部署验收只要求 S7 `turnServer` 自动检测通过,不要求用户每次真实打电话。
>
> 缺口结论:Matrix 通话信令(`m.call.*`)已互通,但 `/_matrix/client/v3/voip/turnServer` 返回 `{}`,
> ICE 只有 host/srflx 没有 relay → 跨 NAT/防火墙通话必失败。**纯后端缺口,非前端。**
> 责任方:**只有 ops 部署 skill**(agent / AS / client 都不涉及 TURN)。

---

## 一、TURN 方案决策(已采用 A)

### 方案 A:VPS 上自建 coturn(已落地)
compose 加一个 `coturn` 容器;Dendrite 用 **shared-secret 模式**让 `/voip/turnServer` 动态签发短期 credentials。

| 维度 | 说明 |
|---|---|
| 自包含 | ✅ 只给一把 AWS key 就能起,零外部账号、零额外月费 —— 契合 skill 定位 |
| 动态凭证 | ✅ shared-secret 模式 = homeserver 按 ttl 现签,满足文档"短期有效/动态签发"要求 |
| 成本 | ✅ 不额外花钱(复用同一台 EC2;TURN relay 流量走该机带宽) |
| 代价 | ⚠️ 要在安全组开 TURN 端口(含一段 UDP relay 范围);coturn 容器要拿公网 IP 作 external-ip |
| 改动量 | 8 处(见第三节) |

### 备选方案 B:接外部 TURN 服务商(未采用)
skill 不部署 coturn,只把服务商给的 `uris + username/password` 写进 Dendrite turn 段。

| 维度 | 说明 |
|---|---|
| 运维 | ✅ 最省心,relay 由服务商扛,不用开 UDP 端口 |
| 自包含 | ❌ 破坏"只给一把 AWS key"——需额外注册服务商、拿密钥 |
| 成本 | ⚠️ 可能按流量计费(Twilio)或有额度上限(Cloudflare 免费档) |
| 动态凭证 | ⚠️ 多数服务商也支持短期凭证,但要 skill 去调它的签发 API,反而更复杂 |
| 改动量 | 少(只改 Dendrite turn 段 + S7 验收),但多一份"用户要准备的外部凭证" |

**最终采用方案 A**。理由:这个 skill 的核心卖点是 AWS 内自包含部署;B 会引入新的外部服务商注册和密钥准备。A 的唯一代价是多开几个端口,并已通过收窄 UDP relay 范围把暴露面压到最小。

---

## 二、端口规划(按你的选择:收窄固定 UDP 范围)

| 端口 | 协议 | 用途 | 是否对公网 |
|---|---|---|---|
| 3478 | udp + tcp | TURN/STUN 主端口 | ✅ 安全组放行 |
| **49160–49200** | udp | relay 媒体端口(**收窄固定范围**,~40 个) | ✅ 放行这一段 |

> 收窄范围够小规模 1:1 通话用;并发高时再调宽。coturn 用 `min-port/max-port` 锁这段,安全组只开这段。
> Caddy **不**代理 TURN(UDP 走不了 Caddy);coturn 端口直接暴露在主机网络。

---

## 三、8 处改动(具体代码片段,方案 A)

### 1. `scripts/cloud-init/docker-compose.yml` — 加 coturn 服务
```yaml
  # ── coturn (TURN relay,WebRTC 通话必需) ──────────────────────────
  # 用 host 网络以正确处理 UDP relay 与 external-ip(容器 NAT 会破坏 relay)。
  # DOMAIN/PUBLIC_IP/TURN_SECRET 由 .env 注入(user-data 写)。
  coturn:
    image: coturn/coturn:latest
    network_mode: host          # relay 必须;不要放进 p2p-net 桥接网络
    restart: unless-stopped
    command:
      - -n
      - --realm=${DOMAIN}
      - --listening-port=3478
      - --min-port=49160
      - --max-port=49200
      - --external-ip=${PUBLIC_IP}
      - --use-auth-secret
      - --static-auth-secret=${TURN_SECRET}
      - --no-cli
      - --no-multicast-peers
      - --no-tls
      - --no-dtls
```
> 注:`network_mode: host` 与现有 `networks: [p2p-net]` 不兼容,coturn 单独用 host 网络。
> 其余服务不变。

### 2. `phases/s3_provision.sh` — 安全组加 TURN 端口
把现有 `for p in 22 80 443` 段扩展:
```bash
# 基础:SSH/HTTP/HTTPS
for p in 22 80 443; do
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port "$p" --cidr 0.0.0.0/0 >/dev/null
done
# TURN:3478 udp+tcp
aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 3478 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol udp --port 3478 --cidr 0.0.0.0/0 >/dev/null
# TURN relay UDP 收窄范围 49160-49200
aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol udp --port 49160-49200 --cidr 0.0.0.0/0 >/dev/null
```
注释同步从"仅 22/80/443"改成"22/80/443 + TURN(3478 + 49160-49200/udp)"。

### 3. `scripts/cloud-init/user-data.yaml` — 注入 PUBLIC_IP / TURN_SECRET 到 .env
在 cloud-init 的 IMDS 取公网 IP 那步顺便落 `PUBLIC_IP`;再生成一个随机 `TURN_SECRET`:
```bash
# 已有:IP=$(curl ... public-ipv4)
echo "PUBLIC_IP=$IP" >> /opt/p2p/.env
# TURN 共享密钥(随机,homeserver 与 coturn 共用)
echo "TURN_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)" >> /opt/p2p/.env
```
> 注:custom 域名模式下 PUBLIC_IP 取不到 IMDS 也能用 `curl ifconfig.me` 兜底;或由 deploy 端注入。

### 4. compose 的 message-server init — 追加 turn 段(让 turnServer 非空)
照现有 `printf ... >> $$CFG` 的模式,在 app_service_api 之后再追加:
```sh
        # TURN:与 coturn 共用 static-auth-secret,Dendrite 按 ttl 动态签 credentials
        printf '\nclient_api:\n  turn:\n    turn_shared_secret: "%s"\n    turn_user_lifetime: "24h"\n    turn_uris:\n      - "turn:%s:3478?transport=udp"\n      - "turn:%s:3478?transport=tcp"\n' "$$TURN_SECRET" "${DOMAIN}" "${DOMAIN}" >> "$$CFG"
```
> message-server init 需要 `TURN_SECRET` 环境变量(从 .env 传入 `environment:`)。
> turn_uris 用 `${DOMAIN}`(正式域名),解析到公网 IP,coturn 在那监听。

### 5. `scripts/cloud-init/Caddyfile` — 不动(确认 TURN 不走 Caddy)
TURN 端口直连 coturn,Caddyfile **不加** TURN 反代。仅在文件头注释说明"TURN 由 coturn 直接暴露,不经 Caddy"。

### 6. `phases/s7_verify_e2e.sh` — 加 TURN 验收
新增一项(用 password/agent_token 换 access_token 后查 turnServer):
```bash
# 换统一 access_token
at=$(curl -sk -X POST "https://$domain/_p2p/command" -H 'Content-Type: application/json' -d "{\"action\":\"portal.auth\",\"params\":{\"password\":\"$password\"}}" | jq -r '.access_token')
# 查 turnServer 必须非空、有 turn: uris、有 username/password、ttl>0
turn=$(curl -sk "https://$domain/_matrix/client/v3/voip/turnServer" -H "Authorization: Bearer $at")
echo "$turn" | jq -e '.uris and (.uris|length>0) and (.uris[]|test("^turns?:")) and (.username!="") and (.password!="") and (.ttl>0)' >/dev/null \
  && ok "  ✓ TURN turnServer 非空且有效" || { warn "  ✗ TURN turnServer 无效:$turn"; fails=$((fails+1)); }
```

### 7. `references/troubleshooting.md` — 加 TURN 排查
新增条目:
- **症状**:通话一直"正在连接"→"连接失败"。
- **查**:`/_matrix/client/v3/voip/turnServer` 是否返回 `{}`;coturn 容器是否在跑(`docker compose ps`);安全组 3478/49160-49200 是否放行;`docker logs coturn` 看有没有 relay 分配。
- **修**:turn 段没追加 → 看 message-server init;端口没开 → 看 s3 安全组;external-ip 错 → 看 .env PUBLIC_IP。

### 8. `references/bug-history.md` + root `SKILL.md` — 记一笔"别再丢 VoIP"
- bug-history 加:"VoIP 通话连不上 = 没 TURN relay。已加 coturn + Dendrite shared-secret turn 段 + 安全组 TURN 端口。重部署勿删。"
- deployer skill 关键设计加一行:"**TURN/coturn 是通话必需**,compose 含 coturn、安全组开 3478/49160-49200,别为简化删掉。"

---

## 四、验收(文档给的标准,落到 S7 + 人工)

**自动(S7)**:`/_matrix/client/v3/voip/turnServer` 返回非空 + uris 含 `turn:` + username/password 非空 + ttl>0。

**人工(浏览器)**:Alice/Bob 互拨语音/视频 → 从"正在连接"进"通话中" → WebRTC internals 看到 **relay** ICE candidate → 挂断后 timeline 有通话系统消息(`m.call.candidates` 等技术信令不应当普通聊天显示)。

---

## 五、当前状态与剩余验收

1. 方案 A 已落地到部署 skill,第一版只跑明文 `turn:3478`(udp+tcp),不上 `turns:5349`。
2. 自动验收已进入 S7:能防止重部署后 `turnServer` 再次变成 `{}`。
3. 基础部署验收只阻塞在 S7 `turnServer` 非空/有效;真正的媒体链路属于 VoIP 专项验收,仍需 Alice/Bob 真机互拨,并在 WebRTC internals 看到 `relay` ICE candidate。

> agent 项目:**这件事无需改动**(已核实它与 TURN/通话无关)。
