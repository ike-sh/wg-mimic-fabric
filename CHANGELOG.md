# Changelog

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
