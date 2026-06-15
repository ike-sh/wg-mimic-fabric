# 设计：A↔B 混淆组网 + 客户端全局出口（obfuscation mesh gateway）

状态：草案（待评审） · 目标版本：v1.1.0 · 关联：wg-mimic-fabric ≥ v1.0.3

## 1. 背景与目标

现状：wg-mimic-fabric 做「公网入口(nat-ingress) ↔ IX(nat-transit)」的**端口转发**中转（WG + mimic 伪 TCP）。

新增目标（科学上网/全局出口）：

```
客户端(官方WG/小火箭/mihomo/sing-box)
   → A(国内网关)  ──[ WG → swgp-go → mimic ]过墙──>  B(国外出口)
                                                        → 出网(全局 masquerade)
```

- **mimic**：把 WG 的 UDP 伪装成 TCP，抗 ISP 的 UDP QoS 限速。
- **swgp-go**（database64128/swgp-go）：混淆/加密 WG 载荷，使其「不像 WireGuard」，抗 GFW 的 DPI 指纹识别与主动探测。
- 客户端 ↔ A 是国内这跳，**不过墙、不混淆**，用标准 WireGuard；混淆只发生在 **A ↔ B**。

非目标：不替换/不破坏现有端口转发模型；不在手机端跑 mimic/swgp-go（手机做不到，也不需要）。

## 2. 角色

| 角色 | 机器 | 职责 |
|------|------|------|
| `exit` | B（国外） | 对 A 的 WG 服务端 + swgp-go server + mimic + 出网 masquerade；生成接入码 |
| `relay` | A（国内） | 连 B（WG→swgp-go→mimic）+ 客户端 WG 服务端 + 路由客户端→B；生成客户端配置 |
| 客户端 | 任意 | 标准 WireGuard（官方 App / 小火箭 / mihomo / sing-box） |

与现有 `nat-transit`/`nat-ingress` **并列**，同机可共存（不同 profile/line）。

## 3. 架构（两段 WireGuard）

```
[客户端] --标准WG(国内,不混淆)--> [A relay] --WG→swgp-go→mimic(过墙)--> [B exit] --masq--> 互联网
   wg-cli                          wg-cli-srv + wg-uplink                  wg-uplink-srv
```

- **客户端 ↔ A**：标准 WG。A 是客户端的 WG 服务端（独立 WG 接口，如 `wm-<relay>-cli`）。
- **A ↔ B**：混淆 WG（独立 WG 接口，如 `wm-<relay>-up`）。A 拨 B；mimic 在该链路上伪 TCP，swgp-go 混淆载荷。
- **A 路由**：客户端子网流量 → 转发进 A↔B 上行接口；B 对其 masquerade 出网。

## 4. 混淆层（四选一，由 B 设定、随接入码下发）

| 模式 | 链路 | 适用 |
|------|------|------|
| `direct` | 裸 WG | 优质国际线路、UDP 不被封 |
| `mimic` | WG→mimic | 仅抗 UDP QoS |
| `swgp` | WG→swgp-go | 仅抗 DPI |
| `swgp+mimic` | WG→swgp-go→mimic | 抗审查 + 抗 QoS（推荐，论坛同款） |

## 5. 端口编排（A↔B，以 `swgp+mimic` 为例）

A 侧（出站）：
```
wg-uplink(本机 UDP) → swgp-go client(本机监听 127.0.0.1:WGP_LOCAL)
                    → 发往 B:WGP_PORT (UDP)
                    → mimic(filter remote=B:WGP_PORT) 伪TCP → 网络
```
B 侧（入站）：
```
mimic(filter local=B网卡IP:WGP_PORT) 还原UDP → swgp-go server(:WGP_PORT)
   → wg-uplink-srv(本机 WG 监听) → WireGuard
```

关键：**mimic 的 filter 对准 swgp-go 端口**（线上跑的是 swgp-go 的 UDP），WG 仅本机环回到 swgp-go。`direct`/`mimic` 模式下退化为现有逻辑（filter 对 WG 端口）。

## 6. swgp-go 集成

- 安装：优先 GitHub release 预编译二进制（`database64128/swgp-go`，按 arch 选）；回退 `go install`/源码。装到 `/usr/local/bin/swgp-go`。
- 服务：systemd `wg-mimic-swgp@<id>.service`（`ExecStart=swgp-go -c /etc/wg-mimic-fabric/swgp/<id>.json`）。
- 配置：A=client、B=server，JSON 含 `proxyListen/proxyMode/proxyPSK` + WG endpoint 映射。
- 模式：`zero-overhead`（默认，XOR，快）/ `paranoid`（AEAD，更隐蔽、有开销）。
- 密钥：`proxyPSK`（B 生成）随接入码下发给 A。

## 7. 接入码扩展（向后兼容）

在现有 `WMGF1`/`code_schema` 基础上**新增可选字段**（升 `code_schema=6`，`parse_code` 仍兼容 5）：

```
role            = "nat-exit-code"        # 区别于 nat-transit-code
exit_mode       = "global" | "forward"
obfs_mode       = direct|mimic|swgp|swgp+mimic
swgp_mode       = zero-overhead|paranoid
swgp_psk        = <base64>
swgp_port       = <int>
client_wg_*     = A 侧客户端 WG 服务端参数（子网、端口）
```

旧 schema-5 接入码与现有 import-code 流程**完全不受影响**。

## 8. 客户端管理（A 上）

- `wm add-client <名>`：分配客户端 WG IP，生成标准 `.conf`：
  ```ini
  [Interface]
  PrivateKey=...; Address=10.89.0.X/32; DNS=<隧道可达DNS>; MTU=<自动>
  [Peer]
  PublicKey=<A客户端WG公钥>; Endpoint=A国内IP:CLI_PORT; AllowedIPs=0.0.0.0/0; PersistentKeepalive=25
  ```
  并用 `qrencode` 输出二维码（缺失则仅打印 conf）。
- `wm list-clients` / `wm del-client <名>`。
- `AllowedIPs` 默认 `0.0.0.0/0`（全局），可改为分流网段。

## 9. MTU 自动计算

| 段 | 默认 MTU |
|----|------|
| A↔B 上行（direct/mimic/swgp/叠加） | 1420 / 1400 / 1380 / 1330 |
| 客户端 WG（其负载需再进 A↔B 隧道） | 上行 MTU 再减 ~60 → 建议 1280 |

A 上对转发流量做 **MSS 钳制**（已在 v1.0.2 实现，`rt mtu` 自适应），TCP 自动协商，UDP 建议小包。

## 10. 路由与 NAT

- **A(relay)**：`ip_forward=1`；nft：客户端子网 `oifname wm-<up>` 转发放行 + masquerade 到上行 WG IP；客户端入口端口 input 放行。
- **B(exit)**：`ip_forward=1`；nft：relay/客户端子网 `masquerade` 到默认出口网卡；WG/swgp/mimic 端口 input 放行（TCP+UDP）。

## 11. 命令面

- B：`wm create-exit`（建出口、出接入码）
- A：`wm import-exit-code`（建网关）、`wm add-client`/`list-clients`/`del-client`
- 复用：`start/stop/restart/health/test/diagnose/set-mtu/upgrade-script/uninstall/purge`、`set-endpoint`/`autoswitch`（A↔B 也可换中转）。

## 12. 隔离与不干涉（关键约束）

- 新角色独立 profile/WG 接口/systemd 实例；
- nft 同表 `wg_mimic_fabric`，但**只做增量、按 ROLE 分支**，现有 `nat-transit`/`nat-ingress` 渲染**逐字不变**；
- 接入码**向后兼容**；
- 用 `scripts/smoke.sh` 现有 nft/wgconf 断言做**回归测试**，任何对旧模型输出的改动都会触发测试失败。

## 13. 分阶段交付

1. **Phase 1**：swgp-go 安装 + systemd；A↔B 混淆链（exit/relay，先无客户端入口）；`obfs_mode` 四选一；自动 MTU。先验证「A↔B 过墙稳」。
2. **Phase 2**：客户端 WG 入口 + `add-client`/二维码 + 全局出口路由/NAT。
3. **Phase 3**：分流示例（mihomo/sing-box 规则）、文档、smoke 用例补充。

## 14. 风险与测试

- 多层叠加调试难 → 每层可单独开关；`wm test` 测隧道丢包；关闭某层对比定位。
- 远程不易测 → 每步 `bash -n` + `smoke.sh` 回归；分阶段，先在非关键机验证。
- swgp-go 为用户态 Go 进程（吃 CPU、单点）→ 弱鸡注意；提供 `direct`/`mimic` 退化选项。
- Secure Boot / 内核 < 6.1 等 mimic 既有约束沿用。

## 15. 默认值（已确认）

- `obfs_mode = swgp+mimic`，`swgp_mode = zero-overhead`，`exit_mode = global`。
- **客户端 DNS = `1.1.1.1`（经隧道解析），可覆盖**；避免 DNS 泄漏与 GFW 污染。
- 平台优先 Debian/Ubuntu（swgp-go 跨平台二进制可用）。

## 16. 未决问题（实现期锁定）

- swgp-go 配置格式以其当前 release 为准（Phase 1 实现时锁定字段名/版本）。
- 可选增强（非默认、后续）：在 B 上跑内置 DNS 解析器（用 B 的 mesh IP 当客户端 DNS），省去 B→公共解析器的明文那跳。
