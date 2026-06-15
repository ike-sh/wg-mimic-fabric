# 公网入口 → IX 中转 → 落地（纯转发）

对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric) 的三段式拓扑。**落地机无需安装 WG、无需 Mimic**，只需在 IX 组网可达后把流量转到目标 `IP:端口`。

## 架构

```text
客户端
  → 公网入口 Debian12/13  公网IP:30000     [relay ingress]
  → IX 中转 Debian12        IX内网IP:40000   [relay transit]
  → 落地 任意               LANDING_IP:PORT  （无 wm，无 WG）
```

- **relay**：仅 `nftables` DNAT + masquerade，不装 mimic、不建 WG 隧道
- **组网**：公网入口须能路由到 IX 机（IX 网段 / 专线 / 内网）。与 ix-transit 的 EasyTier 不同，此处假设 IX 侧 IP 已互通

## 部署步骤

### 1. IX 中转机（Debian 12）

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo WMF_NO_MENU=1 bash

sudo wm create-relay
# 用途: transit
# 监听端口: 40000
# 目标 IP: <落地 IP>
# 目标端口: <落地业务端口>
# 协议: both / tcp / udp

sudo wm start ix-transit
sudo wm health ix-transit
```

### 2. 公网入口机（Debian 12/13）

```bash
sudo wm create-relay
# 用途: ingress
# 监听端口: 30000          ← 客户端连这个
# 目标 IP: <IX机 IX网段IP>
# 目标端口: 40000

sudo wm start pub-ingress
sudo wm health pub-ingress
```

### 3. 客户端

连接：`公网入口公网IP:30000`（TCP/UDP 取决于规则里的 `FORWARD_PROTO`）

### 4. 验证

```bash
sudo wm health <线路ID>
sudo nft list table inet wg_mimic_fabric
sysctl net.ipv4.ip_forward   # 应为 1
```

## 与 ix-transit-fabric 对照

| ix-transit | wg-mimic relay |
|------------|----------------|
| `LOCAL_PORT` | ingress `RELAY_LISTEN_PORT` |
| `TRANSIT_PORT` | transit `RELAY_LISTEN_PORT` |
| `LANDING_HOST:PORT` | transit `RELAY_TARGET_*` |
| EasyTier 组网 | IX 网段路由（需自行保证互通） |
| `IXTF1` 接入码 | 暂未实现，两台机各配一条 relay |

## 何时仍用 WG + Mimic

- 需要 **端到端 VPN 隧道**（非纯端口转发）→ `create-server` + `import-code`
- 公网段需要 **UDP 混淆** → `create-forwarder`（WG 客户端 + Mimic）
- **落地无 WG** 的端口业务 → 本 relay 模式

## 后续规划

- WMGF 二级接入码（transit 生成 → ingress 导入）
- 公网入口 ↔ IX 自动 mesh（无 IX 路由时）
- 多规则 / DDNS（对齐 ix-transit）
