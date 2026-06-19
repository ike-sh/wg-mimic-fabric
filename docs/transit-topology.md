# 公网入口 ⇄ IX（WireGuard 组网）→ 落地

对标同类 IX 中转方案，但组网改用 **WireGuard**：公网入口与 IX 经 WG 点对点互联，链路由 **Mimic** 伪装成 TCP；IX 经 nft 转发到落地。

## 架构

```text
客户端
  → 公网入口 公网IP:client_port
  → 公网入口 nft DNAT → IX虚拟IP:transit_port
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2，Mimic 伪 TCP 承载 WG 的 UDP）
  → IX nft DNAT → 落地 landing_host:landing_port
```

一条 WG 隧道承载所有规则；每条规则差异仅在两端 nft DNAT 与入口 `client_port`。

## 1. IX / 落地侧（nat-transit）

```bash
curl -fsSL .../bootstrap.sh | sudo bash
sudo wm create-transit
# 公网入口可达的 IX 地址（域名/IP）、WG 端口、落地 IP/端口
sudo wm start ix-nat
# 复制 WMGF1: 接入码
```

## 2. 公网入口（nat-ingress）

```bash
curl -fsSL .../bootstrap.sh | sudo bash
sudo wm import-code
# 粘贴接入码；为每条规则分配客户端入口端口
sudo wm start ix-nat-ingress
```

## 3. 客户端

连接：`公网入口IP:<client_port>`（`wm show-port-map`）

## 端口术语

| 名称 | 说明 |
|------|------|
| client_port | 客户端连接公网入口的端口 |
| transit_port | IX 虚拟 IP 上的中转端口（WG 内网） |
| landing_host:landing_port | 落地业务地址 |
| WG_PORT | IX 的 WireGuard 监听端口（Mimic 伪 TCP 绑定，需对入口放行 TCP+UDP） |

## 前提

- 公网入口能路由到 `IX_ENDPOINT_HOST:WG_PORT`。
- 两端内核 ≥ 6.1 且 Mimic 可用（`wm compat`）。

## 变更记录

v0.6.0：EasyTier/relay 模型 → WireGuard 组网 + Mimic 伪 TCP，接入码 schema=5（含规则/落地/MTU）。
