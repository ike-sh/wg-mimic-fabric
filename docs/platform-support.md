# 平台支持说明

## 兼容性等级

| 等级 | 发行版 | 说明 |
|------|--------|------|
| **recommended** | Debian 13, Ubuntu 24.04 | `apt install mimic mimic-dkms` |
| **good** | Debian 12, Arch | .deb 或 AUR |
| **conditional** | RHEL/CentOS/Rocky/Alma 9, Fedora | 需内核 ≥6.1，常需 elrepo；无官方 RPM |
| **experimental** | Alpine, OpenWrt | 源码编译；建议 Forwarder 旁路 |
| **unsupported** | 内核 < 6.1 | Mimic 无法运行 |

运行 `wm compat` 查看本机评级。

## CentOS / RHEL 类

默认 RHEL 9 内核为 5.14，**不满足 Mimic 要求**。

推荐方案（按优先级）：

1. 换 **Debian 13 / Ubuntu 24.04** VPS
2. 使用 **Forwarder 旁路**（RouterOS + Linux Forwarder + Linux Server）
3. **elrepo kernel-ml** 升级至 6.1+ 后源码编译 mimic（自行承担 DKMS 风险）

```bash
wm install-deps   # 打印 dnf/elrepo 指引
```

## Alpine

- 无 `mimic-dkms`，musl 环境需源码编译
- 建议 `make CHECKSUM_HACK=kprobe`
- **生产环境不推荐**；测试可用

```bash
wm install-deps   # 打印 apk 依赖
```

## OpenWrt

- Mimic `openwrt` 分支为实验性
- 路由器侧推荐：**只跑 WG**，旁路 Linux Forwarder 跑 Mimic

```bash
wm create-forwarder
```

见 [forwarder.md](forwarder.md)。
