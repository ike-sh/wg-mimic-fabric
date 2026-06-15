# wg-mimic-fabric 运维示例

## 依赖

```bash
# Debian / Ubuntu
apt install wireguard-tools mimic mimic-dkms python3 nftables
modprobe mimic
```

## 安装

```bash
# 本地开发（自动装 mimic，Debian/Ubuntu）
sudo bash install.sh install-all

# 仅装 wm，不装 mimic
WMF_SKIP_MIMIC=1 sudo bash install.sh install-wm-cli

# 一行安装（需推送到 GitHub 后）
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

## 服务端

```bash
wm create-server
# 复制输出的 WMGF1: 配对码

wm start my-tunnel
wm health my-tunnel
wm show-code my-tunnel
```

## 客户端

```bash
wm import-code
# 粘贴 WMGF1: 配对码

wm start my-tunnel-client
wm health my-tunnel-client
```

## 验证

```bash
wm diagnose my-tunnel
ping -c 3 10.66.66.1    # 从客户端 ping 服务端隧道 IP
mimic show -c eth0      # 查看 Mimic 连接状态
wm refresh-code my-tunnel   # 泄露后轮换密钥
wm set-xdp-mode my-tunnel skb   # Intel 网卡丢包时
wm upgrade-script
WMF_PURGE_YES=1 wm purge    # 完全清理
```

## 故障排查

| 现象 | 处理 |
|------|------|
| Intel 网卡丢包 | profile 设 `MIMIC_XDP_MODE=skb` 后 `wm restart <id>` |
| WG 握手失败 | 确认防火墙 TCP+UDP 51820 放行 |
| mimic 模块缺失 | `apt install mimic-dkms && modprobe mimic` |
| MTU 问题 | IPv6 用 1408，IPv4 用 1420 |
