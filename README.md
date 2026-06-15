# wg-mimic-fabric

**版本**：`v1.0.0` ·
**仓库**：https://github.com/ike-sh/wg-mimic-fabric ·
**许可**：MIT

一键把「公网入口 ⇄ IX/落地」用 **WireGuard** 组网，并用 **Mimic** 把 WireGuard 的 UDP 流量**伪装成 TCP** 穿透对 UDP 的封锁/QoS，IX 侧再用 **nftables** 把流量转发到落地服务。一个全局命令 `wm`，交互菜单 + CLI 全覆盖；运维体验对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric)。

```text
客户端 ──Mimic(伪TCP)承载的 WireGuard──► 公网入口 ⇄ IX ──nft──► 落地:端口
```

---

## 目录

- [什么是 Mimic](#什么是-mimic)
- [系统要求](#系统要求)
- [wg-mimic-fabric 做什么](#wg-mimic-fabric-做什么)
- [架构](#架构)
- [安装](#安装)
- [快速部署](#快速部署)
- [多转发规则与端口池](#多转发规则与端口池)
- [线路质量与中转切换](#线路质量与中转切换)
- [IPv6 / 双栈](#ipv6--双栈)
- [DDNS（域名自动刷新）](#ddns域名自动刷新)
- [主备切换](#主备切换)
- [常用命令](#常用命令)
- [XDP 模式与 MTU](#xdp-模式与-mtu)
- [故障排查](#故障排查)
- [安全](#安全)
- [环境变量](#环境变量)

---

## 什么是 Mimic

[Mimic](https://github.com/hack3ric/mimic) 是一个基于 **eBPF（XDP + TC）** 的流量伪装工具：它在网卡收发路径上**就地改写报文头**，让 WireGuard 的 **UDP** 包在链路上**看起来像 TCP**，从而绕过运营商/防火墙对 UDP 的封锁、限速与 DPI。

### 工作原理

- **发包（TC egress）**：把出站的 WireGuard UDP 包封装/改写成「伪 TCP」（带看似合法的 TCP 头、序号）。
- **收包（XDP ingress）**：把入站的「伪 TCP」还原成 UDP，交还给内核的 WireGuard。
- 对 WireGuard 完全透明——WG 仍以为自己在收发 UDP；**两端都必须运行 Mimic**，各自双向 encode/decode。
- 通过 **filter** 选择要处理的流：`filter = local=IP:端口`（本机监听侧，如 IX）或 `filter = remote=IP:端口`（主动连接侧，如公网入口）。

### 关键特性

- **精确 IP 匹配**：Mimic 在 XDP/TC 看到的是**网卡上的真实目的 IP**。NAT/端口转发机器上，公网流量进网卡前已被改写成内网 IP，所以 IX 侧的 `filter = local=` 必须用**网卡的真实（内网）IP**，而不是公网 IP（本脚本自动处理）。
- **两种 XDP attach 模式**：`native`（驱动层，最快，需驱动支持）/ `skb`（通用，任意网卡可用，略慢）。`virtio_net` 等虚拟网卡通常只能用 `skb`。

> Mimic 链路上是 TCP，但发起方仍是 UDP 行为——netfilter 入站识别为 TCP、出站为 UDP，**云安全组需对 WG 端口同时放行 TCP 和 UDP**。

---

## 系统要求

### Mimic（两端都要装）

| 项 | 要求 |
|------|------|
| 内核 | **Linux ≥ 6.1**（Mimic 用到较新的 eBPF/kfunc，低于 6.1 无法运行） |
| BTF | 需 `/sys/kernel/btf/vmlinux`（`CONFIG_DEBUG_INFO_BTF=y`）；精简内核无 BTF 时需用 `kprobe` 变体源码编译 |
| 内核模块 | `mimic`（内核态，经 **DKMS** 按当前内核编译）+ `mimic` CLI（用户态） |
| 网卡 | 任意（`skb` 模式通用）；物理网卡支持 `native` 则更快 |
| Secure Boot | 若开启，DKMS 编译的模块需 **MOK 签名/入册**，否则内核拒绝加载 |

### wg-mimic-fabric 本体

- `bash`、`python3`、`wireguard-tools`（`wg` / `wg-quick`）、`nftables`、`curl`、`iproute2`
- `systemd`（线路/Mimic/DDNS/自动切换均以 systemd 单元运行）
- **root** 权限

### 发行版兼容评级（`wm compat` 查看本机）

| 评级 | 发行版 | 说明 |
|------|--------|------|
| 推荐 | **Debian 13 / Ubuntu 24.04** | 官方 mimic `.deb` + apt，内核 ≥ 6.1 |
| 良好 | Arch | AUR：`mimic-bpf` |
| 有条件 | Fedora / RHEL 系 | 默认内核常 < 6.1，需 elrepo kernel-ml 或换 Debian/Ubuntu，mimic 源码编译 |
| 实验 | Alpine / OpenWrt | 无 DKMS，需源码编译（Alpine 用 `kprobe`），生产不推荐 |

> 安装脚本会**自动安装 mimic**（apt → GitHub `.deb` → 源码编译，三级回退）并按当前内核用 DKMS 编译模块。

---

## wg-mimic-fabric 做什么

把上面这套「WireGuard 组网 + Mimic 伪装 + nft 转发」的搭建与运维**全自动化**成一个 `wm` 命令：

- **IX/落地侧**一条命令建线路、生成「接入码」；**公网入口**粘贴接入码即自动组网。
- 一条 WG 隧道**承载多条转发规则**，每条规则独立的中转端口 → 落地。
- 自动处理 NAT/端口转发机器的 Mimic 绑定、网卡 XDP 模式（`virtio` 自动用 `skb`）、systemd 单元、防火墙放行。
- 内置：**IPv4/IPv6 双栈**、落地**域名 DDNS**、线路**主备**、**隧道丢包自检（`wm test`）**、**中转线路切换/自动切换**。

### 角色

| 角色 | 机器 | 职责 |
|------|------|------|
| `nat-transit` | IX / 落地侧 | WG 监听 + Mimic + nft 转发到落地 + 生成接入码 |
| `nat-ingress` | 公网入口 | 导入接入码 + WG 连入 + Mimic + 对客户端开放入口端口 |

---

## 架构

```text
客户端
  → 公网入口 公网IP:客户端入口端口(client_port)
  → 公网入口 nft DNAT
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2；Mimic 把 WG 的 UDP 伪装为 TCP）
  → IX 虚拟IP 10.88.0.2:中转端口(transit_port)
  → IX nft DNAT
  → 落地 landing_host:landing_port
```

一条 WG 隧道承载全部规则；规则差异只体现在两端 nft DNAT 与入口 `client_port`。**接入码**（`WMGF1:`，`code_schema=5`）携带 WG 组网密钥、虚拟 IP、端口、落地与多规则数组，由 IX 单向生成、公网入口导入。

---

## 安装

```bash
# 两端都执行；内核需 ≥ 6.1，脚本会自动装 mimic 并按当前内核编译模块
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装后用全局命令 `wm`（无参数进交互菜单）。`wm compat` 查看本机兼容评级，`wm install-deps` 看依赖指引，`wm upgrade-script` 升级。

---

## 快速部署

### 1. IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填：公网入口可达的 IX 公网地址/中转IP、WG 端口、IP 版本(4/6/dual)、（可选）端口池、首条落地 IP/端口
# 复制输出的 WMGF1: 接入码
```
创建末尾会询问是否立即 `wm start`。

### 2. 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴接入码；为每条规则分配「客户端入口端口」（默认与落地端口一致，回车即可）
```
导入末尾同样会询问是否立即 `wm start`。再次导入会进入**更新模式**（同步规则、保留已选入口端口）。

### 3. 客户端

连接 `公网入口IP:<客户端入口端口>`（`wm show-port-map <ID>-ingress` 查看完整端口地图）。

详见 [docs/transit-topology.md](docs/transit-topology.md) 与 [examples/operations.md](examples/operations.md)。

---

## 多转发规则与端口池

一条 WG 隧道可承载多条规则，每条独立的 `transit_port` 与落地：

```bash
wm list-rules <ID>
wm add-rule <ID>                 # 新增（自动重生成接入码，密钥不变）
wm edit-rule <ID> <规则ID>
wm delete-rule <ID> <规则ID>
wm enable-rule|disable-rule <ID> <规则ID>
wm refresh-code <ID>             # 按当前规则刷新接入码（不换密钥、不断流）
wm apply-rules <ID>              # 重建 nft
```

> 改/增/删规则会**自动重生成接入码且不换密钥**——公网入口重新 `import-code` 即可，隧道不断。
> 仅在**密钥泄露**时才用 `wm rotate-keys <ID>` 轮换密钥（会重启 IX，两端短暂中断）。

### 商家中转端口池（可选）

商家给的 IX 端口往往有限。给 IX 线路设 **中转端口池** 后，`create-transit` / `add-rule` 自动从池中取下一个空闲端口作默认中转端口，并强制端口落在池内、禁止重复；池用尽时报错。端口池仅 IX 侧分配状态，**不进入接入码、不影响公网入口**。

```bash
wm set-pool ix-nat 18300-18399    # 设置端口池
wm set-pool ix-nat                # 留空=清除，恢复手动指定
```

---

## 线路质量与中转切换

很多线路「能连但卡 / 客户端不显示延迟」其实是**中转线路丢包**（隧道之上的网络质量问题，不是组网配置错误）。用以下工具自检与切换：

```bash
wm test <ID> [包数]               # 实测隧道真实丢包/延迟并给质量判定（默认100包）
wm set-endpoint <ID> <中转IP>      # 切换该线路用的 IX 公网/中转地址（入口侧即时生效）
```

多中转**自动切换**（专治中转线路波动丢包）：

```bash
wm set-endpoints <入口线路> IP1,IP2,IP3   # 设置候选中转列表（均指向同一 IX）
wm autoswitch <入口线路> [阈值%]           # 测当前丢包，超阈值(默认10%)自动探测并切到最优候选
wm autoswitch-enable <入口线路>           # 定时自动切换（每5分钟）
wm autoswitch-disable <入口线路>
```

> 判定标准：丢包 ≤2% 良好 / ≤10% 一般 / >10% 建议换中转。比较中转线路要用 `wm test`（走隧道实测），而不是对中转网关裸 `ping`（网关回 ICMP 正常不代表它转发不丢包）。

---

## IPv6 / 双栈

`create-transit` 时选 **IP 版本** `4 / 6 / dual`。选 `6`/`dual` 会为 WG 隧道分配 IPv6 虚拟网（如 `fd88:6d6d::/64`）。

- **落地 IPv6**：规则落地填 IPv6（如 `2606:4700::1111`），nft 自动用 `ip6` DNAT/masquerade。
- **落地域名**：填域名即可，nft 渲染时自动解析（A/AAAA），并随 DDNS 刷新。
- 规则协议族由落地地址族决定；MTU 建议 IPv6/dual 用 **1408**。

---

## DDNS（域名自动刷新）

当 IX 端点或落地为**域名**时，IP 变化自动跟随：

```bash
wm ddns-enable      # 启用每 3 分钟定时刷新（systemd timer）
wm ddns-refresh     # 手动刷新一次
wm ddns-status / wm ddns-disable
```

- 公网入口：重新解析 `IX_ENDPOINT_HOST`，变化时 `wg set ... endpoint` 热更新；
- 落地域名：渲染 nft 时重新解析，自动跟随。

---

## 主备切换

把多条线路（如经不同 IX 的入口线路）编入同一分组，**手动**在主备间切换（对标 ix-transit「不自动切换」的安全边界）：

```bash
wm set-group <ID> <组名> primary 100
wm set-group <ID2> <组名> backup 90
wm list-groups
wm primary-backup-check <组名>            # 查看各成员 health 与当前 active
wm switch-line <组名> <目标线路ID>         # 启用目标、停用同组其它，重建 nft
wm health-all
```

> 想要**自动**按丢包切换同一 IX 的多个中转入口，用上面的 [中转切换](#线路质量与中转切换) `autoswitch`。

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
| `wm set-pool <ID> [端口池]` | IX 中转端口池(如 18300-18399；留空=清除) |
| `wm test [ID] [包数]` | 实测隧道丢包/延迟（判断中转质量） |
| `wm set-endpoint <ID> <中转IP>` | 切换该线路的 IX 公网/中转地址 |
| `wm set-endpoints <ID> ip1,ip2,..` / `autoswitch [ID] [阈值]` / `autoswitch-enable\|autoswitch-disable [ID]` | 候选中转 + 自动切换 |
| `wm ddns-enable\|ddns-disable\|ddns-status\|ddns-refresh` | DDNS |
| `wm set-group\|list-groups\|switch-line\|primary-backup-check\|health-all` | 主备 |
| `wm health [ID]` / `diagnose [ID]` | 健康检查 / 诊断 |
| `wm set-mtu <ID> <MTU>` / `set-xdp-mode <ID> [skb\|native]` | 调参 |
| `wm install-all\|install-mimic\|install-deps\|compat` | 安装 / 兼容性 |
| `wm upgrade-script` / `uninstall` / `purge` | 维护 |

---

## XDP 模式与 MTU

- **XDP 模式全自动**：脚本读 `/sys/class/net/<网卡>/device/driver` 识别网卡。`virtio_net` 自动用 `skb`；其它网卡默认 `native`，起不来则自动清理残留 XDP 程序并回退 `skb`。可手动覆盖：`wm set-xdp-mode <ID> [skb|native]`。
- **MTU**：Mimic 每包多占约 12 字节，WG MTU 建议 **1420**（IPv4）/ **1408**（IPv6/dual）；丢包多可 `wm set-mtu <ID> 1380` 两端同改。

---

## 故障排查

| 现象 | 排查 |
|------|------|
| WG 不握手（`wg show` 无 handshake） | 确认入口能到 `IX_ENDPOINT_HOST:WG_PORT`；**云安全组对 WG 端口 TCP+UDP 都放行**；两端 Mimic 均 active |
| **能连但卡 / 客户端不显示延迟** | 多半是**中转线路丢包**：`wm test <ID>` 看真实丢包；>10% 就 `wm set-endpoint` 换中转或开 `autoswitch` |
| IX 侧 mimic 不匹配（`mimic show <网卡>` 无连接） | NAT 机器 `filter = local=` 须用网卡真实内网 IP（脚本自动）；可 `MIMIC_LOCAL_IP` 覆盖 |
| `mimic@<网卡> 仍未启动` | virtio 等网卡 native 起不来；脚本会自动回退 skb。若卡住：`ip link set dev <网卡> xdp off` 后 `wm restart <ID>` |
| 客户端连不上 | `wm show-port-map`，确认 `client_port` 已放行、IX 到落地可达（IX 上 `wm test` / `nc`） |
| mimic 模块缺失 | `wm install-mimic`；Secure Boot 需入册 MOK；内核与头文件不匹配需 `reboot` |
| MTU 异常/大包不通 | `wm set-mtu <ID> 1380`（两端） |

诊断命令：`wm diagnose <ID>`（OS/内核/BTF/mimic/ip_forward 预检 + health）、`wm test <ID>`（隧道丢包）、`wg show`、`mimic show <网卡>`。

---

## 安全

- 接入码含 WG 组网私钥与落地信息，**按密钥对待、勿公开**；泄露后用 `wm rotate-keys` 轮换密钥并重新导入。
- 主备/中转切换是脚本管理的线路级操作，不接管全局防火墙；`wm` 仅维护自己的 nft 表 `wg_mimic_fabric`。
- `wm purge` 删除全部配置/密钥/接入码/服务（含 mimic 系统包，`WMF_PURGE_NO_MIMIC=1` 可保留）。

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `WMF_TAG=v1.0.0` | 安装/升级时指定版本 |
| `WMF_REPO` | GitHub 仓库（默认 `ike-sh/wg-mimic-fabric`） |
| `WMF_SKIP_MIMIC=1` | 跳过 mimic 自动安装 |
| `WMF_AUTO_MIMIC=0` | `install-wm-cli` 时不自动装 mimic |
| `WMF_UPGRADE_YES=1` / `WMF_PURGE_YES=1` / `WMF_UNINSTALL_YES=1` | 跳过相应确认 |
| `WMF_PURGE_NO_MIMIC=1` | purge 时保留 mimic 系统包 |
| `WMF_GITHUB_MIRRORS=url,...` | GitHub 下载镜像（国内网络） |
| `MIMIC_UPSTREAM_TAG` | 源码编译 mimic 的版本（默认 `v0.7.0`） |
| `MIMIC_LOCAL_IP` | 覆盖 IX 侧 Mimic 绑定的本机 IP |

---

## License

MIT
