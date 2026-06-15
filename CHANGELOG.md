# Changelog

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
