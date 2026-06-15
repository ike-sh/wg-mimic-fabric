# wg-mimic-fabric

**当前版本**：[`v0.4.0`](https://github.com/ike-sh/wg-mimic-fabric/releases/tag/v0.4.0)  
**仓库**：https://github.com/ike-sh/wg-mimic-fabric  
**定位**：WireGuard + [Mimic](https://github.com/hack3ric/mimic) 伪 TCP 隧道编排器，对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric) 的运维体验。

管理 **WireGuard 隧道 + Mimic UDP→TCP 混淆**，以及 **纯端口中继（relay）** 对标 ix-transit 三段转发。

**不负责**：安装 Mimic 本体（仅检测并指引）、代理内核、全局防火墙接管。

---

## 架构

```text
客户端 WG ──UDP──► Mimic(TC egress) ──伪TCP──► 公网 ──► Mimic(XDP ingress) ──UDP──► 服务端 WG
```

---

## 依赖

- Linux 内核 ≥ 6.1
- `wireguard-tools`
- `mimic` + `mimic-dkms`（[安装说明](https://github.com/hack3ric/mimic#installation)）
- `python3`（配对码编解码）
- `systemd`

`bootstrap` / `install-all` 会**自动安装 mimic**，策略因发行版而异：

| 发行版 | 安装方式 |
|--------|----------|
| Debian 13 / Ubuntu 24.04 | `apt install mimic mimic-dkms` |
| Debian 12 等 | GitHub Releases `.deb` → 失败则源码 |
| Arch | `pacman` / `yay` AUR → 失败则源码 |
| Fedora / RHEL / Rocky / openSUSE | 源码编译 |
| Alpine | 源码编译（kprobe 模式） |

硬性要求：**内核 ≥ 6.1**。RHEL 9 默认 5.14 需先升内核。

```bash
# 跳过 mimic 自动安装
WMF_SKIP_MIMIC=1 curl -fsSL .../bootstrap.sh | sudo bash

# 指定 mimic 版本
MIMIC_UPSTREAM_TAG=v0.7.0 wm install-mimic
```

---

## 安装

### 本地 / 开发

```bash
git clone https://github.com/ike-sh/wg-mimic-fabric.git
cd wg-mimic-fabric
sudo bash install.sh install-all
wm
```

### 一行安装（发布后）

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

---

## 快速开始

### 1. 服务端

```bash
wm create-server
# 记录 WMGF1: 配对码

wm start my-tunnel
wm health my-tunnel
```

### 2. 客户端

```bash
wm import-code
# 粘贴配对码

wm start my-tunnel-client
wm health my-tunnel-client
```

### 3. 验证

```bash
ping 10.66.66.1   # 从客户端 ping 服务端隧道 IP
```

---

## 常用命令

| 命令 | 说明 |
|------|------|
| `wm` | 交互菜单 |
| `wm create-forwarder` | Forwarder 旁路（RouterOS 等） |
| `wm create-relay` | 纯转发中继（公网入口/IX→落地，无需 WG） |
| `wm install-deps` | 按发行版打印 mimic 依赖指引 |
| `wm compat` | 操作系统兼容性报告 |
| `wm create-server` | 创建服务端线路 |
| `wm import-code` | 客户端导入配对码 |
| `wm start\|stop\|restart <ID>` | 启停线路 |
| `wm list-profiles` | 列出线路 |
| `wm show-code <ID>` | 显示配对码 |
| `wm refresh-code <ID>` | 刷新配对码（轮换客户端密钥） |
| `wm set-mtu <ID> <MTU>` | 修改隧道 MTU |
| `wm set-xdp-mode <ID> [skb\|native]` | Mimic XDP 模式 |
| `wm apply-nft-all` | 重建 nft 防火墙 |
| `wm upgrade-script` | 升级管理脚本 |
| `wm set-peer <ID> <PUBKEY>` | 服务端更新客户端公钥 |
| `wm health [ID]` | 健康检查 |
| `wm diagnose [ID]` | 诊断 |

平台支持见 [docs/platform-support.md](docs/platform-support.md)；Forwarder 见 [docs/forwarder.md](docs/forwarder.md)。

---

## 配置目录

```text
/etc/wg-mimic-fabric/
├── profiles/<id>.env      # 线路配置
├── codes/<id>.code        # 配对码缓存
└── keys/<id>/             # WG 私钥

/etc/mimic/<iface>.conf    # Mimic 配置（自动生成）
/etc/wireguard/wm-<id>.conf
```

---

创建服务端时可选择 **IP 版本**：`4` / `6` / `dual`

| 模式 | 隧道 MTU 建议 |
|------|---------------|
| IPv4 | 1420 |
| IPv6 / dual | 1408 |

---

## 配对码

格式：`WMGF1:` + Base64URL(JSON)

含服务端公钥、endpoint、隧道 IP 分配、预生成客户端密钥（导入后两端密钥匹配，无需手动 set-peer）。

> 配对码含私钥材料，勿公开传播。泄露后请重建线路。

---

## 与 ix-transit-fabric 对比

| | ix-transit-fabric | wg-mimic-fabric |
|--|-------------------|-----------------|
| 隧道 | EasyTier | WireGuard |
| 混淆 | 无 | Mimic 伪 TCP |
| 配对 | IXTF1 接入码 | WMGF1 配对码 |
| CLI | `ix` | `wm` |

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `WMF_TAG` | 安装时指定版本 |
| `WMF_REPO` | GitHub 仓库 |
| `WMF_UPGRADE_YES=1` | 升级跳过确认 |
| `WMF_PURGE_YES=1` | purge 跳过确认 |
| `WMF_NO_MENU=1` | bootstrap 后不自动进菜单 |

---

## 许可

MIT — 见 [LICENSE](LICENSE)
