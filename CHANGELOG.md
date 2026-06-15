# Changelog

## [0.6.13] - 2026-06-15

### Changed

- 交互菜单「规则管理」进入后**先自动列出所有线路及其规则**，不必预先知道线路 ID；只有一条线路时自动选中，多条再让你选——解决「不知道该填哪个线路 ID」

## [0.6.12] - 2026-06-15

### Added

- 交互菜单「规则管理」新增 **edit（编辑现有规则）** 入口：可直接改备注/中转端口/落地/协议（之前只有 增/删/池，要改规则只能删了重加）；进入规则管理时线路 ID 留空默认唯一线路

## [0.6.11] - 2026-06-15

### Added（防呆）

- **WG 监听端口 vs 端口池防呆**：`create-transit` 设了端口池后，若 WG 监听端口不在池范围内（商家常只放行池内端口，否则公网入口连不上 IX），**警告并改提示从池内选端口**；首条规则中转端口从池分配时**自动避开 WG 端口**，并禁止中转端口与 WG 端口相同。`pool_alloc_port` 新增 reserve 参数；`add-rule` 同样避开 WG 端口

### Changed

- `create-transit` 的「公网入口可达的 IX 公网地址」**不再用 curl 探测的出网 IP 作默认值**（NAT 机上那不是入口可达地址，易误填）——改为必填、无默认；探测 IP 默认仅保留在公网入口侧 `import-code`

## [0.6.10] - 2026-06-15

### Fixed

- **配端口池时 `create-transit`/`add-rule` 误报「端口 X 不在端口池内」**（X 明明在池内）：`pool_contains` 用 `expand_port_pool | grep -qxF`，`grep -q` 命中首个端口即退出并关闭管道，左侧 `expand_port_pool` 在 `set -o pipefail` 下收到 SIGPIPE → 整条管道返回非 0 → 误判。属时序竞争（缓冲快的机器不必现，真机慢必现，区间首端口最易触发）。改为**纯 bash 匹配，无管道/无 grep**

## [0.6.9] - 2026-06-15

### Fixed

- **公网入口隧道起不来的真因**：WireGuard 接口名取自 `wm-<线路ID>`，入口线路 `ix-nat-ingress` → `wm-ix-nat-ingress` 共 **17 字符 > Linux 接口名上限 15（IFNAMSIZ）**，`wg-quick` 直接失败（IX 的 `wm-ix-nat` 9 字符正常）。`wg_iface_for` 现在**超过 15 字符就用哈希压到 `wm-<11hex>`**；并通过 per-profile drop-in **覆盖 tunnel 单元的 ExecStart** 指向该短接口的 conf（systemd 实例仍按线路ID，改动面最小）

### Added

- `create-transit` / `import-code` 末尾**询问「现在就启动该线路吗？[Y/n]」并默认自动 `wm start`**（之前必须手动 start，易遗漏）
- 交互菜单「启动/停止线路」回车默认**唯一线路**（不再因留空报「无效的 PROFILE_ID」）

## [0.6.8] - 2026-06-15

### Fixed

- **隧道从未启动的真凶**：systemd 单元 `ExecStart=/usr/bin/mimic` 把路径写死，但部分发行版（如 Debian）mimic 装在 `/usr/sbin/mimic` → 服务 `203/EXEC` 失败、`journalctl` 报 `Unable to locate executable '/usr/bin/mimic'`，mimic 根本没跑（手动 `mimic run` 却完全正常）。改为**自动探测 mimic / wg-quick / modprobe 的真实绝对路径**（新增 `resolve_bin`：PATH + 常见目录），不再写死
- mimic 单元 `Type=notify` → **`Type=simple`**（不依赖 mimic 的 sd_notify 支持）
- `wm start` 现在每次**重新生成 systemd 单元**（让此修复对已装机器在 start 时即生效，无需完整重装），并**校验 mimic 服务真的 active**；若 native XDP 挂载失败（如 virtio_net + GRO），**自动回退 skb 重试**，仍失败则提示用 `journalctl` 排查

### Note

- 真机定位过程：0.6.7 已修正"IX filter 用网卡真实 IP"（mimic 精确匹配）；本版补上 systemd 单元路径这一**真正阻塞点**——之前所有"不通"都源于 mimic 服务 203/EXEC 从未启动

## [0.6.7] - 2026-06-15

### Fixed

- **隧道仍不通的真正根因**（与 mimic#43 同款）：Mimic 做**精确 IP 匹配**，XDP/TC 看到的是**网卡上的真实 IP**；NAT/浮动IP 机器网卡上是内网 IP，而 0.6.6 用的 `local=0.0.0.0` 通配**只有 2025-11 之后的 mimic 才支持**（mimic#32），用户的 mimic 0.7.0 不识别 → IX 侧 mimic 不匹配 → server 端 `mimic show -c` 无连接、入口一直 SYN 重试。改为 **IX filter 用自动探测的 `WAN_IFACE` 网卡真实 IP**（精确匹配、全版本通用）；可用 `MIMIC_LOCAL_IP` 覆盖；`0.0.0.0` 仅作探测失败兜底
- 去掉 0.6.6 加的 `handshake=0`，与 mimic 维护者确认可用的 server 配置（默认 active）对齐

### Note

- 仍需确认云安全组放行 IX 公网/浮动IP 的 **TCP + UDP `WG_PORT`**（mimic 链路上是 TCP，netfilter 入站识别为 TCP、出站为 UDP，两者都要放行）

## [0.6.6] - 2026-06-15

### Fixed

- **连通性根因**：IX(`nat-transit`) 的 Mimic filter 之前用 `local=<公网IP>:端口`，在 NAT / 浮动IP 机器上网卡只有内网 IP，XDP/TC 永远匹配不到该公网 IP → 隧道不通。改为 **`local=0.0.0.0:端口`（通配本机 IP，NAT 安全）** 并加 **`handshake=0`** 让 IX 侧被动（由公网入口主动发起 fake-TCP 握手，对齐 mimic 官方 WireGuard server 范例）；公网入口仍 `remote=<IX公网IP>:端口` 主动
- 移除 `create-transit` 中已无意义且误导的「IX 本机公网 IP（Mimic local 绑定）」提示（Mimic 改用 `0.0.0.0` 通配，不再需要单独绑定 IP）
- `create-transit` / `import-code` 公网地址默认值改回 **curl 出网 IP**（NAT 云机网卡多为内网 IP 不可作公网地址），网卡 IP 仅作辅助提示；浮动公网 IP 仍需手填

### Note

- Mimic 在**两端都运行**、各自双向 encode(TC) + decode(XDP)，是正常设计而非配置错误

## [0.6.5] - 2026-06-15

### Fixed

- `create-transit` / `import-code` 的公网 IP 默认值改用**本机网卡全局 IPv4**（新增 `detect_local_ipv4`，即 Mimic 可绑定、客户端可达的入口 IP），不再默认 `curl` 探测的**出网 IP**——多 IP / NAT 机器上出口 IP ≠ 入口 IP，旧默认常需手动改正；curl 出口 IP 降级为参考提示

## [0.6.4] - 2026-06-15

### Fixed

- `import-code` 导入时「客户端入口端口」默认值改为该规则的**落地端口**（多数场景客户端与落地用同一端口号），直接回车即可，仍可手动指定
- `create-transit` / `import-code` 完成后，若检测到 mimic 内核模块因运行内核与已编译模块不一致而未加载（`mimic_needs_reboot`），主动给出**重启提示**并可选「开机自动续跑 `wm start <ID>`」；此前仅 `wm start` 阶段提示，create/import 阶段易被忽略

## [0.6.3] - 2026-06-15

### Added

- **商家中转端口池**：IX(`nat-transit`) 线路新增可选 `TRANSIT_PORT_POOL`（如 `40000-40010,40050`）。设置后 `create-transit` / `add-rule` 自动从池中分配下一个空闲中转端口作为默认值（可手动覆盖），并强制所选端口必须落在池内、禁止与同线路其它规则重复；池用尽时给出明确提示
- 新增 `wm set-pool <ID> [端口池]`（留空=清除端口池，恢复每条规则手动指定）；`wm list-rules` 显示端口池用量（共/已用/剩）；交互菜单「规则管理」新增 `pool` 操作
- 端口池为 IX 侧分配状态，**不进入接入码、不影响公网入口**；留空时行为与 0.6.2 完全一致

### Fixed

- `add-rule` / `edit-rule` 现在检测并拒绝同一线路内重复的中转端口（此前可能生成冲突的 nft DNAT）

## [0.6.2] - 2026-06-15

### Added

- `wm start` 检测到 mimic 内核模块需重启才能生效（DKMS 为非运行内核编译）时，**交互询问是否现在重启并开机自动继续**：写入一次性 `wg-mimic-resume` systemd 单元，开机 `modprobe mimic` + 续跑 `wm start <ID>` 后自删
- 新增 `wm resume`（一次性恢复命令，主要由上面的开机单元调用）

## [0.6.1] - 2026-06-15

### Fixed

- `create-transit` / `import-code` 交互按回车取默认值时报 `val: unbound variable`：`prompt` 与 `prompt_port` 因内部 `local val` 同名，`printf -v` 跨函数回写错位，`set -u` 下调用方变量未绑定。重命名内部变量（`__prompt_val` / `_pval`）修复；并对 `read </dev/tty` 失败兜底默认值。

## [0.6.0] - 2026-06-15

### Changed（Breaking — 重构）

- **组网模型重构**：借鉴 `ix-transit-fabric`，改为「公网入口 ⇄ IX 经 **WireGuard** 点对点组网」，**Mimic 把 WG 的 UDP 伪装成 TCP** 穿透封锁；IX 经 nft 转发到落地
- **角色**：`nat-transit`（IX/落地侧，WG 监听 + 生成接入码）与 `nat-ingress`（公网入口，导入接入码）
- **接入码 `code_schema=5`**（`WMGF1:`）：含 WG 组网密钥、虚拟 IP、`transit_port`、落地 `IP/端口`、`MTU` 与 **多规则数组**；公网入口单向导入（IX 预生成入口私钥写入码）
- **多转发规则**：一条 WG 隧道承载多条规则，规则存于 `profiles/<id>/rules/<rule_id>.env`；`add-rule`/`edit-rule`/`delete-rule`/`enable-rule`/`disable-rule`/`apply-rules`
- 新命令：`create-transit` / `import-code` / `show-port-map` / `list-rules` 等
- 移除 v0.5 的 `transit-code`(schema3) / relay / WG server-client / forwarder 旁路流程
- 复用 v0.5 的 Mimic 多发行版自动安装、systemd drop-in 修复、镜像下载/升级
- 新增 `.gitattributes`（`*.sh eol=lf`）；`scripts/smoke.sh` 纯函数冒烟测试

### Added — 进阶特性

- **IPv6 / 双栈**：`IP_VERSION=4|6|dual`，WG 隧道可分配 IPv6 虚拟网；nft 按落地地址族（解析后）emit `ip`/`ip6` DNAT/masquerade；接入码携带 IPv6 网段/虚拟 IP
- **DDNS**：`ddns-enable|ddns-disable|ddns-status|ddns-refresh` + systemd timer（每 3 分钟）；公网入口端点域名变化热更新 `wg set endpoint`，落地域名渲染 nft 时自动解析跟随
- **主备**：线路分组 `LINE_GROUP/LINE_ROLE/LINE_PRIORITY`；`set-group`/`list-groups`/`switch-line`/`primary-backup-check`/`health-all`，手动切换（不自动切线）
- nft 渲染对落地**域名自动解析为 IP**（域名落地可用）

## [0.5.1] - 2026-06-15

### Added

- 公网入口 `import-transit-code` 自动安装并启用 **Mimic**（`filter=local=公网IP:端口`，UDP 伪装 TCP）
- IX 中转仍为纯 nft 转发（无需 mimic）

## [0.5.0] - 2026-06-15

### Changed（Breaking）

- **菜单与主流程对齐 ix-transit**：IX `create-transit` 生成接入码 → 公网入口 `import-transit-code`
- 移除菜单中的 WG 服务端 / 客户端 / Forwarder / 手动 relay
- 接入码 `code_schema=3`（`transit-code`）
- 纯转发推荐 `WMF_SKIP_MIMIC=1` 安装

## [0.4.0] - 2026-06-15

### Added

- **`wm create-relay`**：纯 nft 端口转发（`ROLE=relay`），对标 ix-transit 公网入口→IX→落地
  - `RELAY_KIND=ingress|transit`，支持 `tcp` / `udp` / `both`
  - 落地无需 WG / Mimic
- 文档 `docs/transit-topology.md`

## [0.3.4] - 2026-06-15

### Fixed

- DKMS 优先为**当前运行内核** `uname -r` 编译 mimic，避免头文件装到新内核但尚未 reboot 导致 modprobe 失败
- 头文件与运行内核不匹配时给出明确 reboot 指引

## [0.3.3] - 2026-06-15

### Fixed

- 修复 `create-server` 在 `set -u` 下 `iface: unbound variable`（`apply_mimic_conf_iface` 同行 local 声明）
- Debian/Ubuntu 安装 mimic-dkms 前自动安装 `linux-headers-$(uname -r)` 并触发 `dkms autoinstall`

## [0.3.2] - 2026-06-15

### Changed

- **多发行版 mimic 自动安装**（三级回退）：
  1. 包管理器（apt / pacman / AUR）
  2. GitHub Releases `.deb`（Debian/Ubuntu 无 apt 包时）
  3. 源码编译（Fedora / RHEL / Alpine / openSUSE 等）
- 自动安装基础构建依赖（wireguard-tools、clang、libbpf 等）
- 环境变量 `MIMIC_UPSTREAM_TAG`（默认 `v0.7.0`）

## [0.3.1] - 2026-06-15

### Added

- **默认自动安装 mimic**：`bootstrap` / `install-all` / `install-wm-cli` 在 Debian/Ubuntu 上 `apt install mimic mimic-dkms`
- `wm install-mimic`、`wm install-all` 命令
- `WMF_SKIP_MIMIC=1` 跳过 mimic 自动安装

## [0.3.0] - 2026-06-15

### Added

- **Forwarder 旁路模式**：`wm create-forwarder`（RouterOS/非 Linux 客户端 + Linux 中转）
- nft DNAT + ip_forward 自动配置
- **CentOS/RHEL/Alpine** 支持指引：`wm install-deps`
- **系统兼容性报告**：`wm compat`（`wm diagnose` 内含 OS 评级）
- BTF 检测、发行版分级（recommended / conditional / experimental）
- 文档：`docs/forwarder.md`、`docs/platform-support.md`

### Changed

- `diagnose` 增强多发行版预检

## [0.2.0] - 2026-06-15

### Added

- IPv6 / dual-stack 隧道（`IP_VERSION=4|6|dual`，配对码 schema 2）
- `wm refresh-code` — 轮换客户端密钥并重新生成配对码
- `wm purge` — 完全清理配置与服务
- `wm upgrade-script` — 从 GitHub 升级 install.sh
- `wm set-mtu` / `wm set-xdp-mode` — 运行时调参
- `wm apply-nft-all` — 多线路 nft 规则合并重建
- 同网卡多线路 Mimic filter 自动合并

### Changed

- 配对码升级为 `code_schema=2`（兼容 schema 1 导入）
- nft 防火墙改为全量重建，支持多服务端线路

## [0.1.0] - 2026-06-15

### Added

- MVP：WireGuard + Mimic 双端隧道编排
- `wm` CLI 与交互菜单
- 服务端 `create-server` + WMGF1 配对码
- 客户端 `import-code`（含预生成客户端密钥）
- systemd 单元：`wg-mimic-mimic@` + `wg-mimic-tunnel@`
- `health` / `diagnose` / `set-peer`
- `bootstrap.sh` 一行安装骨架
- 示例配置与运维文档
