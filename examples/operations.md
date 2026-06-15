# wg-mimic-fabric 运维示例（v0.6）

## 依赖

```bash
# Debian 13 / Ubuntu 24.04（内核 ≥ 6.1）
apt install wireguard-tools mimic mimic-dkms python3 nftables
modprobe mimic
```

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
# 仅装 wm（跳过 mimic）：WMF_SKIP_MIMIC=1 sudo bash install.sh install-wm-cli
```

## IX / 落地侧（nat-transit）

```bash
wm create-transit
# 填：公网入口可达的 IX 地址、WG 端口(默认51820)、落地 IP/端口
# 复制输出的 WMGF1: 接入码

wm start ix-nat
wm show-code ix-nat
wm health ix-nat
```

## 公网入口（nat-ingress）

```bash
wm import-code
# 粘贴接入码；为每条规则分配客户端入口端口

wm start ix-nat-ingress
wm show-port-map ix-nat-ingress
wm health ix-nat-ingress
```

## 多规则

```bash
wm add-rule ix-nat            # IX 新增落地规则（已自动刷新接入码，密钥不变）
wm show-code ix-nat           # 复制最新接入码
# 公网入口：wm import-code 粘贴新码 → 重启（密钥不变，不会断流）
wm list-rules ix-nat
```

> 改规则**不要**用 `rotate-keys`（那会轮换密钥并重启 IX，仅密钥泄露时才用）。
> `add-rule/edit-rule/delete-rule` 已自动重生成接入码；需要手动再生用 `wm refresh-code`。

## 验证

```bash
wm diagnose ix-nat
wg show wm-ix-nat             # WG 握手与流量
mimic show -c eth0           # Mimic 连接状态
ping -c3 10.88.0.2           # 入口 ping IX 虚拟 IP
wm rotate-keys ix-nat        # 密钥泄露后轮换密钥（会重启IX，公网入口需重新 import-code）
WMF_PURGE_YES=1 wm purge     # 完全清理
```

## 故障排查

| 现象 | 处理 |
|------|------|
| WG 不握手 | 确认入口能到 `IX_ENDPOINT_HOST:WG_PORT`；两端 Mimic 均 active |
| Intel 网卡丢包 | `wm set-xdp-mode <ID> skb` 后 `wm restart <ID>` |
| mimic 模块缺失 | `apt install mimic-dkms && modprobe mimic` |
| 客户端连不上 | `wm show-port-map`，确认 `client_port` 已放行、IX 落地可达 |
| MTU 异常 | `wm set-mtu <ID> 1420`（有额外封装再减 12） |
