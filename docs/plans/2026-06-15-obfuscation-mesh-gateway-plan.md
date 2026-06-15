# Obfuscation Mesh Gateway 实现计划

> **执行方式**：本仓库为单文件 bash 安装器（`install.sh`），交付走 `curl|bash` + `wm upgrade-script`。**不引入子代理**（KC 规则禁止），按任务在当前会话内 inline 执行。每个含纯函数的任务用 `scripts/smoke.sh` 断言做 TDD；涉及 root/systemd/内核/网络的任务用 `bash -n` + 真机手动验证（无法在本机单测）。
>
> 关联设计：`docs/plans/2026-06-15-obfuscation-mesh-gateway-design.md`

**Goal**：在 wg-mimic-fabric 增加「A(国内 relay) ↔ B(国外 exit)」混淆组网与客户端全局出口：A↔B 走 `WG→swgp-go→mimic`，客户端用标准 WG 连 A、全局经 B 出网。

**Architecture**：新增 `exit`/`relay` 两个 role，与现有 `nat-transit`/`nat-ingress` 并列、复用底层（mimic 安装/systemd/nft/密钥/升级）。两段 WG：客户端↔A 明文、A↔B 混淆。swgp-go 作可选混淆层（`direct/mimic/swgp/swgp+mimic`）。接入码升 `code_schema=6`（兼容 5）。

**Tech Stack**：bash、WireGuard(`wg`/`wg-quick`)、mimic(eBPF)、swgp-go(Go)、nftables、systemd、python3(JSON/base64)、qrencode(可选)。

**默认值（已确认）**：`obfs_mode=swgp+mimic`、`swgp_mode=zero-overhead`、`exit_mode=global`、客户端 `DNS=1.1.1.1`(经隧道)。

---

## 文件结构

全部改动集中在单文件 `install.sh`（按现有分节插入新段），外加测试与文档：

| 文件 | 改动 | 责任 |
|------|------|------|
| `install.sh` | 新增「swgp-go 安装/配置/服务」「exit/relay 角色」「客户端管理」「schema 6」「路由/NAT」段；扩展 `usage`/`main`/`render_mimic_conf_for_profile`/`render_nft_all`/卸载清理 | 核心 |
| `scripts/smoke.sh` | 新增 `swgp`/`code6`/`exitnft` 等纯函数断言 | 回归 + TDD |
| `README.md` / `CHANGELOG.md` / `examples/operations.md` | 文档 | 说明 |
| 运行时（脚本生成，非仓库文件）| `/etc/wg-mimic-fabric/swgp/<id>.json`、`/etc/systemd/system/wg-mimic-swgp@.service`、客户端 `.conf` | — |

**隔离铁律**：现有 `nat-transit`/`nat-ingress` 的渲染分支**逐字不动**；新逻辑一律 `case "$ROLE"` 新分支；`render_nft_all`/`render_mimic_conf_for_profile` 只新增 role 分支。smoke 现有断言必须保持绿。

---

## Phase 1：swgp-go 安装 + A↔B 混淆链（无客户端入口）

目标：A、B 两台 Linux 用 `WG→swgp-go→mimic` 跑通隧道（`wm test` 验证），先不做客户端入口。

### Task 1：swgp-go 安装器

**Files:** Modify `install.sh`（新增 `install_swgp` 段，置于 mimic 安装段之后）

- [ ] **Step 1：写 `detect_arch` + `install_swgp`**

```bash
# swgp-go 架构名（GitHub release 资产用）
detect_swgp_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86-64-v2' ;;   # release 资产名以实际为准，Phase1 锁定
        aarch64|arm64) printf 'arm64' ;;
        *) printf '' ;;
    esac
}

SWGP_BIN="/usr/local/bin/swgp-go"
SWGP_UPSTREAM_TAG="${SWGP_UPSTREAM_TAG:-latest}"

install_swgp() {
    require_root
    command_exists "$SWGP_BIN" && { ok "swgp-go 已安装"; return 0; }
    local arch; arch="$(detect_swgp_arch)"
    [[ -n "$arch" ]] || die "不支持的架构，无法装 swgp-go"
    local tmpd; tmpd="$(mktemp -d)"
    # 优先 GitHub release 二进制；失败回退 go install（需 golang）
    if download_swgp_release "$arch" "$tmpd/swgp-go"; then
        install -m 755 "$tmpd/swgp-go" "$SWGP_BIN"
    elif command_exists go; then
        GOBIN=/usr/local/bin go install github.com/database64128/swgp-go/cmd/swgp-go@"${SWGP_UPSTREAM_TAG}" || { rm -rf "$tmpd"; die "swgp-go 安装失败"; }
    else
        rm -rf "$tmpd"; die "swgp-go 安装失败：装不了二进制且无 go"
    fi
    rm -rf "$tmpd"; ok "swgp-go 已安装：$("$SWGP_BIN" -version 2>/dev/null || echo ok)"
}
```
> `download_swgp_release` 复用 `download_with_mirrors` 风格，Phase1 实现时按 `database64128/swgp-go` 实际 release 资产命名锁定（写进同一函数）。

- [ ] **Step 2：`bash -n` 校验**　Run: LF 归一后 `bash -n install.sh`　Expected: 退出 0
- [ ] **Step 3：Commit**　`git commit -m "feat(swgp): swgp-go installer (release binary + go fallback)"`

### Task 2：swgp-go 配置渲染（纯函数，TDD）

**Files:** Modify `install.sh`；Test `scripts/smoke.sh`

- [ ] **Step 1：在 smoke.sh 写失败用例**

```bash
test_swgp() {
    # server 端配置：监听 swgp_port，转发到本机 WG
    local out; out="$(render_swgp_conf server 18443 127.0.0.1:51820 zero-overhead "UFNLMTIz")"
    grep -q '"proxyListen": ":18443"' <<<"$out" || fail "swgp server listen"
    grep -q '"proxyMode": "zero-overhead"' <<<"$out" || fail "swgp mode"
    grep -q '"wgEndpoint": "127.0.0.1:51820"' <<<"$out" || fail "swgp wg endpoint"
    echo "SWGP OK"
}
```
（字段名以 swgp-go 实际 schema 为准，Task 锁定后回填断言）

- [ ] **Step 2：跑测试看失败**　Run: `bash scripts/smoke.sh swgp`　Expected: FAIL（render_swgp_conf 未定义）
- [ ] **Step 3：实现 `render_swgp_conf`**（按 swgp-go JSON schema 生成 server/client 配置；client 指向 B:swgp_port，server 指向本机 WG）
- [ ] **Step 4：跑测试看通过**　Run: `bash scripts/smoke.sh swgp`　Expected: `SWGP OK`
- [ ] **Step 5：Commit**　`git commit -m "feat(swgp): render swgp-go server/client config"`

### Task 3：swgp systemd 单元

**Files:** Modify `install.sh`（`install_swgp_units`，仿 `install_systemd_units`）

- [ ] **Step 1**：写 `wg-mimic-swgp@.service`（`ExecStart=${SWGP_BIN} -config /etc/wg-mimic-fabric/swgp/%i.json`，`Restart=on-failure`）。
- [ ] **Step 2**：`apply_swgp_conf <id>`：渲染 JSON 到 `/etc/wg-mimic-fabric/swgp/<id>.json`(600)。
- [ ] **Step 3**：`bash -n` 校验。
- [ ] **Step 4：Commit**　`git commit -m "feat(swgp): systemd unit + conf apply"`

### Task 4：obfs_mode 串联 + mimic filter 对准 swgp 端口

**Files:** Modify `install.sh:render_mimic_conf_for_profile`、`start_profile`/`apply_profile_configs`

- [ ] **Step 1**：在 smoke.sh `test_swgp`/新 `test_obfs` 加断言——当 `OBFS_MODE=swgp+mimic` 时，`render_mimic_conf_for_profile`（exit/relay role）的 filter 端口=`SWGP_PORT`（而非 WG_PORT）；`direct` 模式不产出 mimic filter。
- [ ] **Step 2**：跑测试看失败。
- [ ] **Step 3**：实现——`render_mimic_conf_for_profile` 新增 `exit`/`relay` 分支：`OBFS_MODE` 含 `mimic` 时 emit filter（端口取 `SWGP_PORT` 若含 swgp，否则 WG_PORT）；含 `swgp` 时 `start_profile` 额外起 `wg-mimic-swgp@<id>`。
- [ ] **Step 4**：跑测试看通过。
- [ ] **Step 5：Commit**　`git commit -m "feat: wire obfs_mode (direct/mimic/swgp/both), mimic filter targets swgp port"`

### Task 5：接入码 schema 6（向后兼容，TDD）

**Files:** Modify `install.sh:render_code_json`/`parse_code`；Test `scripts/smoke.sh`

- [ ] **Step 1**：smoke 写 `test_code6`：`generate_code`(exit role, 带 obfs/swgp 字段) → `parse_code` 往返，断言 `CODE_OBFS_MODE`/`CODE_SWGP_PSK`/`CODE_SWGP_MODE`/`CODE_EXIT_MODE` 正确；并断言**旧 schema-5 接入码仍能 parse**（保留原 `test_code`）。
- [ ] **Step 2**：跑测试看失败。
- [ ] **Step 3**：实现——`render_code_json` 对 `role=nat-exit-code` 增字段；`parse_code` 接受 `code_schema∈{5,6}`、缺字段给默认（5→direct）。
- [ ] **Step 4**：跑测试看通过（`test_code` 与 `test_code6` 全绿）。
- [ ] **Step 5：Commit**　`git commit -m "feat(code): schema 6 with obfs/swgp fields, backward compatible with 5"`

### Task 6：`wm create-exit`（B 侧，最小可用）

**Files:** Modify `install.sh`（`create_exit_interactive` + `usage`/`main`）

- [ ] **Step 1**：实现 `create_exit_interactive`：询问 B 公网地址、WG 端口、swgp_port、obfs_mode(默认 swgp+mimic)、swgp_mode(默认 zero-overhead)；生成 WG 服务端 + swgp server 配置 + masquerade；写 profile `ROLE=exit`；`generate_code`（schema 6）。
- [ ] **Step 2**：`main` 加 `create-exit) create_exit_interactive ;;`；`usage` 加一行。
- [ ] **Step 3**：`bash -n` + `smoke.sh all` 回归（确认旧用例全绿）。
- [ ] **Step 4：Commit**　`git commit -m "feat: wm create-exit (B side obfuscated WG listener + code)"`

### Task 7：`wm import-exit-code`（A 侧，最小 A↔B）

**Files:** Modify `install.sh`（`import_exit_code` + `usage`/`main`）

- [ ] **Step 1**：实现 `import_exit_code`：parse schema6 接入码；写 A 的 `ROLE=relay` profile（拨 B、起 swgp client、mimic filter 对 swgp 端口）；起线路。
- [ ] **Step 2**：`main`/`usage` 接线。
- [ ] **Step 3**：`bash -n` + `smoke.sh all`。
- [ ] **Step 4：Commit**　`git commit -m "feat: wm import-exit-code (A side relay uplink to B)"`

### Task 8：Phase 1 真机验证 + 版本

- [ ] **Step 1**：真机：B `wm create-exit` → A `wm import-exit-code` → A 上 `wm test <relay>`，丢包/握手正常即 A↔B 混淆链通。
- [ ] **Step 2**：`wm test` 关 swgp / 关 mimic 对比（验证各层生效）。
- [ ] **Step 3**：bump `1.1.0-beta.1`、CHANGELOG、`bash -n`、`smoke.sh all`。
- [ ] **Step 4：Commit + push + tag** `v1.1.0-beta.1`。

---

## Phase 2：客户端 WG 入口 + 全局出口

### Task 9：A 客户端 WG 服务端
**Files:** `install.sh`（relay profile 增第二个 WG 接口 `wm-<id>-cli`；`render_wg_conf` 增 relay-client 分支）
- [ ] 渲染 A 的客户端 WG 服务端 conf（独立接口/子网 10.89.0.0/24）；start 时一并起。`bash -n` + smoke。Commit。

### Task 10：客户端管理 `add-client/list-clients/del-client`
**Files:** `install.sh`（`add_client`/`list_clients`/`del_client` + `usage`/`main`）；Test smoke `test_clientconf`
- [ ] smoke：`render_client_conf <名> <ip> ...` 断言 `AllowedIPs=0.0.0.0/0`、`Endpoint=A:CLI_PORT`、`DNS=1.1.1.1`、`MTU=1280`。
- [ ] 实现 + qrencode（缺失则仅打印）。`bash -n` + smoke。Commit。

### Task 11：路由/NAT（A 转发客户端→B；B masquerade 出网）
**Files:** `install.sh:render_nft_all`（relay/exit 新分支）；Test smoke `test_exitnft`
- [ ] smoke：relay 渲染出「客户端子网 forward + masq 到上行」；exit 渲染出「relay/客户端子网 masq 到默认网卡」；并断言**现有 nat-transit/nat-ingress 用例输出不变**。
- [ ] 实现（增量 role 分支）+ `ensure_ip_forward`。`bash -n` + `smoke.sh all`。Commit。

### Task 12：Phase 2 真机端到端
- [ ] A `wm add-client 手机` → 扫码导入官方 WG App（AllowedIPs=0/0）→ 验证全局出口（IP 显示为 B、`wm test` 正常）。
- [ ] bump `1.1.0-beta.2`、CHANGELOG、commit/push/tag。

---

## Phase 3：分流示例 + 文档 + 正式版

### Task 13：文档
**Files:** `README.md`（新增「混淆组网/全局出口」章节 + mihomo/sing-box 分流示例）、`examples/operations.md`、`CHANGELOG.md`
- [ ] 写客户端四件套接入示例 + 分流规则片段。Commit。

### Task 14：smoke 补充 + 正式版
- [ ] `smoke.sh all` 覆盖新函数全绿；`bash -n`。
- [ ] bump `1.1.0`、CHANGELOG 汇总、commit/push/tag `v1.1.0`。

---

## 自查（Spec 覆盖）

- 角色 exit/relay → Task 6/7；两段 WG → Task 7/9；混淆四选一 → Task 4；mimic 对 swgp 端口 → Task 4；swgp 安装/配置/服务 → Task 1/2/3；接入码 schema6 兼容 → Task 5；客户端管理/二维码/DNS/MTU → Task 10；路由 NAT → Task 11；MTU(MSS 已 v1.0.2) → 复用；隔离/回归 → 每 Task 的 `smoke.sh all`；分阶段 → Phase 1/2/3。
- 占位符：swgp-go 字段名/release 资产名在 Task 1/2 实现时锁定（已标注），非遗留 TODO。
- 类型一致：`OBFS_MODE`/`SWGP_PORT`/`SWGP_PSK`/`SWGP_MODE`/`ROLE=exit|relay` 全程一致。

---

## 执行交接

KC 规则禁止子代理，故采用 **inline 执行**（executing-plans 风格）：按 Task 顺序在当前会话实现，每 Task 完成 `bash -n` + `smoke.sh` 回归 + commit，Phase 末真机验证 + push/tag。Phase 1 先交付、验证「A↔B 过墙稳」后再进 Phase 2。
