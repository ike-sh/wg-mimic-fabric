# wg-mimic-fabric

**版本**：`v1.1.1` ·
**仓库**：https://github.com/ike-sh/wg-mimic-fabric ·
**许可**：MIT

用 **WireGuard** 组网、用 **Mimic** 把 WG 的 **UDP 流量伪装成 TCP** 穿透对 UDP 的封锁/QoS，再按需叠加 **swgp-go** 做二层混淆。一个全局命令 `wm`（交互菜单 + CLI 全覆盖）一键搞定两类场景：

1. **IX 中转组网**：公网入口 ⇄ IX/落地，IX 侧用 **nftables** 把流量转发到落地服务（端口转发 / 中转加速）。
2. **混淆全局出口**：国内网关 A ⇄ 国外出口 B，本地设备连 A 即**全局**经隧道从 B 出网（翻墙 / 全局代理），支持 `swgp+mimic` 双层混淆 + 手机扫码接入。

```text
① 中转组网： 客户端 ──Mimic(伪TCP)承载的 WireGuard──► 公网入口 ⇄ IX ──nft──► 落地:端口
② 全局出口： 手机/设备 ──WG──► 国内网关 A ──swgp+mimic 隧道──► 国外出口 B ──► 互联网
```

---

## 目录

- [什么是 Mimic](#什么是-mimic)
- [什么是 swgp-go](#什么是-swgp-go)
- [系统要求](#系统要求)
- [wg-mimic-fabric 做什么](#wg-mimic-fabric-做什么)
- [安装](#安装)
- [场景一：IX 中转组网](#场景一ix-中转组网)
- [场景二：混淆全局出口](#场景二混淆全局出口)
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
- 通过 **filter** 选择要处理的流：`filter = local=IP:端口`（本机监听侧，如 IX/出口 B）或 `filter = remote=IP:端口`（主动连接侧，如公网入口/网关 A）。

### 关键特性

- **精确 IP 匹配**：Mimic 在 XDP/TC 看到的是**网卡上的真实目的 IP**。NAT/端口转发机器上，公网流量进网卡前已被改写成内网 IP，所以监听侧的 `filter = local=` 必须用**网卡的真实（内网）IP**，而不是公网 IP（本脚本自动处理）。
- **两种 XDP attach 模式**：`native`（驱动层，最快，需驱动支持）/ `skb`（通用，任意网卡可用，略慢）。`virtio_net` 等虚拟网卡通常只能用 `skb`。

> Mimic 链路上是 TCP，但发起方仍是 UDP 行为——netfilter 入站识别为 TCP、出站为 UDP，**云安全组需对 WG 端口同时放行 TCP 和 UDP**。

---

## 什么是 swgp-go

[swgp-go](https://github.com/database64128/swgp-go) 是一个用户态的 **WireGuard 流量混淆代理**：它在 WG 之外再加一层 **UDP 加密/混淆**（PSK 预共享密钥），把 WG 的 UDP 流量变成另一种「无规律 UDP」，进一步对抗基于特征的 DPI。

链路是 **WG → swgp-go → Mimic**：swgp-go 先把 WG 流量混淆成另一种 UDP，Mimic 再在最外层把它伪装成 TCP。两层叠加（`swgp+mimic`）是抗封锁最强的模式，用于「混淆全局出口」场景。

- swgp-go **按需自动安装**（无需手动）：从 GitHub release 选 **静态 `linux-x86-64-v2`** 构建（兼容性最广、无 glibc 依赖、不要求 AVX2），下载后**强制 ELF 校验**，损坏会**自动重装**。
- 混淆方式可选：`direct`（不混淆）/ `mimic`（仅伪 TCP）/ `swgp`（仅 swgp 混淆）/ `swgp+mimic`（双层，默认推荐）。
- swgp 模式：`zero-overhead-2026`（默认，零额外开销）/ `paranoid-2026`（更强混淆）。

> **NAT VPS 注意**：`swgp+mimic` 下，A 走公网连接的是 B 的 **swgp「线上端口」**（而非 WG 端口）。若 B 是 NAT 机，该端口**必须落在服务商转发给你的端口段内**，否则 A 的包到不了 B。`wm install-swgp` 可单独安装/修复 swgp-go。

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
- `systemd`（线路/Mimic/swgp/DDNS/自动切换均以 systemd 单元运行）
- 全局出口额外用到 `swgp-go`（自动装）、`qrencode`（出客户端二维码，自动装）、`zstd`（解 swgp release，自动装）
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

把「WireGuard 组网 + Mimic 伪装（+ swgp 混淆）+ nft 转发」的搭建与运维**全自动化**成一个 `wm` 命令：

- **一端建线路、生成「接入码」；另一端粘贴接入码即自动组网**（中转用 `create-transit`/`import-code`，出口用 `create-exit`/`import-exit-code`）。
- 自动处理 NAT/端口转发机器的 Mimic 绑定、网卡 XDP 模式（`virtio` 自动用 `skb`）、systemd 单元、防火墙放行、空闲 mesh 网段选取。
- 全局出口额外：自动装 swgp-go / qrencode，relay 网关自动配置策略路由 + 对端 mesh 路由，客户端一键出 `.conf` + 二维码。
- 内置：**IPv4/IPv6 双栈**、落地**域名 DDNS**、线路**主备**、**隧道丢包自检（`wm test`）**、**中转线路切换/自动切换**、**自动 MTU 探测（`wm automtu`）**。

### 角色

| 角色 | 机器 | 职责 |
|------|------|------|
| `nat-transit` | IX / 落地侧 | WG 监听 + Mimic + nft 转发到落地 + 生成接入码 |
| `nat-ingress` | 公网入口 | 导入接入码 + WG 连入 + Mimic + 对客户端开放入口端口 |
| `exit` | 国外出口 B | WG 监听 + swgp-go/Mimic 混淆 + 出网 NAT + 生成出口接入码 |
| `relay` | 国内网关 A | 导入出口接入码 + 连 B + 全局策略路由 + 客户端接入（出二维码） |

**接入码**（`WMGF1:` 前缀，`code_schema=6`）携带 WG 组网密钥、虚拟 IP、端口、混淆参数（swgp 模式/PSK/端口）与落地/规则信息，由一端单向生成、另一端导入。

---

## 安装

```bash
# 两端都执行；内核需 ≥ 6.1，脚本会自动装 mimic 并按当前内核编译模块
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装后用全局命令 `wm`（无参数进交互菜单）。`wm compat` 查看本机兼容评级，`wm install-deps` 看依赖指引，`wm upgrade-script` 升级（只更新 wm 脚本，不动 mimic）。

---

## 场景一：IX 中转组网

适合「公网入口转发到 IX/落地服务」（端口转发、中转加速）。

```text
客户端
  → 公网入口 公网IP:客户端入口端口(client_port)
  → 公网入口 nft DNAT
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2；Mimic 把 WG 的 UDP 伪装为 TCP）
  → IX 虚拟IP 10.88.0.2:中转端口(transit_port)
  → IX nft DNAT
  → 落地 landing_host:landing_port
```

### 1. IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填：公网入口可达的 IX 公网地址/中转IP、WG 端口、IP 版本(4/6/dual)、（可选）端口池、首条落地 IP/端口
# 复制输出的 WMGF1: 接入码
```

### 2. 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴接入码；为每条规则分配「客户端入口端口」（默认与落地端口一致，回车即可）
```

再次导入会进入**更新模式**（同步规则、保留已选入口端口）。两步末尾都会询问是否立即 `wm start`。

### 3. 客户端

连接 `公网入口IP:<客户端入口端口>`（`wm show-port-map <ID>-ingress` 查看完整端口地图）。

详见 [docs/transit-topology.md](docs/transit-topology.md) 与 [examples/operations.md](examples/operations.md)。

---

## 场景二：混淆全局出口

适合「国内网关 A → 国外出口 B 全局翻墙」：本地设备连 A，所有流量经 `swgp+mimic` 混淆隧道从 B 出网。

```text
手机/电脑 ──WG──► 国内网关 A(relay)
                     │  WG → swgp-go → Mimic（双层混淆，走公网到 B 的 swgp 端口）
                     ▼
                  国外出口 B(exit) ──出网 NAT──► 互联网
```

### 1. 国外出口 B（exit）

```bash
wm create-exit
#   A 可达的 B 公网/中转地址：B 的公网IP或域名（NAT 机填中转入口IP）
#   WireGuard 监听端口：默认 51820（swgp 模式下这是 B 本机内部口，一般回车）
#   混淆方式：swgp+mimic（推荐）
#   swgp-go 线上端口（A 连这个）：⚠ NAT 机务必填「转发段内的空闲端口」，别用默认 51821
#   swgp 模式：zero-overhead-2026（默认）
#   其余回车 → 复制输出的 WMGF1: 出口接入码
```

### 2. 国内网关 A（relay）

```bash
wm import-exit-code
#   粘贴 B 的出口接入码
#   A 公网IP（客户端连接本网关的地址）、客户端 WG 入口端口（默认 51820）
#   → 自动建到 B 的混淆隧道并启动
wm test exit-relay        # 验证 A↔B：应 0% 丢包、真实延迟（~跨境 RTT）
```

> `wm test` 走隧道**真 ping 对端 B**。若 100% 丢包，多半是 swgp「线上端口」不在 B 的 NAT 转发段内——换一个**确认转发**的空闲端口在 B 上重建 `create-exit`、A 重新 `import-exit-code`。

### 3. 客户端（出二维码）

```bash
wm add-client exit-relay phone     # 或：菜单 13 → 1) 新增客户端
# 自动生成 .conf + 终端二维码（按需自动装 qrencode），手机 WireGuard 直接扫码
wm list-clients exit-relay
wm del-client  exit-relay phone
```

客户端连上后，公网 IP 应变为 **B 的出口 IP**（`curl ifconfig.me` 验证）、可正常访问境外站点即全局出口生效。

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
wm set-pool ix 18300-18399        # 设置端口池
wm set-pool ix                    # 留空=清除，恢复手动指定
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

`create-transit` / `create-exit` 时选 **IP 版本** `4 / 6 / dual`。选 `6`/`dual` 会为 WG 隧道分配 IPv6 虚拟网（如 `fd88:6d6d::/64`）。

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

- 公网入口/网关：重新解析端点主机，变化时 `wg set ... endpoint` 热更新；
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
| `wm create-transit` / `import-code` | IX 中转：建线路+生成接入码 / 公网入口导入 |
| `wm create-exit` / `import-exit-code` | 全局出口：B 建混淆出口+生成接入码 / A 导入并建隧道 |
| `wm add-client <网关> <名>` | A：生成客户端 WG 配置 + 二维码 |
| `wm list-clients [网关]` / `del-client <网关> <名>` | 客户端列出 / 删除 |
| `wm start\|stop\|restart [ID]` | 启停线路（两端均需 WG+Mimic） |
| `wm delete-line <ID>` | 删除整条线路（保留同机其它线路；`WMF_DELETE_YES=1` 跳过确认） |
| `wm list-profiles` / `show-config [ID]` / `show-port-map [ID]` | 线路列表 / 配置 / 端口地图 |
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
| `wm set-mtu <ID> <MTU>` / `automtu <ID>` / `set-xdp-mode <ID> [skb\|native]` | 调参 / 自动探 MTU / XDP 模式 |
| `wm install-all\|install-mimic\|install-swgp\|install-deps\|compat` | 安装 / 兼容性 |
| `wm update-mimic [版本]` | 升级 mimic 到 apt 最新或指定版本（重载模块 + 重启线路） |
| `wm upgrade-script` / `uninstall` / `purge` | 维护（`upgrade-script` 只更新 wm 脚本，不动 mimic） |

---

## XDP 模式与 MTU

- **XDP 模式全自动**：脚本读 `/sys/class/net/<网卡>/device/driver` 识别网卡。`virtio_net` 自动用 `skb`；其它网卡默认 `native`，起不来则自动清理残留 XDP 程序并回退 `skb`。可手动覆盖：`wm set-xdp-mode <ID> [skb|native]`。
- **MTU**：Mimic 每包多占约 12 字节，WG MTU 建议 **1420**（IPv4）/ **1408**（IPv6/dual）；丢包多可 `wm set-mtu <ID> 1380` 两端同改，或 `wm automtu <ID>` 自动探测（换中转线路后两端各跑一次即自适应）。

---

## 故障排查

| 现象 | 排查 |
|------|------|
| WG 不握手（`wg show` 无 handshake） | 确认对端能到 `端点:WG端口`；**云安全组对 WG 端口 TCP+UDP 都放行**；两端 Mimic 均 active |
| **能连但卡 / 客户端不显示延迟** | 多半是**中转线路丢包**：`wm test <ID>` 看真实丢包；>10% 就 `wm set-endpoint` 换中转或开 `autoswitch` |
| 全局出口 `wm test` 100% 丢包 | swgp「线上端口」不在 B 的 NAT 转发段内（A 发包到不了 B）→ 换确认转发的空闲端口重建 `create-exit`；`ss -ulnp \| grep <端口>` 看 B 是否真在监听 |
| swgp `Exec format error` / 端口不监听 | `wm install-swgp`（v1.1.0 起自动校验 ELF 并自愈损坏二进制）；`journalctl -u wg-mimic-swgp@<ID>` 看启动日志 |
| 隧道握手成功但 ping 不通（全局出口） | relay 全局出口需到对端 mesh IP 的隧道路由（v1.1.0 已自动加）；`ip route get <对端mesh IP>` 应 `dev wm-<ID>` 而非物理网卡 |
| 客户端连上但不出网 | 确认 A 已开 `ip_forward`、relay 出网 NAT 生效；`curl ifconfig.me` 看是否变 B 的 IP |
| 新增客户端不出二维码 | v1.1.0 起自动装 `qrencode`；非 apt 环境直接复制 `.conf` 文本导入 App |
| IX 侧 mimic 不匹配（`mimic show <网卡>` 无连接） | NAT 机器 `filter = local=` 须用网卡真实内网 IP（脚本自动）；可 `MIMIC_LOCAL_IP` 覆盖 |
| mimic 模块缺失 | `wm install-mimic`；Secure Boot 需入册 MOK；内核与头文件不匹配需 `reboot` |
| MTU 异常/大包不通 | nft `forward` 链已自动 **MSS 钳制**到隧道 MTU；仍异常可 `wm set-mtu <ID> 1380`（两端）或 `wm automtu <ID>` |

诊断命令：`wm diagnose <ID>`（OS/内核/BTF/mimic/ip_forward 预检 + health）、`wm test <ID>`（隧道丢包）、`wg show`、`mimic show <网卡>`、`journalctl -u wg-mimic-swgp@<ID>`。

---

## 安全

- 接入码含 WG 组网私钥、混淆 PSK 与落地信息，**按密钥对待、勿公开**；泄露后用 `wm rotate-keys` 轮换密钥并重新导入。
- 运行时密钥/配置/接入码存于 `/etc/wg-mimic-fabric/`（不在仓库内）；本仓库不含任何真实密钥或 IP。
- 主备/中转切换是脚本管理的线路级操作，不接管全局防火墙；`wm` 仅维护自己的 nft 表 `wg_mimic_fabric`。
- `wm purge` 删除全部配置/密钥/接入码/服务（含 mimic 系统包，`WMF_PURGE_NO_MIMIC=1` 可保留）。

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `WMF_TAG=v1.1.1` | 安装/升级时指定版本 |
| `WMF_REPO` | GitHub 仓库（默认 `ike-sh/wg-mimic-fabric`） |
| `WMF_SKIP_MIMIC=1` | 跳过 mimic 自动安装 |
| `WMF_AUTO_MIMIC=0` | `install-wm-cli` 时不自动装 mimic |
| `WMF_UPGRADE_YES=1` / `WMF_PURGE_YES=1` / `WMF_UNINSTALL_YES=1` / `WMF_DELETE_YES=1` | 跳过相应确认 |
| `WMF_PURGE_NO_MIMIC=1` | purge 时保留 mimic 系统包 |
| `WMF_GITHUB_MIRRORS=url,...` | GitHub 下载镜像（国内网络） |
| `MIMIC_UPSTREAM_TAG` | 源码编译 mimic 的版本（默认 `v0.7.0`） |
| `MIMIC_LOCAL_IP` | 覆盖 IX/出口侧 Mimic 绑定的本机 IP |

---

## License

MIT
