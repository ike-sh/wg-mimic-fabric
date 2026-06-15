# wg-mimic-fabric

**当前版本**：[`v0.5.0`](https://github.com/ike-sh/wg-mimic-fabric/releases/tag/v0.5.0)  
**仓库**：https://github.com/ike-sh/wg-mimic-fabric  
**定位**：公网入口 + IX 组网 + 落地转发，运维体验对标 [ix-transit-fabric](https://github.com/ike-sh/ix-transit-fabric)。

**纯 nft 端口转发** + **公网入口 Mimic（UDP→伪 TCP）**。IX 机生成接入码，公网入口粘贴接入码。落地无需 WG / wm。

```text
客户端 ──Mimic(伪TCP)──► 公网入口 ──明文 UDP/TCP──► IX ──► 落地:端口
```

---

## 架构

```text
客户端 → 公网入口:LOCAL_PORT → IX:TRANSIT_PORT → 落地:PORT
```

---

## 安装

```bash
# IX 中转机可跳过 mimic
WMF_SKIP_MIMIC=1 curl -fsSL .../bootstrap.sh | sudo bash

# 公网入口需要 mimic（不要 SKIP）
curl -fsSL https://raw.githubusercontent.com/ike-sh/wg-mimic-fabric/main/scripts/bootstrap.sh | sudo bash
```

---

## 快速部署

### IX 中转机

```bash
wm create-transit    # 生成 WMGF1 接入码
wm start <线路ID>
```

### 公网入口

```bash
wm import-transit-code
wm start <线路ID>-ingress
```

详见 [docs/transit-topology.md](docs/transit-topology.md)

---

## 常用命令

| 命令 | 说明 |
|------|------|
| `wm` | 交互菜单 |
| `wm create-transit` | IX：创建中转 + 接入码 |
| `wm import-transit-code` | 公网入口：导入接入码 |
| `wm health <ID>` | 健康检查 |
| `wm upgrade-script` | 升级脚本 |

---

## 升级

```bash
wm upgrade-script
```

---

## License

MIT
