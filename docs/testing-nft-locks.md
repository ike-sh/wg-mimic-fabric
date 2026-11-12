# Issue #1：nft 锁回归验证

## 调用链与锁顺序

v1.4.10：`wm start/restart/resume` 持有 state 锁 → 等待 `systemctl restart tunnel` → tunnel 的 `Requires` 启动 nft 服务 → `wm apply-nft-all` 再等 state 锁，形成循环等待，30 秒后依赖失败。

v1.4.11：普通 CLI 获取 state 锁 → 获取 nft 锁完成完整事务 → 释放 nft 锁 → 等待 systemd → nft 服务运行 `wm apply-nft-all --internal`，只获取 nft 锁 → 事务成功并释放锁 → tunnel 启动。只有参数恰为 `apply-nft-all --internal` 且通过 root 检查时才走内部入口；不会设置通用的 state 锁绕过变量。

配置写入、规则/线路删除和 DDNS 缓存更新也在短暂的 nft 临界区中完成。渲染期间这些输入不会变化；所有 nft 更新路径（含 DDNS、autoswitch、主备和 purge）共用一把 nft 锁。渲染内部的缓存写入使用已持有的锁，不递归加锁。临界区中没有 systemctl 等待，也没有尝试获取 state 锁的操作。已有 `WMF_LOCK_HELD` 嵌套状态调用保持兼容。

规则仍经预检与单个 nft transaction 更新内核；持久化失败时不加载内核，内核加载失败时恢复原持久化文件。EXIT/HUP/INT/TERM 清理和回滚在释放 nft 锁之前完成。WG/Mimic 配置、单元及新版本脚本同样原子替换，systemd 可读到完整文件。

## 无特权回归

```bash
bash -n install.sh scripts/bootstrap.sh scripts/smoke.sh
shellcheck -S warning install.sh scripts/bootstrap.sh scripts/smoke.sh
bash scripts/smoke.sh all
```

这些测试使用临时目录、真实 `flock` 和独立 Bash 进程；root 身份、nft/systemd/WireGuard 命令由夹具模拟，宿主机规则与服务不被修改。模拟 systemd 根据实际生成单元的 ExecStart 启动独立进程，并清除继承的 `WMF_LOCK_HELD`；升级后的刷新调用则保留合法嵌套标记。

| 测试入口 | 覆盖行为 |
| --- | --- |
| `bash scripts/smoke.sh nftlocks` | 另一个进程持有 state 锁时内部入口在 3 秒内完成；普通 CLI 超时拒绝；内部参数和 root 校验；两类调用均受 nft 锁保护；两个完整事务不交错；配置写入等候完整事务结束 |
| `bash scripts/smoke.sh nftfail` | 已有/无持久化文件时的预检、加载失败；持久化/渲染失败；加载前 TERM；检查旧磁盘和模拟内核规则、临时文件、锁与退出码 |
| `bash scripts/smoke.sh units` | 内部入口、Requires/After、Mimic/direct drop-in、daemon-reload |
| `bash scripts/smoke.sh lifecycle` | 首次启动、nft failed 状态重试、restart、resume、多线路；nft 依赖失败阻止隧道并回滚 ENABLED |
| `bash scripts/smoke.sh upgrade` | 运行 v1.4.10 版本的升级逻辑并安装新脚本；新脚本生成内部入口、保留依赖、执行 daemon-reload、备份脚本、保持配置与规则逐字节不变；同版本继续跳过 |
| `bash scripts/smoke.sh maintenance` | DDNS endpoint/landing 缓存并存，autoswitch 及主备启动触发内部 nft 依赖，保留多线路 DNAT 与持久化一致性 |
| `bash scripts/smoke.sh atomic` | 并发读者看不到生成中的部分配置；渲染失败保留旧文件 |
| `bash scripts/smoke.sh rollback` / `lock` | 启动原始退出码、失败日志脱敏、ENABLED 回滚，两种锁的中间失败/errexit、嵌套 state 锁 |

CI 的发行版安装任务（含 Ubuntu 24.04 / Debian 13）在安装完成后执行同一套 smoke，并校验实际安装的 nft 单元。容器中的 systemctl 是 mock，不能据此认定真实 systemd 或重启已经通过。

## 隔离的真实 systemd/nft 集成测试

在有 systemd、nftables、util-linux 的 root 环境中运行：

```bash
bash -n scripts/integration-nft-locks.sh
shellcheck -S warning scripts/integration-nft-locks.sh
sudo bash scripts/integration-nft-locks.sh
```

脚本为单元分配独立名称，以临时目录保存配置，并让全部 nft 命令进入独立网络命名空间；结束时停止/删除测试单元、enable 链接、配置和命名空间。systemd 与内核 nft 是真实实现，wg-quick 是只检查配置和 nft table 的 stub，模块加载与 sysctl 不修改宿主机。覆盖真实 state 锁被占用时的依赖启动、首次启动、restart、多线路、真实 failed 依赖/回滚/重试、resume 单元执行，以及真实 nft 预检/事务拒绝和并发更新。缺少 root/systemd/命名空间能力时退出 77，不能当作通过。

CI 在 Ubuntu 24.04 VM 单独执行该脚本。该测试不执行真实 reboot，也不建立真实 WireGuard/Mimic 隧道；实际端到端网络验证使用下面的虚拟机步骤。

## 真实 systemd 集成步骤

分别在 Ubuntu 24.04、Debian 13 的测试虚拟机执行。准备至少两条有效线路，涵盖四种角色、Mimic/direct、IPv4/双栈；验证 MTU、接入码、客户端、DNAT/MASQUERADE 和对端连通性。下面的停止、失败注入、切换与重启会中断测试线路。

先安装本分支的 `install.sh`（`sudo bash install.sh install-wm-cli`），确认 `wm --version` 为 `1.4.12`，`systemctl cat wg-mimic-nft.service` 包含 `apply-nft-all --internal`，tunnel 保留 Requires/After。以下命令在 root Bash 中执行：

```bash
ID=测试线路ID
OTHER=另一条测试线路ID

# 持有真实 state 锁，直接启动真实 nft 单元。
systemctl stop wg-mimic-nft.service
(
    exec 9>/run/lock/wg-mimic-fabric.lock
    flock -x 9
    env -u WMF_LOCK_HELD timeout 10 systemctl start wg-mimic-nft.service
)
systemctl is-active wg-mimic-nft.service

# 重现首次依赖启动，再验证 restart 和多线路。
systemctl stop wg-mimic-nft.service
time timeout 20 wm start "$ID"
time timeout 20 wm restart "$ID"
time timeout 20 wm start "$OTHER"
systemctl is-active wg-mimic-nft.service "wg-mimic-tunnel@${ID}.service" "wg-mimic-tunnel@${OTHER}.service"
nft list table inet wg_mimic_fabric
wm health "$ID"
wm test "$ID" 20
```

然后注入 nft 单元失败，移除注入后直接重试，让 `wm start` 面对已有 failed 状态：

```bash
systemctl stop wg-mimic-nft.service
install -d /etc/systemd/system/wg-mimic-nft.service.d
cat >/etc/systemd/system/wg-mimic-nft.service.d/90-lock-regression.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/bin/false
EOF
systemctl daemon-reload
if systemctl start wg-mimic-nft.service; then
    echo '失败注入未生效' >&2
    exit 1
fi
systemctl is-failed wg-mimic-nft.service
rm /etc/systemd/system/wg-mimic-nft.service.d/90-lock-regression.conf
systemctl daemon-reload
time timeout 20 wm start "$ID"
systemctl is-active wg-mimic-nft.service "wg-mimic-tunnel@${ID}.service"
```

最后验证真实开机恢复（调用现有函数生成单元，不修改命令行接口）：

```bash
WMF_SOURCED=1 bash -c '
    source /usr/local/libexec/wg-mimic-fabric/install.sh
    with_state_lock install_resume_unit "start $1"
' _ "$ID"
systemctl enable wg-mimic-nft.service
reboot
```

重启后检查 nft/tunnel active、resume marker 与一次性 resume 单元已移除、日志没有锁超时，并再次验证两条线路的健康和连通性。在有效 DDNS/自动切换配置下执行 `wm ddns-refresh`、`wm autoswitch <入口ID>`、`wm switch-line <组> <目标ID>` 后复核规则与连通性。

```bash
systemctl is-active wg-mimic-nft.service "wg-mimic-tunnel@${ID}.service"
test ! -e /etc/wg-mimic-fabric/state/resume.cmd
test ! -e /etc/systemd/system/wg-mimic-resume.service
journalctl -b -u wg-mimic-nft.service -u "wg-mimic-tunnel@${ID}.service" -n 40 --no-pager -o cat
```

真实 nft 回滚另在测试 VM 中比较一次有效 `wm apply-nft-all` 前后的持久化文件和 `nft list table`。用指向不存在内核对象的规则或临时 nft shim 分别触发 `-c -f` 和 `-f` 失败，确认旧表及文件不变、临时文件清理、后续有效调用能获取锁。加载失败注入应在实际提交之前返回失败，不能在成功提交之后伪报失败。

记录每个发行版的 systemd/nft 版本、命令退出码、耗时、服务状态和连通性结果。未实际运行以上步骤时，应标为「未验证」，不能以 smoke 通过代替。

## 升级与回滚

部署修复到 main 或发布 v1.4.11 后，旧用户运行 `sudo env WMF_UPGRADE_YES=1 wm upgrade-script`。版本从 1.4.10 变为 1.4.11，正常进入升级；旧脚本已具有由新脚本执行 `refresh-installation` 的逻辑。回归测试实际执行这条链路，并检查配置/规则未改动。无需清除或重建线路，也无需删除锁文件。

failed 恢复与脚本回滚命令见 [README](../README.md#升级与-failed-状态恢复)。回滚时务必同时重新生成旧版本单元；旧脚本不理解 `--internal` 的锁语义。回滚到 v1.4.10 会恢复原死锁，因此需先在 wm 之外启动 nft 服务再启动线路。

锁只能协调遵守本协议的 wm 进程；外部直接修改 nft 表或配置文件不受该锁约束。SIGKILL、断电或内核提交成功后进程立即消失无法由 Bash trap 保证磁盘与内核同步；恢复后执行 `wm apply-nft-all` 重新对齐。这些属于原有事务机制的崩溃边界，修复没有移除预检或依赖保护。
