# Changelog

## [1.0.1] - 2026-06-15

### Added

- **`wm update-mimic [版本]`**：升级 mimic（此前装上后不会自动更新）。无参数走 apt `--only-upgrade` 到仓库最新；带版本号（如 `wm update-mimic v0.8.0`）走 GitHub `.deb`/源码按该版本安装。升级后自动停 mimic 服务、卸载/重载内核模块、并重启之前启用的线路使新版本生效。`wm upgrade-script` 仍只更新 wm 脚本本身、不动 mimic——两者分工明确。

## [1.0.0] - 2026-06-15

首个正式版。汇总 0.6.x 全部修复与特性，并完成一轮全项目审计（去死代码/修逻辑/补健壮性）与 README 重写。

### Audit / Fixed（正式版收尾）

- **去除死代码**：删除从未被调用的 `assume_yes()`；删除冗余且未被引用的 `scripts/fix-wm.sh`（功能与 `wm upgrade-script` 重复）。
- **`wm diagnose` 不再误报**：mimic ≥ 0.7 无 `run --check`，改为**先探测是否支持再调用**，否则打印配置路径跳过（消除 `[WARN] mimic --check 失败`）；内核模块判定改用 `awk $1=="mimic"` 精确匹配（修此前"已加载却报未加载"的误判）；diagnose 额外打印网卡驱动与 XDP 模式。
- 修正 `examples/operations.md` 中 `mimic show -c eth0` 的过时语法为 `mimic show <网卡>`，并补 `wm test`。
- 重写 `README.md`：先讲 **Mimic 的功能与系统要求**（eBPF/XDP 原理、内核 ≥6.1/BTF/DKMS、native/skb），再讲本脚本（角色/架构/部署/运维/故障排查）。

### Added

- **`wm test [线路] [包数]`**：一条命令测隧道**真实丢包/延迟**（ping 对端虚拟IP，默认 100 包）并给质量判定（≤2% 良好 / ≤10% 一般 / >10% 建议换中转）——快速判断"能连但卡/不显示延迟"是不是中转线路丢包。
- **`wm set-endpoint <线路> <中转IP>`**：一条命令切换该线路用的 IX 公网/中转地址。入口侧即时重写 mimic/wg 并重启、切换后顺带报一次丢包；IX 侧则刷新接入码提示重导。
- **自动切换**：`wm set-endpoints <入口线路> ip1,ip2,...` 设候选中转 → `wm autoswitch <线路> [阈值%]` 测当前丢包、超阈值(默认10%)自动探测并切到最优候选 → `wm autoswitch-enable/-disable` 定时(每5分钟)自动切换。专治中转线路波动丢包。

### Changed

- **交互菜单「规则管理」操作项改竖排**（1)新增 2)编辑 3)删除 4)设置端口池 回车)返回 各占一行）。

### Fixed

- **mimic 启动健壮性**：
  - 启动后用**轮询等待**（最多 ~8s，配合单元 `Restart=on-failure`）替代单次 `sleep 1` 检查，消除"mimic 仍未启动"的虚惊误报；
  - **检测到 virtio_net 网卡直接默认 XDP skb 模式**（`import-code` 与启动时），不再在不支持 native 的网卡上反复尝试 native、报错、甚至残留程序锁死线路；
  - 新增 `nic_driver`/`nic_prefers_skb`/`wait_mimic_active`/`force_iface_skb` 辅助；卸载时清理 autoswitch 定时器。

## [0.6.20] - 2026-06-15 (未发布，并入 1.0.0)

### Added

- **`wm test [线路] [包数]`**：一条命令测隧道**真实丢包/延迟**（ping 对端虚拟IP，默认 100 包）并给质量判定（≤2% 良好 / ≤10% 一般 / >10% 建议换中转）——快速判断"能连但卡/不显示延迟"是不是中转线路丢包。
- **`wm set-endpoint <线路> <中转IP>`**：一条命令切换该线路用的 IX 公网/中转地址。入口侧即时重写 mimic/wg 并重启、切换后顺带报一次丢包；IX 侧则刷新接入码提示重导。
- **自动切换**：`wm set-endpoints <入口线路> ip1,ip2,...` 设候选中转 → `wm autoswitch <线路> [阈值%]` 测当前丢包、超阈值(默认10%)自动探测并切到最优候选 → `wm autoswitch-enable/-disable` 定时(每5分钟)自动切换。专治中转线路波动丢包。

### Changed

- **交互菜单「规则管理」操作项改竖排**（1)新增 2)编辑 3)删除 4)设置端口池 回车)返回 各占一行，更清晰）。

### Fixed

- **mimic 启动健壮性**：
  - 启动后用**轮询等待**（最多 ~8s，配合单元 `Restart=on-failure`）替代单次 `sleep 1` 检查，消除"mimic 仍未启动"的虚惊误报；
  - **检测到 virtio_net 网卡直接默认 XDP skb 模式**（`import-code` 与启动时），不再在不支持 native 的网卡上反复尝试 native、报错、甚至残留程序锁死线路；
  - 新增 `nic_driver`/`nic_prefers_skb`/`wait_mimic_active`/`force_iface_skb` 辅助；卸载时清理 autoswitch 定时器。

## [0.6.19] - 2026-06-15

### Fixed

- **native XDP attach 失败后残留程序把线路弄成"仍未启动"死循环**：在不支持 native XDP 的网卡（如 virtio_net `ens5`）上 `set-xdp-mode native` / 启动时，native attach 失败会**残留一个 XDP 程序挂在网卡上**，导致随后连 skb 模式都 attach 不上 → `mimic@<iface> 仍未启动`、`wm health` 全 inactive，必须手动 `ip link set dev <iface> xdp off` 才能救活。
  - 新增 `detach_xdp`：清理网卡上残留的 XDP 程序（generic/native-drv/offload 三种模式都清）。
  - `ensure_mimic_service_up`：**首次 attach 前**与 **skb 回退前**都先 `detach_xdp`（回退前还会先 `systemctl stop` 彻底停掉失败单元），让 native→skb 回退能干净恢复、不再把线路弄挂；并新增"mimic 已在该网卡运行则直接返回"避免打扰共享网卡上的其它线路。
  - `stop_profile`：停止后若该网卡已无 mimic 运行，则 `detach_xdp` 让网卡保持干净，下次启动干净 attach。

## [0.6.18] - 2026-06-15

### Fixed

- **「刷新接入码」轮换密钥却不重启 IX → 公网入口重导后整体不通的真因**：菜单 8 / `refresh_code` 每次都会**轮换入口 WG 密钥对**（把新私钥写进接入码、新公钥写进 IX 的 `WG_PEER_PUBLIC_KEY`），但随后只调 `apply_profile_configs`（**仅重写 conf 文件**），从不重启正在运行的 IX 隧道。于是 IX 内核里仍是**旧** ingress 公钥，公网入口用接入码里的**新**私钥重导+重启后，两端公钥对不上 → WG 永远不握手 → 这条隧道上的**所有规则（含原来好用的）一起中断**。
  - **解耦**：`refresh-code`（菜单 8）改为**按当前规则刷新接入码、不换密钥、不重启**（改规则后用它即可，两端不断流）；密钥轮换拆到新命令 **`wm rotate-keys [ID]`**。
  - **修复轮换路径**：`rotate-keys` 在 `apply_profile_configs` 后，**若 IX 隧道在运行则 `restart_profile`**，让内核真正加载新的对端公钥；随后提示公网入口必须重新 `import-code`。
  - 修正 `README.md` / `examples/operations.md` 误导：改规则不需要（也不应）轮换密钥；`add-rule/edit-rule/delete-rule` 已自动重生成接入码。
  - 受影响用户**立即恢复**：在 IX 机执行 `wm restart ix-nat`（加载已写好的新对端公钥，握手即恢复）。

## [0.6.17] - 2026-06-15

### Fixed

- **菜单按线路操作前先列出线路、不再报「无效的 PROFILE_ID」**：之前「启动/停止/健康检查/显示接入码/刷新接入码/端口地图」（菜单 `3/4/5/7/8/9`）要手输线路 ID，直接回车/留空会报 `[ERROR] 无效的 PROFILE_ID` 并退出脚本（尤其菜单 `7/8` 即便只有一条线路也会失败）。现在统一改为：进入后**先列出所有线路（含角色 nat-transit/nat-ingress）**，只有一条时自动选中，多条再让你选（**回车=取消、返回菜单而非退出脚本**，无效 ID 也不再 die），与「规则管理」菜单的「先列出再选」体验一致

## [0.6.16] - 2026-06-15

### Fixed

- **公网入口可重复导入接入码以更新线路**：之前 IX 端改/增/删规则后，公网入口再次 `import-code` 会报「入口线路已存在」并被迫先 `wm stop` + 手动删除 profile。现在检测到入口线路已存在时**询问是否用新接入码更新**（默认是）——自动停旧线路、同步新接入码的规则集（删除 IX 已删的规则、新增 IX 新加的），并**保留本机已配置的公网IP/网卡与各规则已选的客户端入口端口**（只对新规则询问端口），最后重启线路

## [0.6.15] - 2026-06-15

### Changed

- **规则列表竖排显示**：`list-rules`（及交互菜单「规则管理」）每条规则改为字段分行展示（备注 / 启用 / 协议 / 中转 / 落地），不再挤在一行，更易读
- **规则增/改/删/启停后询问是否显示新接入码**：IX(`nat-transit`) 线路规则变更会自动重生成接入码，之前需手动 `wm show-code` 才看得到。现在变更后提示「现在显示更新后的接入码吗？[Y/n]」——选 Y 直接打印新接入码，公网入口可立即重新 `import-code`（无 tty 时跳过提问）

## [0.6.14] - 2026-06-15

### Fixed

- **菜单内「升级脚本」后自动重载**：之前菜单是长驻进程，升级只换了磁盘文件、内存里仍是旧代码（看起来"升级没生效、菜单没变"）。现在升级后 `exec` 重新加载 `wm`，新版本立即生效
- 规则管理操作改为**中文数字菜单**：`1)新增 2)编辑 3)删除 4)设置端口池 回车)返回`，不再用易困惑的 `add/del/pool/skip`

## [0.6.13] - 2026-06-15

### Changed

- 交互菜单「规则管理」进入后**先自动列出所有线路及其规则**，不必预先知道线路 ID；只有一条线路时自动选中，多条再让你选——解决「不知道该填哪个线路 ID」

## [0.6.12] - 2026-06-15

### Added

- 交互菜单「规则管理」新增 **edit（编辑现有规则）** 入口：可直接改备注/中转端口/落地/协议（之前只有 增/删/池，要改规则只能删了重加）；进入规则管理时线路 ID 留空默认唯一线路

## [0.6.11] - 2026-06-15

### Added（防呆）

- **WG 监听端口 vs 端口池防呆**：`create-transit` 设了端口池后，若 WG 监听端口不在池范围内（商家常只放行池内端口，否则公网入口连不上 IX），**警告并改提示从池内选端口**；首条规则中转端口从池分配时**自动避开 WG 端口**，并禁止中转端口与 WG 端口相同。`pool_alloc_port` 新增 reserve 参数；`add-rule` 同样避开 WG 端口

### Changed

- `create-transit` 的「公网入口可达的 IX 公网地址」**不再用 curl 探测的出网 IP 作默认值**（NAT 机上那不是入口可达地址，易误填）——改为必填、无默认；探测 IP 默认仅保留在公网入口侧 `import-code`

## [0.6.10] - 2026-06-15

### Fixed

- **配端口池时 `create-transit`/`add-rule` 误报「端口 X 不在端口池内」**（X 明明在池内）：`pool_contains` 用 `expand_port_pool | grep -qxF`，`grep -q` 命中首个端口即退出并关闭管道，左侧 `expand_port_pool` 在 `set -o pipefail` 下收到 SIGPIPE → 整条管道返回非 0 → 误判。属时序竞争（缓冲快的机器不必现，真机慢必现，区间首端口最易触发）。改为**纯 bash 匹配，无管道/无 grep**

## [0.6.9] - 2026-06-15

### Fixed

- **公网入口隧道起不来的真因**：WireGuard 接口名取自 `wm-<线路ID>`，入口线路 `ix-nat-ingress` → `wm-ix-nat-ingress` 共 **17 字符 > Linux 接口名上限 15（IFNAMSIZ）**，`wg-quick` 直接失败（IX 的 `wm-ix-nat` 9 字符正常）。`wg_iface_for` 现在**超过 15 字符就用哈希压到 `wm-<11hex>`**；并通过 per-profile drop-in **覆盖 tunnel 单元的 ExecStart** 指向该短接口的 conf（systemd 实例仍按线路ID，改动面最小）

### Added

- `create-transit` / `import-code` 末尾**询问「现在就启动该线路吗？[Y/n]」并默认自动 `wm start`**（之前必须手动 start，易遗漏）
- 交互菜单「启动/停止线路」回车默认**唯一线路**（不再因留空报「无效的 PROFILE_ID」）

## [0.6.8] - 2026-06-15

### Fixed

- **隧道从未启动的真凶**：systemd 单元 `ExecStart=/usr/bin/mimic` 把路径写死，但部分发行版（如 Debian）mimic 装在 `/usr/sbin/mimic` → 服务 `203/EXEC` 失败、`journalctl` 报 `Unable to locate executable '/usr/bin/mimic'`，mimic 根本没跑（手动 `mimic run` 却完全正常）。改为**自动探测 mimic / wg-quick / modprobe 的真实绝对路径**（新增 `resolve_bin`：PATH + 常见目录），不再写死
- mimic 单元 `Type=notify` → **`Type=simple`**（不依赖 mimic 的 sd_notify 支持）
- `wm start` 现在每次**重新生成 systemd 单元**（让此修复对已装机器在 start 时即生效，无需完整重装），并**校验 mimic 服务真的 active**；若 native XDP 挂载失败（如 virtio_net + GRO），**自动回退 skb 重试**，仍失败则提示用 `journalctl` 排查

### Note

- 真机定位过程：0.6.7 已修正"IX filter 用网卡真实 IP"（mimic 精确匹配）；本版补上 systemd 单元路径这一**真正阻塞点**——之前所有"不通"都源于 mimic 服务 203/EXEC 从未启动

## [0.6.7] - 2026-06-15

### Fixed

- **隧道仍不通的真正根因**（与 mimic#43 同款）：Mimic 做**精确 IP 匹配**，XDP/TC 看到的是**网卡上的真实 IP**；NAT/浮动IP 机器网卡上是内网 IP，而 0.6.6 用的 `local=0.0.0.0` 通配**只有 2025-11 之后的 mimic 才支持**（mimic#32），用户的 mimic 0.7.0 不识别 → IX 侧 mimic 不匹配 → server 端 `mimic show -c` 无连接、入口一直 SYN 重试。改为 **IX filter 用自动探测的 `WAN_IFACE` 网卡真实 IP**（精确匹配、全版本通用）；可用 `MIMIC_LOCAL_IP` 覆盖；`0.0.0.0` 仅作探测失败兜底
- 去掉 0.6.6 加的 `handshake=0`，与 mimic 维护者确认可用的 server 配置（默认 active）对齐

### Note

- 仍需确认云安全组放行 IX 公网/浮动IP 的 **TCP + UDP `WG_PORT`**（mimic 链路上是 TCP，netfilter 入站识别为 TCP、出站为 UDP，两者都要放行）

## [0.6.6] - 2026-06-15

### Fixed

- **连通性根因**：IX(`nat-transit`) 的 Mimic filter 之前用 `local=<公网IP>:端口`，在 NAT / 浮动IP 机器上网卡只有内网 IP，XDP/TC 永远匹配不到该公网 IP → 隧道不通。改为 **`local=0.0.0.0:端口`（通配本机 IP，NAT 安全）** 并加 **`handshake=0`** 让 IX 侧被动（由公网入口主动发起 fake-TCP 握手，对齐 mimic 官方 WireGuard server 范例）；公网入口仍 `remote=<IX公网IP>:端口` 主动
- 移除 `create-transit` 中已无意义且误导的「IX 本机公网 IP（Mimic local 绑定）」提示（Mimic 改用 `0.0.0.0` 通配，不再需要单独绑定 IP）
- `create-transit` / `import-code` 公网地址默认值改回 **curl 出网 IP**（NAT 云机网卡多为内网 IP 不可作公网地址），网卡 IP 仅作辅助提示；浮动公网 IP 仍需手填

### Note

- Mimic 在**两端都运行**、各自双向 encode(TC) + decode(XDP)，是正常设计而非配置错误

## [0.6.5] - 2026-06-15

### Fixed

- `create-transit` / `import-code` 的公网 IP 默认值改用**本机网卡全局 IPv4**（新增 `detect_local_ipv4`，即 Mimic 可绑定、客户端可达的入口 IP），不再默认 `curl` 探测的**出网 IP**——多 IP / NAT 机器上出口 IP ≠ 入口 IP，旧默认常需手动改正；curl 出口 IP 降级为参考提示

## [0.6.4] - 2026-06-15

### Fixed

- `import-code` 导入时「客户端入口端口」默认值改为该规则的**落地端口**（多数场景客户端与落地用同一端口号），直接回车即可，仍可手动指定
- `create-transit` / `import-code` 完成后，若检测到 mimic 内核模块因运行内核与已编译模块不一致而未加载（`mimic_needs_reboot`），主动给出**重启提示**并可选「开机自动续跑 `wm start <ID>`」；此前仅 `wm start` 阶段提示，create/import 阶段易被忽略

## [0.6.3] - 2026-06-15

### Added

- **商家中转端口池**：IX(`nat-transit`) 线路新增可选 `TRANSIT_PORT_POOL`（如 `40000-40010,40050`）。设置后 `create-transit` / `add-rule` 自动从池中分配下一个空闲中转端口作为默认值（可手动覆盖），并强制所选端口必须落在池内、禁止与同线路其它规则重复；池用尽时给出明确提示
- 新增 `wm set-pool <ID> [端口池]`（留空=清除端口池，恢复每条规则手动指定）；`wm list-rules` 显示端口池用量（共/已用/剩）；交互菜单「规则管理」新增 `pool` 操作
- 端口池为 IX 侧分配状态，**不进入接入码、不影响公网入口**；留空时行为与 0.6.2 完全一致

### Fixed

- `add-rule` / `edit-rule` 现在检测并拒绝同一线路内重复的中转端口（此前可能生成冲突的 nft DNAT）

## [0.6.2] - 2026-06-15

### Added

- `wm start` 检测到 mimic 内核模块需重启才能生效（DKMS 为非运行内核编译）时，**交互询问是否现在重启并开机自动继续**：写入一次性 `wg-mimic-resume` systemd 单元，开机 `modprobe mimic` + 续跑 `wm start <ID>` 后自删
- 新增 `wm resume`（一次性恢复命令，主要由上面的开机单元调用）

## [0.6.1] - 2026-06-15

### Fixed

- `create-transit` / `import-code` 交互按回车取默认值时报 `val: unbound variable`：`prompt` 与 `prompt_port` 因内部 `local val` 同名，`printf -v` 跨函数回写错位，`set -u` 下调用方变量未绑定。重命名内部变量（`__prompt_val` / `_pval`）修复；并对 `read </dev/tty` 失败兜底默认值。

## [0.6.0] - 2026-06-15

### Changed（Breaking — 重构）

- **组网模型重构**：借鉴 `ix-transit-fabric`，改为「公网入口 ⇄ IX 经 **WireGuard** 点对点组网」，**Mimic 把 WG 的 UDP 伪装成 TCP** 穿透封锁；IX 经 nft 转发到落地
- **角色**：`nat-transit`（IX/落地侧，WG 监听 + 生成接入码）与 `nat-ingress`（公网入口，导入接入码）
- **接入码 `code_schema=5`**（`WMGF1:`）：含 WG 组网密钥、虚拟 IP、`transit_port`、落地 `IP/端口`、`MTU` 与 **多规则数组**；公网入口单向导入（IX 预生成入口私钥写入码）
- **多转发规则**：一条 WG 隧道承载多条规则，规则存于 `profiles/<id>/rules/<rule_id>.env`；`add-rule`/`edit-rule`/`delete-rule`/`enable-rule`/`disable-rule`/`apply-rules`
- 新命令：`create-transit` / `import-code` / `show-port-map` / `list-rules` 等
- 移除 v0.5 的 `transit-code`(schema3) / relay / WG server-client / forwarder 旁路流程
- 复用 v0.5 的 Mimic 多发行版自动安装、systemd drop-in 修复、镜像下载/升级
- 新增 `.gitattributes`（`*.sh eol=lf`）；`scripts/smoke.sh` 纯函数冒烟测试

### Added — 进阶特性

- **IPv6 / 双栈**：`IP_VERSION=4|6|dual`，WG 隧道可分配 IPv6 虚拟网；nft 按落地地址族（解析后）emit `ip`/`ip6` DNAT/masquerade；接入码携带 IPv6 网段/虚拟 IP
- **DDNS**：`ddns-enable|ddns-disable|ddns-status|ddns-refresh` + systemd timer（每 3 分钟）；公网入口端点域名变化热更新 `wg set endpoint`，落地域名渲染 nft 时自动解析跟随
- **主备**：线路分组 `LINE_GROUP/LINE_ROLE/LINE_PRIORITY`；`set-group`/`list-groups`/`switch-line`/`primary-backup-check`/`health-all`，手动切换（不自动切线）
- nft 渲染对落地**域名自动解析为 IP**（域名落地可用）

## [0.5.1] - 2026-06-15

### Added

- 公网入口 `import-transit-code` 自动安装并启用 **Mimic**（`filter=local=公网IP:端口`，UDP 伪装 TCP）
- IX 中转仍为纯 nft 转发（无需 mimic）

## [0.5.0] - 2026-06-15

### Changed（Breaking）

- **菜单与主流程对齐 ix-transit**：IX `create-transit` 生成接入码 → 公网入口 `import-transit-code`
- 移除菜单中的 WG 服务端 / 客户端 / Forwarder / 手动 relay
- 接入码 `code_schema=3`（`transit-code`）
- 纯转发推荐 `WMF_SKIP_MIMIC=1` 安装

## [0.4.0] - 2026-06-15

### Added

- **`wm create-relay`**：纯 nft 端口转发（`ROLE=relay`），对标 ix-transit 公网入口→IX→落地
  - `RELAY_KIND=ingress|transit`，支持 `tcp` / `udp` / `both`
  - 落地无需 WG / Mimic
- 文档 `docs/transit-topology.md`

## [0.3.4] - 2026-06-15

### Fixed

- DKMS 优先为**当前运行内核** `uname -r` 编译 mimic，避免头文件装到新内核但尚未 reboot 导致 modprobe 失败
- 头文件与运行内核不匹配时给出明确 reboot 指引

## [0.3.3] - 2026-06-15

### Fixed

- 修复 `create-server` 在 `set -u` 下 `iface: unbound variable`（`apply_mimic_conf_iface` 同行 local 声明）
- Debian/Ubuntu 安装 mimic-dkms 前自动安装 `linux-headers-$(uname -r)` 并触发 `dkms autoinstall`

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
