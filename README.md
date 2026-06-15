# wg-mimic-fabric

**当前版本**：`v0.6.0`
**仓库**：https://github.com/ike-sh/wg-mimic-fabric
**定位**：公网入口 ⇄ IX **WireGuard 组网** + **Mimic（UDP→伪 TCP）** + nft 转发到落地。运维体验对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric)。

公网入口与 IX 之间用 **WireGuard 点对点组网**，链路由 **Mimic** 伪装成 TCP 穿透对 UDP/WG 的封锁；IX 侧用 nftables 把虚拟网端口转发到落地。一条 WG 隧道承载多条转发规则。

```text
客户端 ──Mimic(伪TCP)承载的 WG──► 公网入口 ⇄ IX ──nft──► 落地:端口
```

---

## 架构

```text
客户端
  → 公网入口 公网IP:客户端入口端口(client_port)
  → 公网入口 nft DNAT
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2，Mimic 把 WG 的 UDP 伪装为 TCP）
  → IX 虚拟IP 10.88.0.2:中转端口(transit_port)
  → IX nft DNAT
  → 落地:业务端口(landing_host:landing_port)
```

| 角色 | 机器 | 职责 |
|------|------|------|
| `nat-transit` | IX / 落地侧 | WG 监听 + Mimic + nft 转发到落地 + 生成接入码 |
| `nat-ingress` | 公网入口 | 导入接入码 + WG 连入 + Mimic + 客户端入口 |

---

## 安装

```bash
# 两端都需要 mimic（WG 的 UDP 由 Mimic 伪装 TCP）
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装后用全局命令 `wm`（无参数进菜单）。

---

## 快速部署

### 1. IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填写：公网入口可达的 IX 地址、WG 端口、落地 IP/端口
# 复制输出的 WMGF1: 接入码
wm start <线路ID>
```

### 2. 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴 IX 接入码，按提示为每条规则分配客户端入口端口
wm start <线路ID>-ingress
```

### 3. 客户端

连接：`公网入口IP:<客户端入口端口>`（`wm show-port-map` 查看）

详见 [docs/transit-topology.md](docs/transit-topology.md)。

---

## 多转发规则

一条 WG 隧道可承载多条规则，每条独立的 `transit_port` 与落地：

```bash
wm list-rules <ID>
wm add-rule <ID>
wm edit-rule <ID> <规则ID>
wm delete-rule <ID> <规则ID>
wm refresh-code <ID>     # IX 改规则后刷新接入码
wm apply-rules <ID>      # 重建 nft
```

IX 改规则后需 `refresh-code` 并在公网入口 `import-code` 重新导入。接入码含组网密钥与落地信息，**请勿公开**；泄露后 `refresh-code` 轮换入口密钥并重新导入。

---

## 常用命令

| 命令 | 说明 |
|------|------|
| `wm` | 交互菜单 |
| `wm create-transit` | IX：创建组网线路 + 首条规则，生成接入码 |
| `wm import-code` | 公网入口：导入接入码 |
| `wm start\|stop\|restart [ID]` | 启停线路（两端均需 WG+Mimic） |
| `wm show-port-map [ID]` | 端口地图 |
| `wm show-code [ID]` / `refresh-code [ID]` | 显示 / 刷新接入码（IX） |
| `wm health [ID]` / `diagnose [ID]` | 健康检查 / 诊断 |
| `wm set-mtu <ID> <MTU>` / `set-xdp-mode <ID> [skb\|native]` | 调参 |
| `wm upgrade-script` | 升级脚本 |

---

## 平台 / MTU

- Mimic 需内核 **≥ 6.1**（Debian 13 / Ubuntu 24.04 推荐）；`wm compat` 查看评级，`wm install-deps` 看依赖指引。
- Mimic 每包多占 12 字节，WG MTU 建议 **1420**（IPv4）；Intel 网卡丢包可 `wm set-xdp-mode <ID> skb`。

---

## 升级

```bash
wm upgrade-script
```

---

## License

MIT
