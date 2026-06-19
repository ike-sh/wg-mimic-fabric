# wg-mimic-fabric

> 基于 WireGuard 的组网与全局出口编排工具，集成 Mimic 伪 TCP 伪装与 swgp-go 流量混淆，通过单一命令 `wm` 完成搭建与全生命周期运维。

| | |
|------|------|
| **版本** | `v1.4.7` |
| **仓库** | https://github.com/ike-sh/wg-mimic-fabric |
| **许可** | MIT |

---

## 快速开始

在**两端服务器**上分别执行一键安装（场景一：IX 与公网入口；场景二：国内网关 A 与国外出口 B）。需 **root**、内核 **≥ 6.1**，脚本会自动安装并按当前内核编译 mimic 模块：

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装完成后运行 `wm` 进入交互菜单，按下文 [场景一：IX 中转组网](#场景一ix-中转组网) 或 [场景二：混淆全局出口](#场景二混淆全局出口) 操作；升级使用 `wm upgrade-script`。

---

## 概述

wg-mimic-fabric 以 **WireGuard** 为底层组网，使用 **Mimic** 将 WireGuard 的 **UDP 流量伪装为 TCP**，以穿透针对 UDP 的封锁与 QoS 限速；并可按需叠加 **swgp-go** 提供第二层流量混淆。全部能力收敛为一个全局命令 `wm`（交互式菜单与 CLI 子命令完全等价），覆盖以下两类典型场景：

1. **IX 中转组网**：公网入口 ⇄ IX / 落地节点。IX 侧基于 **nftables** 将流量转发至落地服务，适用于端口转发与中转加速。
2. **混淆全局出口**：国内网关 A ⇄ 国外出口 B。本地设备接入 A 后，全部流量经隧道由 B 出网（全局代理），支持 `swgp+mimic` 双层混淆与移动端扫码接入。

```text
场景一 · 中转组网：客户端 ──[Mimic 伪 TCP 承载的 WireGuard]──► 公网入口 ⇄ IX ──[nft]──► 落地:端口
场景二 · 全局出口：手机 / 设备 ──[WG]──► 国内网关 A ──[swgp+mimic 隧道]──► 国外出口 B ──► 互联网
```

---

## 目录

- [快速开始](#快速开始)
- [核心组件](#核心组件)
  - [Mimic](#mimic)
  - [swgp-go](#swgp-go)
- [系统要求](#系统要求)
- [功能概览](#功能概览)
- [安装](#安装)
- [场景一：IX 中转组网](#场景一ix-中转组网)
- [场景二：混淆全局出口](#场景二混淆全局出口)
- [多转发规则与端口池](#多转发规则与端口池)
- [线路质量与中转切换](#线路质量与中转切换)
- [IPv6 / 双栈](#ipv6--双栈)
- [DDNS（域名自动刷新）](#ddns域名自动刷新)
- [主备切换](#主备切换)
- [命令参考](#命令参考)
- [XDP 模式与 MTU](#xdp-模式与-mtu)
- [故障排查](#故障排查)
- [安全](#安全)
- [环境变量](#环境变量)
- [许可](#许可)

---

## 核心组件

### Mimic

[Mimic](https://github.com/hack3ric/mimic) 是基于 **eBPF（XDP + TC）** 的流量伪装工具。它在网卡收发路径上就地改写报文头，使 WireGuard 的 **UDP** 报文在链路上呈现为 **TCP** 特征，从而规避运营商与防火墙对 UDP 的封锁、限速及 DPI 检测。

**工作原理**

- **发送方向（TC egress）**：将出站的 WireGuard UDP 报文改写为「伪 TCP」（携带合法外观的 TCP 头与序号）。
- **接收方向（XDP ingress）**：将入站的「伪 TCP」还原为 UDP，交还内核的 WireGuard。
- 该过程对 WireGuard 完全透明——WireGuard 仍按 UDP 收发；**隧道两端均须运行 Mimic**，各自完成双向 encode/decode。
- 通过 **filter** 指定需处理的流：`filter = local=IP:端口`（本机监听侧，如 IX 或出口 B）或 `filter = remote=IP:端口`（主动连接侧，如公网入口或网关 A）。

**关键特性**

- **精确 IP 匹配**：Mimic 在 XDP/TC 层观察到的是网卡上的真实目的 IP。在 NAT / 端口转发机器上，公网流量进入网卡前已被改写为内网 IP，因此监听侧的 `filter = local=` 必须使用网卡的真实（内网）IP，而非公网 IP——本工具已自动处理。
- **两种 XDP attach 模式**：`native`（驱动层，性能最优，需驱动支持）与 `skb`（通用，适配任意网卡，性能略低）。`virtio_net` 等虚拟网卡通常仅支持 `skb`。

> 链路层呈现为 TCP，但连接发起行为仍属 UDP：netfilter 在入站方向识别为 TCP、出站方向识别为 UDP。因此**云安全组需对 WireGuard 端口同时放行 TCP 与 UDP**。

### swgp-go

[swgp-go](https://github.com/database64128/swgp-go) 是用户态的 **WireGuard 流量混淆代理**。它在 WireGuard 之外叠加一层基于 PSK（预共享密钥）的 **UDP 加密 / 混淆**，将 WireGuard 的 UDP 流量转换为无显著特征的 UDP，进一步增强对特征型 DPI 的抵抗能力。

完整链路为 **WG → swgp-go → Mimic**：swgp-go 先将 WireGuard 流量混淆为另一种 UDP，Mimic 再在最外层将其伪装为 TCP。双层叠加（`swgp+mimic`）为抗封锁能力最强的模式，用于「混淆全局出口」场景。

- **按需自动安装**：无需手动部署。工具从 GitHub Release 选取**静态 `linux-x86-64-v2`** 构建（兼容性最广、无 glibc 依赖、不要求 AVX2），下载后执行 **ELF 强制校验**，文件损坏时**自动重新安装**。
- **混淆方式**：`direct`（不混淆）/ `mimic`（仅伪 TCP）/ `swgp`（仅 swgp 混淆）/ `swgp+mimic`（双层，默认推荐）。
- **swgp 模式**：`zero-overhead-2026`（默认，零额外开销）/ `paranoid-2026`（更强混淆）。

> **NAT VPS 注意事项**：`swgp+mimic` 模式下，网关 A 经公网连接的是出口 B 的 **swgp 对外端口**（而非 WireGuard 端口）。若 B 为 NAT 机器，该端口**必须落在服务商转发的端口段内**，否则 A 的报文无法抵达 B。可使用 `wm install-swgp` 单独安装或修复 swgp-go。

---

## 系统要求

### Mimic（隧道两端均需安装）

| 项目 | 要求 |
|------|------|
| 内核 | **Linux ≥ 6.1**（Mimic 依赖较新的 eBPF / kfunc，低于 6.1 无法运行） |
| BTF | 需 `/sys/kernel/btf/vmlinux`（`CONFIG_DEBUG_INFO_BTF=y`）；精简内核无 BTF 时需使用 `kprobe` 变体源码编译 |
| 内核模块 | `mimic`（内核态，经 **DKMS** 按当前内核编译）与 `mimic` CLI（用户态） |
| 网卡 | 任意（`skb` 模式通用）；物理网卡支持 `native` 时性能更优 |
| Secure Boot | 若启用，DKMS 编译的模块需经 **MOK 签名 / 入册**，否则内核将拒绝加载 |

### wg-mimic-fabric 本体

- `bash`、`python3`、`wireguard-tools`（`wg` / `wg-quick`）、`nftables`、`curl`、`iproute2`
- `systemd`（线路、Mimic、swgp、DDNS、自动切换均以 systemd 单元运行）
- 全局出口场景额外依赖 `swgp-go`、`qrencode`（生成客户端二维码）、`zstd`（解压 swgp Release），均自动安装
- **root** 权限

### 发行版兼容评级（执行 `wm compat` 查看本机评级）

| 评级 | 发行版 | 说明 |
|------|--------|------|
| 推荐 | **Debian 13 / Ubuntu 24.04** | 官方 mimic `.deb` 与 apt，内核 ≥ 6.1 |
| 良好 | Arch | AUR：`mimic-bpf` |
| 有条件 | Fedora / RHEL 系 | 默认内核常 < 6.1，需 elrepo kernel-ml 或改用 Debian / Ubuntu，mimic 需源码编译 |
| 实验 | Alpine / OpenWrt | 无 DKMS，需源码编译（Alpine 使用 `kprobe`），不建议用于生产 |

> 安装脚本会自动安装 mimic（apt → GitHub `.deb` → 源码编译，三级回退），并按当前内核经 DKMS 编译模块。

---

## 功能概览

本工具将「WireGuard 组网 + Mimic 伪装（+ swgp 混淆）+ nft 转发」的搭建与运维完全自动化，统一为一个 `wm` 命令：

- **一端创建线路并生成「接入码」，另一端粘贴接入码即自动完成组网**：中转场景使用 `create-transit` / `import-code`，出口场景使用 `create-exit` / `import-exit-code`。
- 自动处理 NAT / 端口转发机器的 Mimic 绑定、网卡 XDP 模式（`virtio` 自动回退 `skb`）、systemd 单元、防火墙放行与空闲 mesh 网段分配。
- 全局出口场景额外自动安装 swgp-go 与 qrencode，自动为 relay 网关配置策略路由及对端 mesh 路由，并一键生成客户端 `.conf` 与二维码。
- 内置 **IPv4 / IPv6 双栈**、落地**域名 DDNS**、线路**主备**、**隧道丢包自检（`wm test`）**、**中转线路切换 / 自动切换**与**自动 MTU 探测（`wm automtu`）**。

### 角色

| 角色 | 部署位置 | 职责 |
|------|----------|------|
| `nat-transit` | IX / 落地侧 | WireGuard 监听 + Mimic + nft 转发至落地 + 生成接入码 |
| `nat-ingress` | 公网入口 | 导入接入码 + WireGuard 接入 + Mimic + 对客户端开放入口端口 |
| `exit` | 国外出口 B | WireGuard 监听 + swgp-go / Mimic 混淆 + 出网 NAT + 生成出口接入码 |
| `relay` | 国内网关 A | 导入出口接入码 + 连接 B + 全局策略路由 + 客户端接入（生成二维码） |

**接入码**（`WMGF1:` 前缀，`code_schema=6`）封装 WireGuard 组网密钥、虚拟 IP、端口、混淆参数（swgp 模式 / PSK / 端口）及落地与规则信息，由一端单向生成、另一端导入。

---

## 安装

```bash
# 隧道两端均需执行；内核要求 ≥ 6.1，脚本将自动安装 mimic 并按当前内核编译模块
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

安装完成后，通过全局命令 `wm` 操作（无参数进入交互菜单）。常用辅助命令：`wm compat` 查看本机兼容评级，`wm install-deps` 查看依赖指引，`wm upgrade-script` 升级脚本（仅更新 wm 脚本本体，不改动 mimic）。

---

## 场景一：IX 中转组网

适用于将公网入口转发至 IX / 落地服务（端口转发、中转加速）。

```text
客户端
  → 公网入口 公网IP:客户端入口端口(client_port)
  → 公网入口 nft DNAT
  → WireGuard 隧道（入口 10.88.0.1 ⇄ IX 10.88.0.2；Mimic 将 WG 的 UDP 伪装为 TCP）
  → IX 虚拟IP 10.88.0.2:中转端口(transit_port)
  → IX nft DNAT
  → 落地 landing_host:landing_port
```

### 1. IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填写：公网入口可达的 IX 公网地址 / 中转 IP、WG 端口、IP 版本（4/6/dual）、（可选）端口池、首条落地 IP / 端口
# 复制输出的 WMGF1: 接入码
```

### 2. 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴接入码；为每条规则分配「客户端入口端口」（默认与落地端口一致，回车采用默认值）
```

再次导入将进入**更新模式**（同步规则集并保留已选入口端口）。两步结束时均会询问是否立即 `wm start`。

### 3. 客户端

连接 `公网入口IP:<客户端入口端口>`（执行 `wm show-port-map <ID>-ingress` 查看完整端口地图）。

更多细节参见 [docs/transit-topology.md](docs/transit-topology.md) 与 [examples/operations.md](examples/operations.md)。

---

## 场景二：混淆全局出口

适用于「国内网关 A → 国外出口 B 全局代理」：本地设备接入 A，全部流量经 `swgp+mimic` 混淆隧道由 B 出网。

```text
手机 / 电脑 ──[WG]──► 国内网关 A(relay)
                        │  WG → swgp-go → Mimic（双层混淆，经公网连接 B 的 swgp 端口）
                        ▼
                     国外出口 B(exit) ──[出网 NAT]──► 互联网
```

### 1. 国外出口 B（exit）

```bash
wm create-exit
#   B 的公网 / 中转地址：B 的公网 IP 或域名（NAT 机器填中转入口 IP）
#   WireGuard 监听端口：默认 51820（swgp 模式下为 B 本机内部端口，通常回车）
#   混淆方式：swgp+mimic（推荐）
#   swgp 对外端口（A 连接此端口）：NAT 机器须填写「转发段内的空闲端口」，请勿沿用默认 51821
#   swgp 模式：zero-overhead-2026（默认）
#   其余回车 → 复制输出的 WMGF1: 出口接入码
```

### 2. 国内网关 A（relay）

```bash
wm import-exit-code
#   粘贴 B 的出口接入码
#   A 的公网地址（客户端连接本网关的地址）、客户端 WG 入口端口（默认 51820）
#   → 自动建立至 B 的混淆隧道并启动
wm test exit-relay        # 验证 A↔B：应为 0% 丢包、真实跨境 RTT 延迟
```

> `wm test` 经隧道**实际 ping 对端 B**。若出现 100% 丢包，通常是 swgp 对外端口不在 B 的 NAT 转发段内——请更换一个**确认已转发**的空闲端口，在 B 上重新执行 `create-exit`，并在 A 上重新执行 `import-exit-code`。

### 3. 客户端（生成二维码）

```bash
wm add-client exit-relay phone     # 或：菜单 5 → 1) 新增客户端
# 自动生成 .conf 与终端二维码（按需自动安装 qrencode），移动端 WireGuard 直接扫码导入
wm list-clients exit-relay
wm del-client  exit-relay phone
```

客户端连接成功后，其公网 IP 应变更为 **B 的出口 IP**（可通过 `curl ifconfig.me` 验证），能正常访问境外站点即表示全局出口生效。

---

## 多转发规则与端口池

单条 WireGuard 隧道可承载多条规则，每条规则拥有独立的 `transit_port` 与落地目标：

```bash
wm list-rules <ID>
wm add-rule <ID>                 # 新增规则（自动重新生成接入码，密钥不变）
wm edit-rule <ID> <规则ID>
wm delete-rule <ID> <规则ID>
wm enable-rule|disable-rule <ID> <规则ID>
wm refresh-code <ID>             # 按当前规则刷新接入码（不更换密钥、不中断流量）
wm apply-rules <ID>              # 重建 nft
```

> 新增 / 修改 / 删除规则均会**自动重新生成接入码且不更换密钥**——公网入口重新执行 `import-code` 即可，隧道不中断。
> 仅在**密钥泄露**时使用 `wm rotate-keys <ID>` 轮换密钥（将重启 IX，两端短暂中断）。

### 中转端口池（可选）

IDC / 运营商分配的 IX 端口通常数量有限。为 IX 线路设置**中转端口池**后，`create-transit` 与 `add-rule` 将自动从池中取下一个空闲端口作为默认中转端口，并强制端口落在池内、禁止重复；池耗尽时报错。端口池仅作为 IX 侧的分配状态，**不写入接入码、不影响公网入口**。

```bash
wm set-pool transit 18300-18399   # 设置端口池
wm set-pool transit               # 留空以清除，恢复手动指定
```

---

## 线路质量与中转切换

许多线路「可连接但卡顿 / 客户端不显示延迟」的根因是**中转线路丢包**（隧道之上的网络质量问题，而非组网配置错误）。可使用以下工具自检与切换：

```bash
wm test <ID> [包数]               # 实测隧道真实丢包 / 延迟并给出质量判定（默认 100 包）
wm set-endpoint <ID> <中转IP>      # 切换该线路使用的 IX 公网 / 中转地址（入口侧即时生效）
```

多中转**自动切换**（应对中转线路抖动丢包）：

```bash
wm set-endpoints <入口线路> IP1,IP2,IP3   # 设置候选中转列表（均指向同一 IX）
wm autoswitch <入口线路> [阈值%]           # 测量当前丢包，超过阈值（默认 10%）时自动探测并切换至最优候选
wm autoswitch-enable <入口线路>           # 启用定时自动切换（每 5 分钟）
wm autoswitch-disable <入口线路>
```

> 判定标准：丢包 ≤ 2% 为良好 / ≤ 10% 为一般 / > 10% 建议更换中转。比较中转线路应使用 `wm test`（经隧道实测），而非对中转网关直接 `ping`（网关回应 ICMP 正常并不代表其转发不丢包）。

---

## IPv6 / 双栈

执行 `create-transit` / `create-exit` 时选择 **IP 版本** `4 / 6 / dual`。选择 `6` 或 `dual` 将为 WireGuard 隧道分配 IPv6 虚拟网段（如 `fd88:6d6d::/64`）。

- **落地 IPv6**：规则落地填写 IPv6 地址（如 `2606:4700::1111`），nft 自动采用 `ip6` DNAT / masquerade。
- **落地域名**：填写域名即可，nft 渲染时自动解析（A / AAAA），并随 DDNS 刷新。
- 规则协议族由落地地址族决定；MTU 建议 IPv6 / dual 使用 **1408**。

---

## DDNS（域名自动刷新）

当 IX 端点或落地为**域名**时，可在 IP 变化时自动跟随：

```bash
wm ddns-enable      # 启用每 3 分钟定时刷新（systemd timer）
wm ddns-refresh     # 手动刷新一次
wm ddns-status / wm ddns-disable
```

- 公网入口 / 网关：重新解析端点主机，变化时通过 `wg set ... endpoint` 热更新；
- 落地域名：渲染 nft 时重新解析，自动跟随。

---

## 主备切换

将多条线路（如经由不同 IX 的入口线路）编入同一分组，在主备之间**手动**切换（与 ix-transit「不自动切换」的安全边界保持一致）：

```bash
wm set-group <ID> <组名> primary 100
wm set-group <ID2> <组名> backup 90
wm list-groups
wm primary-backup-check <组名>            # 查看各成员 health 与当前 active
wm switch-line <组名> <目标线路ID>         # 启用目标、停用同组其余线路并重建 nft
wm health-all
```

> 如需按丢包**自动**切换同一 IX 的多个中转入口，请使用 [线路质量与中转切换](#线路质量与中转切换) 中的 `autoswitch`。

---

## 命令参考

| 命令 | 说明 |
|------|------|
| `wm` | 交互菜单 |
| `wm create-transit` / `import-code` | IX 中转：创建线路并生成接入码 / 公网入口导入 |
| `wm create-exit` / `import-exit-code` | 全局出口：B 创建混淆出口并生成接入码 / A 导入并建立隧道 |
| `wm add-client <网关> <名>` | A：生成客户端 WireGuard 配置与二维码 |
| `wm list-clients [网关]` / `del-client <网关> <名>` | 客户端列出 / 删除 |
| `wm start\|stop\|restart [ID]` | 启停线路（两端均需 WG + Mimic） |
| `wm delete-line <ID>` | 删除整条线路（保留同机其余线路；`WMF_DELETE_YES=1` 跳过确认） |
| `wm list-profiles` / `show-config [ID]` / `show-port-map [ID]` | 线路列表 / 配置 / 端口地图 |
| `wm show-code [ID]` / `refresh-code [ID]` | 显示 / 按当前规则刷新接入码（不更换密钥，IX） |
| `wm rotate-keys [ID]` | 轮换入口密钥并刷新接入码（密钥泄露时使用，将重启 IX） |
| `wm list-rules\|add-rule\|edit-rule\|delete-rule\|enable-rule\|disable-rule\|apply-rules` | 规则管理 |
| `wm set-pool <ID> [端口池]` | IX 中转端口池（如 18300-18399；留空以清除） |
| `wm test [ID] [包数]` | 实测隧道丢包 / 延迟（判断中转质量） |
| `wm set-endpoint <ID> <中转IP>` | 切换该线路的 IX 公网 / 中转地址 |
| `wm set-endpoints <ID> ip1,ip2,..` / `autoswitch [ID] [阈值]` / `autoswitch-enable\|autoswitch-disable [ID]` | 候选中转与自动切换 |
| `wm ddns-enable\|ddns-disable\|ddns-status\|ddns-refresh` | DDNS |
| `wm set-group\|list-groups\|switch-line\|primary-backup-check\|health-all` | 主备 |
| `wm health [ID]` / `diagnose [ID]` | 健康检查 / 诊断 |
| `wm set-mtu <ID> <MTU>` / `automtu <ID>` / `set-xdp-mode <ID> [skb\|native]` | 调参 / 自动探测 MTU / XDP 模式 |
| `wm install-all\|install-mimic\|install-swgp\|install-deps\|compat` | 安装 / 兼容性 |
| `wm update-mimic [版本]` | 升级 mimic 至 apt 最新或指定版本（重载模块并重启线路） |
| `wm upgrade-script` / `uninstall` / `purge` | 维护（`upgrade-script` 仅更新 wm 脚本，不改动 mimic） |

---

## XDP 模式与 MTU

- **XDP 模式全自动**：脚本读取 `/sys/class/net/<网卡>/device/driver` 识别网卡。`virtio_net` 自动采用 `skb`；其余网卡默认 `native`，若无法启动则自动清理残留 XDP 程序并回退 `skb`。可手动覆盖：`wm set-xdp-mode <ID> [skb|native]`。
- **MTU**：Mimic 每包额外占用约 12 字节，WireGuard MTU 建议为 **1420**（IPv4）/ **1408**（IPv6 / dual）；丢包偏多时可执行 `wm set-mtu <ID> 1380` 两端同步修改，或使用 `wm automtu <ID>` 自动探测（更换中转线路后两端各执行一次即自适应）。

---

## 故障排查

| 现象 | 排查方向 |
|------|----------|
| WG 不握手（`wg show` 无 handshake） | 确认对端可达 `端点:WG端口`；**云安全组对 WG 端口需同时放行 TCP 与 UDP**；确认两端 Mimic 均为 active |
| **可连接但卡顿 / 客户端不显示延迟** | 多为**中转线路丢包**：执行 `wm test <ID>` 查看真实丢包；> 10% 时使用 `wm set-endpoint` 更换中转或启用 `autoswitch` |
| 全局出口 `wm test` 100% 丢包 | swgp 对外端口不在 B 的 NAT 转发段内（A 报文无法抵达 B）→ 更换确认已转发的空闲端口重建 `create-exit`；执行 `ss -ulnp \| grep <端口>` 确认 B 是否正在监听 |
| swgp `Exec format error` / 端口未监听 | 执行 `wm install-swgp`（v1.1.0 起自动校验 ELF 并自愈损坏二进制）；通过 `journalctl -u wg-mimic-swgp@<ID>` 查看启动日志 |
| 隧道握手成功但 ping 不通（全局出口） | relay 全局出口需配置到对端 mesh IP 的隧道路由（v1.1.0 起自动添加）；`ip route get <对端mesh IP>` 应指向 `dev wm-<ID>` 而非物理网卡 |
| 客户端已连接但不出网 | 确认 A 已启用 `ip_forward` 且 relay 出网 NAT 生效；通过 `curl ifconfig.me` 确认是否变更为 B 的 IP |
| 新增客户端不显示二维码 | v1.1.0 起自动安装 `qrencode`；非 apt 环境直接复制 `.conf` 文本导入 App |
| IX 侧 mimic 不匹配（`mimic show <网卡>` 无连接） | NAT 机器的 `filter = local=` 须使用网卡真实内网 IP（脚本自动处理）；可通过 `MIMIC_LOCAL_IP` 覆盖 |
| mimic 模块缺失 | 执行 `wm install-mimic`；Secure Boot 需入册 MOK；内核与头文件不匹配需 `reboot` |
| MTU 异常 / 大包不通 | nft `forward` 链已自动对 MSS 进行钳制（跟随隧道 MTU）；仍异常时执行 `wm set-mtu <ID> 1380`（两端）或 `wm automtu <ID>` |

诊断命令：`wm diagnose <ID>`（OS / 内核 / BTF / mimic / ip_forward 预检与 health）、`wm test <ID>`（隧道丢包）、`wg show`、`mimic show <网卡>`、`journalctl -u wg-mimic-swgp@<ID>`。

---

## 安全

- 接入码包含 WireGuard 组网私钥、混淆 PSK 与落地信息，**应按密钥同等对待、切勿公开**；泄露后使用 `wm rotate-keys` 轮换密钥并重新导入。
- 运行时密钥 / 配置 / 接入码存储于 `/etc/wg-mimic-fabric/`（不在仓库内）；本仓库不包含任何真实密钥或 IP。
- 主备 / 中转切换为脚本管理的线路级操作，不接管全局防火墙；`wm` 仅维护自有的 nft 表 `wg_mimic_fabric`。
- `wm purge` 将删除全部配置 / 密钥 / 接入码 / 服务（含 mimic 系统包，可通过 `WMF_PURGE_NO_MIMIC=1` 保留）。

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `WMF_TAG=v1.3.5` | 安装 / 升级时指定版本 |
| `WMF_REPO` | GitHub 仓库（默认 `ike-sh/wg-mimic-fabric`） |
| `WMF_SKIP_MIMIC=1` | 跳过 mimic 自动安装 |
| `WMF_AUTO_MIMIC=0` | 执行 `install-wm-cli` 时不自动安装 mimic |
| `WMF_UPGRADE_YES=1` / `WMF_PURGE_YES=1` / `WMF_UNINSTALL_YES=1` / `WMF_DELETE_YES=1` | 跳过相应确认 |
| `WMF_PURGE_NO_MIMIC=1` | purge 时保留 mimic 系统包 |
| `WMF_GITHUB_MIRRORS=url,...` | GitHub 下载镜像（适用于国内网络） |
| `MIMIC_UPSTREAM_TAG` | 源码编译 mimic 的版本（默认 `v0.7.0`） |
| `MIMIC_LOCAL_IP` | 覆盖 IX / 出口侧 Mimic 绑定的本机 IP |
| `WMF_NO_OFFLOAD_DISABLE=1` | 跳过自动关闭网卡硬件 offload（默认会关闭以兼容 Mimic） |

---

## 许可

本项目基于 [MIT 许可证](LICENSE) 发布。
