# Changelog

## [1.1.0-beta.14] - 2026-06-16

### Fixed（swgp-go 被装成损坏文件导致 `Exec format error`，A↔B 骨干 100% 丢包的真正根因）

- **`download_swgp_release` 支持 `.tar.zst` 解压**：swgp-go 上游（database64128）自 v1.10.0 起**只发布 `.tar.zst` 资产**（无 `.tar.gz`/`.zip`）。旧代码的 `case "$url"` 只认 `.zip`/`.tar.gz`/`.tgz`，`.tar.zst` 落入 `*)` 兜底分支——**把压缩包原样 `cp` 成 `/usr/local/bin/swgp-go` 并 `chmod +x`**，于是「二进制」其实是个 zstd 压缩档，systemd 启动即 `Failed to execute ... Exec format error`（status=203/EXEC）疯狂重启，swgp 端口从不监听 → A 发包 B 不回 → `wm test` / `ping 10.90.0.2` 100% 丢包。现新增 `.tar.zst`/`.tar`/`.zst` 分支（GNU `tar --zstd`，回退 `zstd -d | tar`），并按需 `apt install zstd`。
- **资产选型优先「静态构建 + x86-64-v2」**：上游同时提供 glibc/静态、v2/v3 多档；旧打分逻辑遇全 `.tar.zst` 时一律打平、取首个（glibc-v2），可能引入 glibc 版本依赖或 AVX2(v3) 指令兼容问题。现优先选**静态构建**（更可移植）与 **x86-64-v2**（兼容性最广），降低换机即崩风险。
- **下载产物强制 ELF 魔数校验**：`install` 前用 `is_elf_bin` 确认产物确为 ELF（`7f 45 4c 46`），任何「未解压归档/坏档」一律拒装，从源头杜绝再装出 `Exec format error`。
- **`install_swgp` 守卫自愈损坏二进制**：旧守卫 `[[ -x "$SWGP_BIN" ]]` 见到带 +x 的坏档即判「已安装」直接返回，导致反复 `bootstrap`/`upgrade` 永远绕过重装、坏档一直在（用户多次重装仍报「swgp-go 已安装」却始终不通的元凶）。现改为 `swgp_installed_ok`——仅当是真 ELF 才算已装，否则删除坏档并重新下载，**升级即自愈**。
- 验证：`bash -n` 语法通过；`smoke nopy` 回归全 10 项通过；并以真实 v1.10.0 资产核对解包路径（`./swgp-go`）与选型（`linux-x86-64-v2.tar.zst`）。

## [1.1.0-beta.13] - 2026-06-15

### Fixed（`wm test` 对 relay 线路假通过：ping 的是自己而非对端 B）

- **`peer_mesh_ip` 修复 relay 角色**：此前只有 `nat-ingress` 返回对端 IX/出口 IP（`WG_IX_IP`），其余角色一律返回 `WG_INGRESS_IP`。但 **relay（A 网关全局出口）自身 mesh 地址正是 `WG_INGRESS_IP`**，于是 `wm test <relay>` ping 的是 A 自己（`10.x.0.1`，延迟 0.0xx ms、0% 丢包），看似「线路质量良好」实为白测，根本没验证 A↔B 隧道。现把 relay 与 nat-ingress 同等对待（拨号侧对端 = `WG_IX_IP`），`wm test` 改为真正 ping 对端 B（`10.x.0.2`），能如实暴露 swgp 端口不通等问题。

## [1.1.0-beta.12] - 2026-06-15

### Changed（交互菜单所有 ID 列表改为「阿拉伯数字」选择）

- **`menu_pick_profile` 改为编号选择**：之前列出线路是 `- exit` / `- ix-nat`，却让用户手敲字符串 ID，输「1」会报 `线路不存在：1`。现改为 `1) exit  [exit]` / `2) ix-nat  [nat-transit]`，输编号即选中（仍兼容直接输 ID）。覆盖菜单 3/4/5/7/8/9/13/14 的线路选择。
- **新增 `menu_pick_rule` / `menu_pick_client` 编号选择器**：菜单 `10) 规则管理` 的「编辑/删除规则」、`13) 客户端管理` 的「删除客户端」此前要手敲规则 ID / 客户端名，现统一列编号选择（兼容输名称）。
- **菜单 `10)` 线路选择改用 `menu_pick_profile`**（编号化，去掉重复的自定义选择逻辑）。
- 编号解析用 `10#` 强制十进制（避免 `08`/`09` 被当八进制报错），越界/非数字自动回退到「按 ID/名称匹配」；`bash -n` + 索引逻辑隔离测试 + `smoke nopy` 回归全过。

## [1.1.0-beta.11] - 2026-06-15

### Added（交互菜单接入「删除线路」，与 CLI 对齐）

- **交互菜单新增 `14) 删除线路（delete-line）`**：beta.10 只把删除做成了 CLI（`wm delete-line`），敲 `wm` 进菜单点不到——反复建/删线测试只能记命令手敲。现菜单补入口（升级/卸载顺延为 `15)` / `16)`）：选 14 → 列出全部线路供选 → 调用 `delete_profile` 二次确认后删除。菜单框各行内宽仍为 38 显示列、与既有项完全对齐（已用按字节 CJK=2 测量复核）。`bash -n` + `smoke nopy` 回归全过。

## [1.1.0-beta.10] - 2026-06-15

### Added（安全删除整条线路，便于反复建/删测试）

- **新增 `wm delete-line <ID>`（别名 `remove`）安全删除单条线路**：此前只有 `delete-rule` 删单条转发规则，**没有删除整条线路的命令**——反复测试混淆出口/组网时只能手动 `rm` 配置/密钥/接入码/客户端，极易误删，且在「同一网卡多线路共用 mimic」的机器上贸然删除会波及其它线路。新命令一条龙：停并 disable 该线路的 tunnel/swgp 服务 → 删除 `profiles/<id>.env`、`/etc/wireguard/<wg-iface>.conf`、`codes/<id>.code`、`swgp/<id>.json`、`profiles/<id>/`（含 clients）、tunnel 的 systemd drop-in → `daemon-reload` → **重渲染 nft 与该网卡 mimic（保留同机其它线路，按当前 filter 重新挂载，无残留 XDP）**。默认二次确认，`WMF_DELETE_YES=1` 跳过确认（脚本化）。已接入 CLI 分发与 `usage`。



### Fixed（relay 全局出口隧道 wg-quick 启动失败 status=2,却无报错）

- **relay 的 PostUp/PostDown 清理命令补 `|| true`**：全局出口 relay 的 WG conf 在加策略路由前用 `ip rule del ... 2>/dev/null` 清残留,但 **wg-quick 本身以 `set -e` 运行 PostUp**——首次启动规则不存在时 `ip rule del` 返回 2（`2>/dev/null` 只挡了报错信息、挡不住退出码），触发 set -e 中止 → `wg-quick up` 失败回滚(`Main process exited status=2/INVALIDARGUMENT`,且**不打印任何 Error 行**,极难排查)。给 PostUp/PostDown 的 `ip rule del` / `ip route flush` 都加 `|| true` 使其幂等,首次启动不再被 set -e 打断。属 Phase 2 全局出口(beta.2/4)从未真机验证暴露的问题。

## [1.1.0-beta.8] - 2026-06-15

### Fixed（多条线路撞同一网段/虚拟IP；虚拟IP 不在所选网段内）

- **`create-exit` / `create-transit` 自动选空闲 mesh 网段**：此前网段默认死写 `10.88.0.0/24`、虚拟IP 死写 `10.88.0.2/.1`,在已有线路(同为 10.88)的机器上再建线路会直接撞网段/虚拟IP,导致 WG 路由冲突、隧道异常。新增 `next_free_mesh_subnet`——扫描已有线路占用的 `10.N.0.0/24`,自动给第一个空闲段(10.88 被占 → 10.90…,预留 10.89 给 relay 客户端子网);无其它线路时仍默认 10.88,单线路行为不变。
- **虚拟IP 跟随所选网段**：新增 `mesh_host_ip`,B/IX 虚拟IP = 网段.2、A/入口 虚拟IP = 网段.1。此前改了网段但虚拟IP 默认仍是 10.88.0.2,会落在网段之外(隐藏坑),现已消除。

## [1.1.0-beta.7] - 2026-06-15

### Fixed（restart/set-mtu/upgrade 后遗留旧 mimic 进程 → 隧道不通）

- **`ensure_mimic_service_up` 改为总是按最新 unit/conf/env 干净重启 mimic**：此前“见 mimic 已 active 就提前 return”，导致 `wm set-mtu` / `restart` / `upgrade-script` 后 mimic 仍跑着旧进程（旧 XDP 模式、或解析旧 conf 丢了 filter），在 virtio 网卡上尤其致命——重启后隧道直接不通、必须手动 `systemctl restart wg-mimic-mimic@<iface>` 才能救。现在每次都 `detach_xdp` +（virtio 直接 skb）+ `restart` mimic，确保按当前 `-x` 模式与 filter 重新挂载。代价：同一网卡多线路时会顺带重启共享 mimic（秒级抖动），换取重启后状态必定一致。
- **`start_profile` 用 `systemctl restart` 显式拉起隧道**：隧道单元 `Requires=wg-mimic-mimic@<iface>`，重启 mimic 可能被 systemd 级联停掉隧道；改用 `restart`（而非 `enable --now`）保证隧道最终一定起来并套用最新 WG conf（修“重启 mimic 后 WG 接口消失、隧道不通”）。

## [1.1.0-beta.6] - 2026-06-15

### Fixed（严重：virtio 网卡上 mimic 丢 filter 导致隧道在 XDP 层不通）

- **mimic 的 XDP attach 模式改用命令行 `-x` 传递，不再写进 `.conf`**：此前 `MIMIC_XDP_MODE`（virtio 网卡自动置 skb，或手动 `wm set-xdp-mode`）会以 `xdp_mode = skb` 写入 `/etc/mimic/<iface>.conf`，但 **mimic 0.7.0 的配置文件并没有 `xdp_mode` 这个键**（XDP 模式只能用命令行 `-x/--xdp-mode`）。mimic 读到这行非法配置即**中断解析、丢弃后面的 `filter = ...` 行** → 以默认值（native、无 filter）运行 → 不处理任何流量 → **隧道在 XDP 层完全不通**。virtio 网卡上尤其致命：`wm set-mtu` / `set-xdp-mode` / `restart` 任一操作触发自动 skb 后，这条 conf 就把线路打断。典型表现：**WG 能握手、`wm test` 100% 丢包、`mimic show` 显示 `Filter: none` / `XDP Attach Mode: native`（即使设了 skb）**。
  - `render_mimic_conf_iface` 不再输出 `xdp_mode` 行（conf 只保留 mimic 认识的 `filter` / `log.verbosity` / `keepalive`）。
  - 新增 `iface_xdp_mode` / `write_mimic_xdp_env`：把网卡选定的模式落到 `/etc/mimic/<iface>.xdp`（`MIMIC_XDP_ARGS=-x <mode>`），由 mimic 单元新增的 `EnvironmentFile=-/etc/mimic/%i.xdp` 注入 `ExecStart=… mimic run %i $MIMIC_XDP_ARGS -F …`。模式为空时删除该文件 → mimic 自动选择（native 支持则 native，否则 skb）。
  - 升级后两端 `wm restart <ID>` 重渲染即生效（单元模板会在 `wm start`/`restart` 时自动重建）。

### Added

- **`wm automtu <ID>` 自动探测隧道可用 MTU**：换中转线路后线上可用 MTU 常变小，导致"能连但卡/不显示延迟"（小握手包通、大数据包黑洞）。此前只能手动二分 `ping -M do` 再 `wm set-mtu`。新命令隧道起来后**自动**带 DF 二分 ping 对端虚拟 IP，找到封装(mimic+WG)后能过线路的最大内层包 → `WG_MTU = 该值`，自动 set-mtu 并满包复测；nft 的 MSS 钳制(`rt mtu`)随 WG_MTU 自动跟随，无需手算 MSS。路径对称，两端各跑一次（命令行，和 `wm test`/`set-mtu` 一样）。
- **交互菜单接入「混淆组网 / 全局出口」模式**：`create-exit` / `import-exit-code` / 客户端管理（增/列/删）此前只有 CLI 与 `usage` 入口，`show_menu()` 漏接，敲 `wm` 进菜单点不到、无法测试。现菜单新增分区 `11) 创建国外出口 B` `12) 导入出口接入码 A` `13) 客户端管理`（升级/卸载顺延 14/15）；`menu_pick_profile` 增可选角色过滤，客户端管理只列 `relay` 网关线路。

## [1.1.0-beta.5] - 2026-06-15

### Fixed（国内服务器一键引导拉取 install.sh）

- **引导脚本 `scripts/bootstrap.sh` 拉取 install.sh 改走镜像轮询**：之前 `fetch_repo_file` 仅「GitHub API raw → 直连 `raw.githubusercontent.com`」两步，国内（中国大陆）直连常超时/被墙，导致 `curl -fsSL .../bootstrap.sh | sudo bash` 一键安装在**第一步下载**就卡死。
- 现新增镜像兜底：API 失败后按 `WMF_GITHUB_MIRRORS`（默认 `gh.ddlc.top / gh-proxy.com / ghproxy.net`）逐个镜像拉取，最后回退直连；每次下载加 `[[ -s ]]` 非空校验 + `--connect-timeout 10 --max-time 120`，全部失败才 `return 1` 报错退出。
- 与 beta.3 给 install.sh 内部 release 下载加 `gh_curl` 镜像同思路，至此整条安装链路（引导脚本 → install.sh → swgp-go/mimic 资产）国内全程可达。

## [1.1.0-beta.4] - 2026-06-15

### Fixed（严重：全局出口劫持网关自身默认路由）

- **relay(A) 全局出口不再劫持 A 自身路由**：之前 peer B 用 `AllowedIPs=0.0.0.0/0` 时，wg-quick 默认把 `0/0` 装进主路由表，导致 **A 的 SSH 与现有 nat-ingress 线路一起断**。
- 现改为 **`Table = off` + 按客户端子网的策略路由**：`PostUp` 把默认路由只写进**每条线路独立的路由表**（`8000+hash(profile)%1000`），并 `ip rule from <客户端子网> lookup <表>`；`PostDown` 清理。**A 自身流量保持原默认路由不变**，只有客户端子网经隧道出 B。
- 移除 relay 接口上的 `FwMark`（策略路由已替代其防环作用；swgp 的 `proxyFwmark` 保留无害）。
- smoke `client` 用例改断言 `Table = off` + 策略路由规则。

> ⚠️ 升级后需在 A 上 `wm stop exit-relay` 再 `wm start exit-relay`（或重新 import）以重渲染配置。

## [1.1.0-beta.3] - 2026-06-15

### Fixed（国内服务器拉取 GitHub release）

- **swgp-go / mimic 的 release 下载改走镜像**：新增通用 `gh_curl`（镜像优先轮询 + 直连兜底 + 连接/总超时 + 重试），替换原先裸连 `api.github.com` / `browser_download_url` 的 `curl`。国内（中国大陆）网关机 `import-exit-code` / `install-swgp` / `install-mimic` 不再因直连 GitHub 失败而卡死。
- 镜像源沿用 `WMF_GITHUB_MIRRORS`（默认 `gh.ddlc.top / gh-proxy.com / ghproxy.net`），API 与资产下载统一走同一套；mimic 源码 tarball 同样改为镜像下载后解压。
- `test`：非数字 ping 包数自动回退默认值（避免误报 100% 丢包）。

## [1.1.0-beta.2] - 2026-06-15

### Added（混淆组网 Phase 2：客户端入口 + 全局出口）

- **客户端 WG 入口**：relay(A) 单 WG 接口同时当客户端服务端（`ListenPort`）+ 拨 B 出口（peer B `AllowedIPs=0.0.0.0/0`）；客户端 peer 用最长前缀匹配各走各路。
- **`wm add-client <网关> <名>` / `list-clients` / `del-client`**：生成标准 WG `.conf`（`AllowedIPs=0.0.0.0/0`、`DNS=1.1.1.1`、`MTU=1280`）+ `qrencode` 二维码，官方App/小火箭/mihomo/sing-box 通吃。
- **全局出口路由/NAT**：A 把客户端子网 masquerade 到上行(src→A mesh IP，B 才认)；B 把 mesh 子网 masquerade 出网卡 → 客户端对外即 B 出口IP。
- **防路由环**：relay 全局出口用 `FwMark` + swgp `proxyFwmark`，让 A 自身/swgp 到 B 的流量避开 WG 默认路由。
- `import-exit-code` 增「A 公网IP / 客户端端口」配置（更新模式保留旧值）；smoke 新增 `client` 用例。

> ⚠️ beta：Phase 2 路由/NAT/fwmark **必须真机验证**（本机无法运行期测试，仅 `bash -n` + smoke 渲染断言）。先在测试机：B `wm create-exit` → A `wm import-exit-code` → `wm test` 通后 `wm add-client` 扫码连。

## [1.1.0-beta.1] - 2026-06-15

### Added（混淆组网 / 全局出口 Phase 1：A↔B 混淆链）

- **swgp-go 集成**：`wm install-swgp`（GitHub release 动态匹配 linux+arch 资产，回退 `go install`）；`render_swgp_conf`/`apply_swgp_conf` 生成 server/client JSON；`wg-mimic-swgp@.service` systemd 单元。
- **新角色 `exit`(B 国外出口) / `relay`(A 国内网关)**，与现有 `nat-transit`/`nat-ingress` 并列：
  - `wm create-exit`（B）：建 WG 监听 + 可选 swgp/mimic + 出口；生成**出口接入码**（`code_schema=6` `nat-exit-code`，向后兼容 5）。
  - `wm import-exit-code`（A）：建到 B 的混淆隧道（`WG→swgp-go→mimic`）。
- **混淆四选一** `OBFS_MODE=direct/mimic/swgp/swgp+mimic`：mimic 的 filter 自动对准**线上端口**（含 swgp 时为 swgp 端口）；swgp 默认 `zero-overhead-2026`（不减 MTU）。
- **自动 MTU**：direct 1420 / mimic·swgp 1400 / paranoid 1360。
- smoke 新增 `swgp`/`code6`/`obfs` 用例；现有用例保持回归。

> Phase 1 仅打通 A↔B 混淆隧道（`wm test <relay>` 验证）。客户端 WG 入口 + 全局出口路由为 Phase 2。详见 `docs/plans/2026-06-15-obfuscation-mesh-gateway-{design,plan}.md`。
>
> ⚠️ beta：新角色未在真机充分验证；现有 nat-transit/nat-ingress 路径按 role 分支隔离、未改动（升级后建议先 `bash scripts/smoke.sh all` + `wm health`/`wm test` 确认现有线路无恙）。

## [1.0.3] - 2026-06-15

### Fixed

- **`wm upgrade-script` 确认输了 y 仍被取消**：此前确认是单次 `read`，SSH 下偶发漏键/读空就按默认 N 取消。改为**循环读取 + 容错**：读空重问（不再直接取消）、`y`/`yes` 继续、`n`/`no` 取消、其它重问；非交互或读取失败时明确提示用 `WMF_UPGRADE_YES=1 wm upgrade-script`。

## [1.0.2] - 2026-06-15

### Fixed

- **TCP MSS 钳制（修"能连但大流量卡死/网页转圈"）**：nft `forward` 链新增 `tcp flags syn tcp option maxseg size set rt mtu`——把进/出隧道的 TCP SYN 的 MSS 钳到隧道路由 MTU（如 1420→MSS 1380）。此前**未做 MSS 钳制**，>隧道MTU 的大包只能靠 PMTUD，而中转/NAT 常过滤 ICMP "需要分片"导致 **PMTUD 黑洞**：小请求正常、大文件/大 TLS 静默丢包卡死。钳制后两端自动协商出能过隧道的段大小，不再依赖 PMTUD。两端 `wm start`/`apply-rules` 后即生效，随 `WG_MTU` 自动适配（IPv4/IPv6 通用）。

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
