# Changelog

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
