# 平台支持说明

## 兼容性等级

| 等级 | 发行版 | 说明 |
|------|--------|------|
| **recommended** | Debian 13, Ubuntu 24.04 | `apt install mimic mimic-dkms` |
| **good** | Debian 12, Arch | .deb 或 AUR |
| **conditional** | RHEL/CentOS/Rocky/Alma 9, Fedora | 需内核 ≥6.1，常需 elrepo；无官方 RPM |
| **unsupported** | Alpine | `wm` 依赖 systemd，不支持 Alpine/OpenRC |
| **unsupported** | OpenWrt | `wm` 依赖 systemd，不提供路由器/Forwarder 模式 |
| **unsupported** | 内核 < 6.1 | Mimic 无法运行 |

运行 `wm compat` 查看本机评级。

## CentOS / RHEL 类

默认 RHEL 9 内核为 5.14，**不满足 Mimic 要求**。

推荐方案（按优先级）：

1. 换 **Debian 13 / Ubuntu 24.04** VPS
2. **elrepo kernel-ml** 升级至 6.1+ 后源码编译 mimic（自行承担 DKMS 风险）

```bash
wm install-deps   # 打印 dnf/elrepo 指引
```

## Alpine

- 当前安装器和运行单元依赖 systemd，Alpine/OpenRC 不受支持，安装器会直接拒绝执行。
- 请改用 Debian 13 / Ubuntu 24.04，或自行维护独立的 OpenRC 适配（本项目不提供）。

## OpenWrt

- 当前 `wm` 使用 systemd、nftables 与常规 Linux 文件布局，不支持直接安装到 OpenWrt。
- 如路由器只承担客户端接入，请把 `relay` 部署在独立的 Debian/Ubuntu Linux 网关上。
