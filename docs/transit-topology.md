# 公网入口 → IX 中转 → 落地

对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric)：**IX 生成接入码 → 公网入口粘贴接入码**。落地无需 WG / Mimic，仅 `IP:端口`。

## 架构

```text
客户端 → 公网入口 Debian  公网IP:LOCAL_PORT
       → IX 中转 Debian    IX_IP:TRANSIT_PORT
       → 落地              LANDING_IP:PORT
```

## 1. IX 中转机（Debian 12）

```bash
# 纯转发可跳过 mimic
WMF_SKIP_MIMIC=1 curl -fsSL .../bootstrap.sh | sudo bash

sudo wm create-transit
# IX 中转监听端口: 40000
# IX 对入口可达 IP: 10.x.x.x（IX 网段）
# 落地 IP / 端口

sudo wm start ix-transit
# 复制 WMGF1: 接入码
```

## 2. 公网入口（Debian 12/13）

```bash
WMF_SKIP_MIMIC=1 curl -fsSL .../bootstrap.sh | sudo bash

sudo wm import-transit-code
# 粘贴 IX 接入码
# 公网入口端口: 30000（客户端连此口）

sudo wm start ix-transit-ingress
```

## 3. 客户端

连接：`公网入口IP:30000`

## 命令

| 命令 | 机器 |
|------|------|
| `wm create-transit` | IX |
| `wm import-transit-code` | 公网入口 |
| `wm show-code` / `refresh-code` | IX |

## 前提

公网入口须能路由到 IX 机的 `transit_reach_host`（IX 网段互通）。

## 变更记录

v0.5.0 移除 WG/Mimic/Forwarder 菜单，统一为接入码流程。
