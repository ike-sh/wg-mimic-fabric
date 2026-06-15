# Forwarder 旁路模式

当客户端 **无法运行 Mimic**（RouterOS、Windows、老系统等）时，在局域网内放一台 **Linux Forwarder**：

```text
客户端 WG ──UDP──► Forwarder:监听端口
                      │ nft DNAT
                      ▼
                 Mimic 伪 TCP ──► 远端 Server WG
```

## 部署步骤

### 1. 远端 Server（Linux）

```bash
wm create-server
wm start my-tunnel
```

服务端 Mimic filter：`local=<公网IP>:51820`

### 2. Forwarder（Linux，与客户端同网段）

```bash
wm install-deps    # 确认 Debian/Ubuntu + mimic
wm create-forwarder
wm start my-forwarder
```

交互填写：
- **监听端口**：如 `1234`（客户端 WG Endpoint 指向 `Forwarder_IP:1234`）
- **服务端 IP/端口**：远端 WG 公网地址

Forwarder 自动配置：
- `nft` DNAT：`UDP 1234 → Server:51820`
- `ip_forward=1`
- Mimic：`remote=Server:51820`，默认 `xdp_mode=native`

### 3. 客户端（RouterOS 等）

WireGuard Peer Endpoint → `Forwarder内网或公网IP:1234`

**无需在客户端安装 Mimic。**

## 注意事项

- Forwarder 与 Server **都要跑 Mimic**
- Forwarder 官方建议 `xdp_mode=native`；Intel 网卡丢包改 `skb`
- 先在不启 Mimic 情况下测通 UDP 转发，再加 Mimic
- 详见 [mimic-as-forwarder.md](https://github.com/hack3ric/mimic/blob/master/docs/mimic-as-forwarder.md)
