# wg-mimic-fabric

**当前版本**：`v0.6.0`
**仓库**：https://github.com/ike-sh/wg-mimic-fabric
**定位**：公网入口 ⇄ IX 经 **WireGuard 组网**，链路用 **Mimic 把 WG 的 UDP 伪装成 TCP** 穿透封锁，IX 侧用 **nftables** 转发到落地。运维体验对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric)。

```text
客户端 ──Mimic(伪TCP)承载的 WireGuard──► 公网入口 ⇄ IX ──nft──► 落地:端口
```

一条 WG 隧道承载多条转发规则；支持 IPv4/IPv6 双栈、域名 DDNS、线路主备手动切换。

---

## 目录

- [架构](#架构)
- [安装](#安装)
- [快速部署](#快速部署)
- [多转发规则](#多转发规则)
- [IPv6 / 双栈](#ipv6--双栈)
- [DDNS（域名自动刷新）](#ddns域名自动刷新)
- [主备切换](#主备切换)
- [常用命令](#常用命令)
- [平台与 MTU](#平台与-mtu)
- [安全](#安全)
- [环境变量](#环境变量)

---

## 架构

```text
客户端
  → 公网入口 公网IP:客户端入口端口(client_port)
  → 公网入口 nft DNAT
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2，Mimic 把 WG 的 UDP 伪装为 TCP）
  → IX 虚拟IP 10.88.0.2:中转端口(transit_port)
  → IX nft DNAT
  → 落地 landing_host:landing_port
```

| 角色 | 机器 | 职责 |
|------|------|------|
| `nat-transit` | IX / 落地侧 | WG 监听 + Mimic + nft 转发到落地 + 生成接入码 |
| `nat-ingress` | 公网入口 | 导入接入码 + WG 连入 + Mimic + 客户端入口 |

一条 WG 隧道承载全部规则；规则差异只体现在两端 nft DNAT 与入口 `client_port`。

---

## 安装

```bash
# 两端都需要 mimic（WG 的 UDP 由 Mimic 伪装 TCP）；内核需 ≥ 6.1
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装后用全局命令 `wm`（无参数进菜单）。`wm compat` 查看本机兼容评级，`wm install-deps` 看依赖指引。

---

## 快速部署

### 1. IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填：公网入口可达的 IX 地址、WG 端口、IP 版本(4/6/dual)、落地 IP/端口
# 复制输出的 WMGF1: 接入码
wm start <线路ID>
```

### 2. 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴接入码；为每条规则分配客户端入口端口
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
wm enable-rule|disable-rule <ID> <规则ID>
wm set-pool <ID> [端口池]  # 设置/清除 IX 中转端口池(如 40000-40010,40050)
wm refresh-code <ID>     # 按当前规则刷新接入码（不换密钥、不断流；改规则后公网入口重新 import-code）
wm apply-rules <ID>      # 重建 nft
```

> 改/增/删规则会**自动重生成接入码且不换密钥**，公网入口重新 `import-code` 即可，隧道不会断。
> 仅在**密钥泄露**时才用 `wm rotate-keys <ID>` 轮换密钥（会重启 IX，两端短暂中断）。

### 商家中转端口池（可选）

商家给的 IX 端口通常是有限的几个/几段。给 IX 线路设置 **中转端口池** 后，`create-transit` 与 `add-rule` 会自动从池中取下一个空闲端口作为默认 `transit_port`（可手动覆盖），并强制所选端口落在池内、禁止与同线路其它规则重复；池用尽时报错提示。端口池仅是 IX 侧分配状态，**不进入接入码、不影响公网入口**；留空即恢复手动指定。

```bash
wm set-pool ix-nat 40000-40010,40050   # 设置端口池
wm set-pool ix-nat                     # 留空=清除，恢复手动指定
wm list-rules ix-nat                    # 顶部显示「端口池: …（共/已用/剩）」
```

接入码（`code_schema=5`）含组网密钥与落地信息，**请勿公开**；泄露后用 `wm rotate-keys` 轮换入口密钥并刷新接入码（会重启 IX），再到公网入口重新导入即可。

---

## IPv6 / 双栈

`create-transit` 时选 **IP 版本** `4 / 6 / dual`。选 `6`/`dual` 会为 WG 隧道分配 IPv6 虚拟网（如 `fd88:6d6d::/64`）。

- **落地 IPv6**：规则的落地地址填 IPv6（如 `2606:4700::1111`），nft 自动用 `ip6` DNAT/masquerade。
- **落地域名**：填域名即可，nft 渲染时自动解析为 IP（A/AAAA），并随 DDNS 刷新。
- 规则的协议族由其落地地址（解析后）的族决定；MTU 建议 IPv6/dual 用 **1408**。

---

## DDNS（域名自动刷新）

当 IX 端点或落地为**域名**时，IP 变化会自动跟随：

```bash
wm ddns-enable      # 启用每 3 分钟定时刷新（systemd timer）
wm ddns-refresh     # 手动刷新一次
wm ddns-status
wm ddns-disable
```

- 公网入口：重新解析 `IX_ENDPOINT_HOST`，变化时 `wg set ... endpoint` 热更新；
- 落地域名：`apply_nft_all` 渲染时重新解析，自动跟随。

---

## 主备切换

把多条线路（如经不同 IX 的入口线路）编入同一分组，**手动**在主备间切换（对标 ix-transit「不自动切换」的安全边界）：

```bash
wm set-group <ID> <组名> primary 100     # 标记线路所属分组/角色/优先级
wm set-group <ID2> <组名> backup 90
wm list-groups
wm primary-backup-check <组名>            # 查看各成员 health 与当前 active
wm switch-line <组名> <目标线路ID>         # 启用目标、停用同组其它，重建 nft
wm health-all
```

---

## 常用命令

| 命令 | 说明 |
|------|------|
| `wm` | 交互菜单 |
| `wm create-transit` | IX：创建组网线路 + 首条规则，生成接入码 |
| `wm import-code` | 公网入口：导入接入码 |
| `wm start\|stop\|restart [ID]` | 启停线路（两端均需 WG+Mimic） |
| `wm show-port-map [ID]` | 端口地图 |
| `wm show-code [ID]` / `refresh-code [ID]` | 显示 / 按当前规则刷新接入码（不换密钥，IX） |
| `wm rotate-keys [ID]` | 轮换入口密钥并刷新接入码（密钥泄露时用，会重启 IX） |
| `wm list-rules\|add-rule\|edit-rule\|delete-rule\|enable-rule\|disable-rule\|apply-rules` | 规则管理 |
| `wm set-pool <ID> [端口池]` | IX 中转端口池(如 40000-40010；留空=清除，规则自动分配) |
| `wm ddns-enable\|ddns-disable\|ddns-status\|ddns-refresh` | DDNS |
| `wm set-group\|list-groups\|switch-line\|primary-backup-check\|health-all` | 主备 |
| `wm health [ID]` / `diagnose [ID]` | 健康检查 / 诊断 |
| `wm set-mtu <ID> <MTU>` / `set-xdp-mode <ID> [skb\|native]` | 调参 |
| `wm upgrade-script` / `uninstall` / `purge` | 维护 |

---

## 平台与 MTU

- Mimic 需内核 **≥ 6.1**（Debian 13 / Ubuntu 24.04 推荐）；详见 [docs/platform-support.md](docs/platform-support.md)。
- Mimic 每包多占 12 字节，WG MTU 建议 **1420**（IPv4）/ **1408**（IPv6/dual）；Intel 网卡丢包可 `wm set-xdp-mode <ID> skb`。

---

## 安全

- 接入码含 WG 组网私钥与落地信息，按密钥对待，勿公开；泄露后 `rotate-keys` 轮换密钥。
- 主备为手动切换，脚本不自动切线、不接管全局防火墙。
- `wm purge` 会删除全部配置/密钥/接入码/服务（含 mimic 系统包，可用 `WMF_PURGE_NO_MIMIC=1` 保留）。

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `WMF_TAG=v0.6.0` | 安装/升级时指定版本 |
| `WMF_REPO` | GitHub 仓库（默认 `ike-sh/wg-mimic-fabric`） |
| `WMF_SKIP_MIMIC=1` | 跳过 mimic 自动安装 |
| `WMF_AUTO_MIMIC=0` | `install-wm-cli` 时不自动装 mimic |
| `WMF_UPGRADE_YES=1` / `WMF_PURGE_YES=1` / `WMF_UNINSTALL_YES=1` | 跳过相应确认 |
| `WMF_PURGE_NO_MIMIC=1` | purge 时保留 mimic 系统包 |
| `WMF_GITHUB_MIRRORS=url,...` | GitHub 下载镜像（国内网络） |
| `MIMIC_UPSTREAM_TAG` | 源码编译 mimic 的版本（默认 `v0.7.0`） |

---

## License

MIT
