#!/usr/bin/env bash
# wg-mimic-fabric — WireGuard + Mimic tunnel orchestrator (MVP)
set -Eeuo pipefail

SCRIPT_VERSION="1.1.0-beta.12"
MIMIC_UPSTREAM_TAG="${MIMIC_UPSTREAM_TAG:-v0.7.0}"
APP_NAME="wg-mimic-fabric"
WMF_PROJECT_REPO="${WMF_REPO:-ike-sh/wg-mimic-fabric}"

CONFIG_DIR="/etc/wg-mimic-fabric"
PROFILES_DIR="${CONFIG_DIR}/profiles"
CODES_DIR="${CONFIG_DIR}/codes"
KEYS_DIR="${CONFIG_DIR}/keys"
STATE_DIR="${CONFIG_DIR}/state"
NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/wg-mimic-fabric.nft"
NFT_TABLE="wg_mimic_fabric"
BACKUP_DIR="/var/backups/wg-mimic-fabric"
DEFAULT_GITHUB_MIRRORS="https://gh.ddlc.top/,https://gh-proxy.com/,https://ghproxy.net/"
LIBEXEC_DIR="/usr/local/libexec/wg-mimic-fabric"
WM_CLI_INSTALL_SH="${LIBEXEC_DIR}/install.sh"
WM_BIN="/usr/local/bin/wm"
MIMIC_CONF_DIR="/etc/mimic"
WG_CONF_DIR="/etc/wireguard"
SYSTEMD_MIMIC_TEMPLATE="/etc/systemd/system/wg-mimic-mimic@.service"
SYSTEMD_TUNNEL_TEMPLATE="/etc/systemd/system/wg-mimic-tunnel@.service"
SYSCTL_FILE="/etc/sysctl.d/99-wg-mimic-fabric.conf"
SYSTEMD_DDNS_SERVICE="/etc/systemd/system/wg-mimic-ddns.service"
SYSTEMD_DDNS_TIMER="/etc/systemd/system/wg-mimic-ddns.timer"
SYSTEMD_AUTOSWITCH_SERVICE="/etc/systemd/system/wg-mimic-autoswitch@.service"
SYSTEMD_AUTOSWITCH_TIMER="/etc/systemd/system/wg-mimic-autoswitch@.timer"
SWGP_BIN="/usr/local/bin/swgp-go"
SWGP_CONF_DIR="${CONFIG_DIR}/swgp"
SWGP_REPO="${SWGP_REPO:-database64128/swgp-go}"
SYSTEMD_SWGP_TEMPLATE="/etc/systemd/system/wg-mimic-swgp@.service"
CLIENT_SUBNET_DEFAULT="10.89.0.0/24"   # relay 客户端 WG 子网（A=.1，客户端 .2+）
WMF_FWMARK="0x8c20"                      # relay 全局出口用：标记 swgp/WG 自身流量以避免路由环
SYSTEMD_RESUME_SERVICE="/etc/systemd/system/wg-mimic-resume.service"
RESUME_MARKER="${STATE_DIR}/resume.cmd"

# ── OS / kernel compatibility ──────────────────────────────────────────────

detect_os_id() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        printf '%s' "${ID:-unknown}"
    else
        printf 'unknown'
    fi
}

kernel_ge_61() {
    awk -v r="$(uname -r)" 'BEGIN{
        split(r,a,"[.-]"); ma=a[1]+0; mi=a[2]+0;
        exit !(ma>6 || (ma==6 && mi>=1))
    }'
}

compat_os_report() {
    local id tier note
    id="$(detect_os_id)"
    tier="unknown"; note=""
    case "$id" in
        debian|ubuntu) tier="recommended"; note="官方 mimic .deb / apt" ;;
        arch) tier="good"; note="AUR: mimic-bpf" ;;
        fedora) tier="conditional"; note="内核≥6.1 可源码编译 mimic" ;;
        rhel|centos|rocky|almalinux|ol)
            tier="conditional"
            note="默认内核可能<6.1，需 elrepo kernel-ml 或换 Debian/Ubuntu" ;;
        alpine) tier="experimental"; note="无 DKMS，需源码编译 mimic；生产不推荐" ;;
        openwrt) tier="experimental"; note="见 mimic openwrt 分支或改用 Forwarder 旁路" ;;
        *) tier="unknown"; note="未验证，需内核≥6.1 + mimic" ;;
    esac
    if ! kernel_ge_61; then
        tier="unsupported"
        note="内核 $(uname -r) < 6.1，Mimic 无法运行"
    fi
    printf 'OS_ID=%s\nCOMPAT_TIER=%s\nCOMPAT_NOTE=%s\n' "$id" "$tier" "$note"
}

ensure_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    {
        printf 'net.ipv4.ip_forward=1\n'
        printf 'net.ipv6.conf.all.forwarding=1\n'
    } >"$SYSCTL_FILE"
}

# ── utilities ──────────────────────────────────────────────────────────────

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*" >&2; }
ok() { printf '[OK] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

require_root() { [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

sanitize_id() {
    local s="$1"
    s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')"
    [[ -n "$s" ]] || die "无效的 PROFILE_ID"
    printf '%s' "$s"
}

wg_iface_for() {
    local id name h
    id="$(sanitize_id "$1")"
    name="wm-${id}"
    if [[ "${#name}" -le 15 ]]; then
        printf '%s' "$name"
    else
        # Linux caps network interface names at 15 chars (IFNAMSIZ-1); a longer
        # name makes wg-quick fail. Derive a stable short name for long ids.
        h="$(printf '%s' "$id" | md5sum 2>/dev/null | cut -c1-11)"
        [[ -n "$h" ]] || h="$(printf '%s' "$id" | cksum | tr -cd '0-9' | cut -c1-11)"
        printf 'wm-%s' "$h"
    fi
}

ensure_dirs() {
    install -d -m 700 "$CONFIG_DIR" "$PROFILES_DIR" "$CODES_DIR" "$KEYS_DIR" "$STATE_DIR"
    install -d -m 755 "$LIBEXEC_DIR" "$MIMIC_CONF_DIR" "$NFT_DIR"
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
}

# ── profile env I/O ────────────────────────────────────────────────────────

profile_env_path() { printf '%s/%s.env' "$PROFILES_DIR" "$(sanitize_id "$1")"; }

write_profile_kv() {
    local path="$1"; shift
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$@" >"$tmp"
    install -m 600 "$tmp" "$path"
    rm -f "$tmp"
}

load_profile() {
    local id="$1"
    local path; path="$(profile_env_path "$id")"
    [[ -f "$path" ]] || die "线路不存在：$id"
    # shellcheck disable=SC1090
    source "$path"
    PROFILE_ID="$(sanitize_id "${PROFILE_ID:-$id}")"
}

list_profile_ids() {
    local f id
    for f in "$PROFILES_DIR"/*.env; do
        [[ -f "$f" ]] || continue
        id="$(basename "$f" .env)"
        printf '%s\n' "$id"
    done
}

resolve_profile_id() {
    local req="${1:-}"
    local ids=() id
    while IFS= read -r id; do ids+=("$id"); done < <(list_profile_ids)
    if [[ -n "$req" ]]; then
        sanitize_id "$req"
        return
    fi
    [[ "${#ids[@]}" -eq 1 ]] && printf '%s' "${ids[0]}" && return
    die "请指定线路 ID（wm list-profiles 查看）"
}

# Interactive picker: print existing lines, resolve to ONE id on stdout.
# Listing/prompts go to stderr so callers can capture the id via $(...).
# Returns non-zero (empty stdout) when there are no lines or the user cancels,
# so menu actions skip gracefully instead of aborting the whole script with
# "无效的 PROFILE_ID".
menu_pick_profile() {
    local want_role="${1:-}"
    local ids=() id role path sel
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done \
        < <(list_profile_ids 2>/dev/null || true)
    if [[ -n "$want_role" && "${#ids[@]}" -gt 0 ]]; then
        local filtered=()
        for id in "${ids[@]}"; do
            path="$(profile_env_path "$id")"
            role="$(grep -m1 '^ROLE=' "$path" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
            [[ "$role" == "$want_role" ]] && filtered+=("$id")
        done
        ids=(${filtered[@]+"${filtered[@]}"})
    fi
    if [[ "${#ids[@]}" -eq 0 ]]; then
        if [[ -n "$want_role" ]]; then
            warn "暂无 ${want_role} 线路（relay 先 wm import-exit-code；exit 先 wm create-exit）"
        else
            warn "暂无线路，请先用 1)IX 创建组网线路 或 2)公网入口导入接入码"
        fi
        return 1
    fi
    printf '现有线路：\n' >&2
    local _i=1
    for id in "${ids[@]}"; do
        path="$(profile_env_path "$id")"
        role="$(grep -m1 '^ROLE=' "$path" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        printf '  %d) %s%s\n' "$_i" "$id" "${role:+  [$role]}" >&2
        _i=$((_i + 1))
    done
    if [[ "${#ids[@]}" -eq 1 ]]; then
        printf '（仅一条线路，已自动选中 %s）\n' "${ids[0]}" >&2
        printf '%s' "${ids[0]}"
        return 0
    fi
    read -r -p "选择编号或线路 ID（回车取消）: " sel </dev/tty
    sel="$(trim "$sel")"
    [[ -n "$sel" ]] || { warn "已取消"; return 1; }
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#ids[@]} )); then
        printf '%s' "${ids[$((10#$sel - 1))]}"
        return 0
    fi
    sel="$(sanitize_id "$sel" 2>/dev/null)" || { warn "无效的线路 ID"; return 1; }
    for id in "${ids[@]}"; do
        [[ "$id" == "$sel" ]] && { printf '%s' "$sel"; return 0; }
    done
    warn "线路不存在：$sel"
    return 1
}

# 按编号/ID 选择某线路下的一条规则（列表打到 stderr，选中 id 打到 stdout）。
menu_pick_rule() {
    local pid="$1" rids=() rid sel note path _i=1
    while IFS= read -r rid; do [[ -n "$rid" ]] && rids+=("$rid"); done \
        < <(list_rule_ids "$pid" 2>/dev/null || true)
    if [[ "${#rids[@]}" -eq 0 ]]; then warn "该线路暂无规则（先用 新增规则）"; return 1; fi
    printf '现有规则：\n' >&2
    for rid in "${rids[@]}"; do
        note=""; path="$(rule_env_path "$pid" "$rid")"
        [[ -f "$path" ]] && note="$(grep -m1 '^RULE_NOTE=' "$path" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        printf '  %d) %s%s\n' "$_i" "$rid" "${note:+  （$note）}" >&2
        _i=$((_i + 1))
    done
    if [[ "${#rids[@]}" -eq 1 ]]; then
        printf '（仅一条规则，已自动选中 %s）\n' "${rids[0]}" >&2
        printf '%s' "${rids[0]}"; return 0
    fi
    read -r -p "选择编号或规则 ID（回车取消）: " sel </dev/tty
    sel="$(trim "$sel")"
    [[ -n "$sel" ]] || { warn "已取消"; return 1; }
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#rids[@]} )); then
        printf '%s' "${rids[$((10#$sel - 1))]}"; return 0
    fi
    for rid in "${rids[@]}"; do [[ "$rid" == "$sel" ]] && { printf '%s' "$sel"; return 0; }; done
    warn "规则不存在：$sel"; return 1
}

# 按编号/名称选择某网关下的一个客户端。
menu_pick_client() {
    local pid="$1" cids=() cid sel ip path _i=1
    while IFS= read -r cid; do [[ -n "$cid" ]] && cids+=("$cid"); done \
        < <(list_client_ids "$pid" 2>/dev/null || true)
    if [[ "${#cids[@]}" -eq 0 ]]; then warn "该网关暂无客户端（先用 新增客户端）"; return 1; fi
    printf '现有客户端：\n' >&2
    for cid in "${cids[@]}"; do
        ip=""; path="$(client_env_path "$pid" "$cid")"
        [[ -f "$path" ]] && ip="$(grep -m1 '^CLIENT_IP=' "$path" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        printf '  %d) %s%s\n' "$_i" "$cid" "${ip:+  $ip}" >&2
        _i=$((_i + 1))
    done
    if [[ "${#cids[@]}" -eq 1 ]]; then
        printf '（仅一个客户端，已自动选中 %s）\n' "${cids[0]}" >&2
        printf '%s' "${cids[0]}"; return 0
    fi
    read -r -p "选择编号或客户端名（回车取消）: " sel </dev/tty
    sel="$(trim "$sel")"
    [[ -n "$sel" ]] || { warn "已取消"; return 1; }
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#cids[@]} )); then
        printf '%s' "${cids[$((10#$sel - 1))]}"; return 0
    fi
    for cid in "${cids[@]}"; do [[ "$cid" == "$sel" ]] && { printf '%s' "$sel"; return 0; }; done
    warn "客户端不存在：$sel"; return 1
}

# ── JSON / pairing code (python3) ──────────────────────────────────────────

base64url_encode() {
    python3 -c 'import base64,sys; d=sys.stdin.buffer.read(); print(base64.urlsafe_b64encode(d).decode().rstrip("="))'
}

base64url_decode() {
    python3 -c 'import base64,sys; s=sys.stdin.read().strip(); s+="="*(-len(s)%4); sys.stdout.buffer.write(base64.urlsafe_b64decode(s))'
}

parse_wmgf_code() {
    local code="$1"
    [[ "$code" == WMGF1:* ]] || die "接入码必须以 WMGF1: 开头"
    printf '%s' "${code#WMGF1:}" | base64url_decode
}

detect_public_ipv4() {
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
        || true
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

prompt_port() {
    local var="$1" text="$2" default="${3:-}"
    local _pval=""
    while true; do
        prompt _pval "$text" "$default"
        if validate_port "$_pval"; then
            printf -v "$var" '%s' "$_pval"
            return 0
        fi
        warn "端口必须是 1–65535 的数字"
    done
}

json_get() {
    local json="$1" key="$2"
    python3 -c 'import json,sys; o=json.load(sys.stdin); print(o.get(sys.argv[1],""))' "$key" <<<"$json"
}

validate_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -ra o <<<"$ip"
    (( ${o[0]} <= 255 && ${o[1]} <= 255 && ${o[2]} <= 255 && ${o[3]} <= 255 ))
}

validate_proto() {
    case "$1" in tcp|udp|both) return 0 ;; *) return 1 ;; esac
}

# ── WireGuard mesh helpers ─────────────────────────────────────────────────

wg_genkey() { wg genkey; }
wg_pubkey_of() { printf '%s' "$1" | wg pubkey; }

default_mesh_subnet() { printf '10.88.0.0/24'; }
default_ix_ip()       { printf '10.88.0.2'; }
default_ingress_ip()  { printf '10.88.0.1'; }

# 从 /24 网段取主机 IP：10.90.0.0/24 + 2 → 10.90.0.2
mesh_host_ip() { local s="${1%%/*}"; printf '%s.%s' "${s%.*}" "$2"; }

# 扫描已有线路占用的 mesh 网段(10.N.0.0/24 的 N),返回第一个空闲的,避免多条线路
# 撞同一网段/虚拟IP;预留 10.89(relay 客户端默认子网)。无线路时仍回 10.88(单线路旧默认)。
next_free_mesh_subnet() {
    local p sub used=" 89 " n
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        sub="$(grep -m1 '^WG_MESH_SUBNET=' "$p" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        [[ "$sub" =~ ^10\.([0-9]+)\. ]] && used="${used}${BASH_REMATCH[1]} "
    done
    for n in 88 90 91 92 93 94 95 96 97 98 99; do
        [[ "$used" == *" $n "* ]] || { printf '10.%s.0.0/24' "$n"; return 0; }
    done
    printf '10.88.0.0/24'
}

# ── rule env I/O (multi-rule) ──────────────────────────────────────────────

rules_dir_for() { printf '%s/%s/rules' "$PROFILES_DIR" "$(sanitize_id "$1")"; }
rule_env_path() { printf '%s/%s.env' "$(rules_dir_for "$1")" "$(sanitize_id "$2")"; }

list_rule_ids() {
    local d f; d="$(rules_dir_for "$1")"
    [[ -d "$d" ]] || return 0
    for f in "$d"/*.env; do
        [[ -f "$f" ]] && basename "$f" .env
    done
}

load_rule() {
    local p; p="$(rule_env_path "$1" "$2")"
    [[ -f "$p" ]] || return 1
    RULE_ID=""; RULE_NOTE=""; RULE_ENABLED="true"; TRANSIT_PORT=""
    LANDING_HOST=""; LANDING_PORT=""; FORWARD_PROTO="both"; CLIENT_PORT=""
    # shellcheck disable=SC1090
    source "$p"
}

write_rule() {
    local pid="$1" rid="$2"; shift 2
    local d; d="$(rules_dir_for "$pid")"
    install -d -m 700 "$d"
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$@" >"$tmp"
    install -m 600 "$tmp" "$(rule_env_path "$pid" "$rid")"
    rm -f "$tmp"
}

generate_unique_rule_id() {
    local pid="$1" base="${2:-rule}" n=1 rid
    rid="$base"
    while [[ -f "$(rule_env_path "$pid" "$rid")" ]]; do
        n=$((n + 1)); rid="${base}-${n}"
    done
    printf '%s' "$rid"
}

# ── 商家端口池（IX 端口有限 → 每规则从池中分配一个 transit 端口）──────────────

# Expand a pool spec ("40000-40010,40020,40030-40031") into one port per line.
expand_port_pool() {
    local spec="$1" part lo hi p _parts
    IFS=',' read -ra _parts <<<"$spec"
    for part in "${_parts[@]}"; do
        part="$(trim "$part")"
        [[ -z "$part" ]] && continue
        if [[ "$part" == *-* ]]; then
            lo="${part%-*}"; hi="${part#*-}"
            [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
            (( lo >= 1 && hi <= 65535 && lo <= hi )) || continue
            for ((p = lo; p <= hi; p++)); do printf '%s\n' "$p"; done
        elif [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 1 && part <= 65535 )); then
            printf '%s\n' "$part"
        fi
    done
}

validate_port_pool() {
    local n; n="$(expand_port_pool "$1" | awk 'NF{c++} END{print c+0}')"
    (( n >= 1 ))
}

# Ports already taken by this profile's rules (their TRANSIT_PORT = merchant port).
pool_used_ports() {
    local pid="$1" rid
    for rid in $(list_rule_ids "$pid"); do
        (
            load_rule "$pid" "$rid" || exit 0
            [[ -n "${TRANSIT_PORT:-}" ]] && printf '%s\n' "$TRANSIT_PORT"
        )
    done
}

# First pool port not yet used by a rule; non-zero exit when pool exhausted.
pool_alloc_port() {
    local pid="$1" spec="$2" reserve="${3:-}" used p
    used="$( { pool_used_ports "$pid"; [[ -n "$reserve" ]] && printf '%s\n' "$reserve"; } | sort -u )"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        grep -qxF "$p" <<<"$used" && continue
        printf '%s' "$p"; return 0
    done < <(expand_port_pool "$spec")
    return 1
}

# True when PORT belongs to the expanded pool SPEC. Pure-bash match (no `grep -q`):
# under `set -o pipefail`, grep -q exits on the first match and the still-writing
# expand_port_pool gets SIGPIPE, making the pipeline return non-zero and falsely
# report "not in pool" (timing-dependent; hits the first port the hardest).
pool_contains() {
    local spec="$1" port="$2" p
    for p in $(expand_port_pool "$spec"); do
        [[ "$p" == "$port" ]] && return 0
    done
    return 1
}

# How many pool ports are left for this profile (echoes total/used/free counts).
pool_stats() {
    local pid="$1" spec="$2" total used
    total="$(expand_port_pool "$spec" | awk 'NF{c++} END{print c+0}')"
    used="$(pool_used_ports "$pid" | sort -u | awk 'NF{c++} END{print c+0}')"
    printf '%s %s %s' "$total" "$used" "$(( total - used ))"
}

# True when PORT is already a rule's TRANSIT_PORT in this profile (optionally
# excluding one rule id, e.g. the rule being edited).
transit_port_in_use() {
    local pid="$1" port="$2" exclude="${3:-}" rid
    for rid in $(list_rule_ids "$pid"); do
        [[ "$rid" == "$exclude" ]] && continue
        (
            load_rule "$pid" "$rid" || exit 1
            [[ "${TRANSIT_PORT:-}" == "$port" ]]
        ) && return 0
    done
    return 1
}

rules_to_tsv() {
    local pid="$1" rid
    for rid in $(list_rule_ids "$pid"); do
        (
            load_rule "$pid" "$rid" || exit 0
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$RULE_ID" "${RULE_NOTE:-}" "$TRANSIT_PORT" \
                "$LANDING_HOST" "$LANDING_PORT" "${FORWARD_PROTO:-both}"
        )
    done
}

# ── access code (WMGF1, code_schema=5, WG mesh) ─────────────────────────────

render_code_json() {
    local rules_tsv rules_b64 created
    [[ "${ROLE:-}" == "nat-transit" ]] || die "仅 IX(nat-transit) 线路可生成接入码"
    rules_tsv="$(rules_to_tsv "$PROFILE_ID")"
    [[ -n "$rules_tsv" ]] || die "线路 ${PROFILE_ID} 暂无转发规则，无法生成接入码"
    rules_b64="$(printf '%s' "$rules_tsv" | base64url_encode)"
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$PROFILE_ID" "${PROFILE_NAME:-$PROFILE_ID}" "$WG_MESH_SUBNET" \
        "$WG_IX_IP" "$WG_INGRESS_IP" "$WG_PUBLIC_KEY" "$INGRESS_PRIVKEY_B64" \
        "$IX_ENDPOINT_HOST" "$WG_PORT" "$WG_MTU" "${MIMIC_KEEPALIVE:-300:::}" \
        "${FORWARD_PROTO:-both}" "$rules_b64" "$created" \
        "${IP_VERSION:-4}" "${WG_MESH_SUBNET6:-}" "${WG_IX_IP6:-}" "${WG_INGRESS_IP6:-}" <<'PY'
import base64, json, sys
( pid, pname, subnet, ix_ip, ing_ip, ix_pub, ing_priv_b64, endpoint,
  wg_port, wg_mtu, keepalive, fproto, rules_b64, created,
  ip_version, subnet6, ix_ip6, ing_ip6 ) = sys.argv[1:19]
def decode_tsv(b):
    b = b + "=" * (-len(b) % 4)
    return base64.urlsafe_b64decode(b.encode()).decode()
rules = []
for line in decode_tsv(rules_b64).splitlines():
    if not line.strip():
        continue
    f = line.split("\t")
    while len(f) < 6:
        f.append("")
    rules.append({
        "rule_id": f[0], "note": f[1],
        "transit_port": int(f[2]) if f[2] else 0,
        "landing_host": f[3],
        "landing_port": int(f[4]) if f[4] else 0,
        "proto": f[5] or "both",
    })
obj = {
    "version": 1, "code_schema": 5, "project": "wg-mimic-fabric",
    "role": "nat-transit-code", "profile_id": pid, "profile_name": pname,
    "ip_version": ip_version or "4",
    "wg_mesh_subnet": subnet, "ix_wg_ip": ix_ip, "ingress_wg_ip": ing_ip,
    "ix_wg_pubkey": ix_pub, "ingress_wg_privkey_b64": ing_priv_b64,
    "ix_endpoint_host": endpoint, "wg_port": int(wg_port), "wg_mtu": int(wg_mtu),
    "mimic_keepalive": keepalive, "forward_proto": fproto,
    "rules": rules, "rules_b64": rules_b64, "created_at": created,
}
if subnet6:
    obj["wg_mesh_subnet6"] = subnet6
    obj["ix_wg_ip6"] = ix_ip6
    obj["ingress_wg_ip6"] = ing_ip6
print(json.dumps(obj, separators=(",", ":")))
PY
}

generate_code() {
    render_code_json | base64url_encode | sed 's/^/WMGF1:/'
}

# 出口接入码（code_schema=6, nat-exit-code）：A↔B 混淆组网 + 全局出口用。
# 复用 transit 的 WG 字段，去掉 rules，加 obfs/swgp/exit_mode。
render_exit_code_json() {
    [[ "${ROLE:-}" == "exit" ]] || die "仅 exit 线路可生成出口接入码"
    local created; created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$PROFILE_ID" "${PROFILE_NAME:-$PROFILE_ID}" "$WG_MESH_SUBNET" \
        "$WG_IX_IP" "$WG_INGRESS_IP" "$WG_PUBLIC_KEY" "$INGRESS_PRIVKEY_B64" \
        "$IX_ENDPOINT_HOST" "$WG_PORT" "$WG_MTU" "${MIMIC_KEEPALIVE:-300:::}" \
        "${OBFS_MODE:-swgp+mimic}" "${SWGP_MODE:-zero-overhead-2026}" "${SWGP_PSK:-}" "${SWGP_PORT:-0}" \
        "${EXIT_MODE:-global}" "$created" \
        "${IP_VERSION:-4}" "${WG_MESH_SUBNET6:-}" "${WG_IX_IP6:-}" "${WG_INGRESS_IP6:-}" <<'PY'
import json, sys
( pid, pname, subnet, ix_ip, ing_ip, ix_pub, ing_priv_b64, endpoint, wg_port, wg_mtu,
  keepalive, obfs, swgp_mode, swgp_psk, swgp_port, exit_mode, created,
  ip_version, subnet6, ix_ip6, ing_ip6 ) = sys.argv[1:22]
obj = {
    "version": 1, "code_schema": 6, "project": "wg-mimic-fabric",
    "role": "nat-exit-code", "profile_id": pid, "profile_name": pname,
    "ip_version": ip_version or "4",
    "wg_mesh_subnet": subnet, "ix_wg_ip": ix_ip, "ingress_wg_ip": ing_ip,
    "ix_wg_pubkey": ix_pub, "ingress_wg_privkey_b64": ing_priv_b64,
    "ix_endpoint_host": endpoint, "wg_port": int(wg_port), "wg_mtu": int(wg_mtu),
    "mimic_keepalive": keepalive, "obfs_mode": obfs, "swgp_mode": swgp_mode,
    "swgp_psk": swgp_psk, "swgp_port": int(swgp_port), "exit_mode": exit_mode,
    "created_at": created,
}
if subnet6:
    obj["wg_mesh_subnet6"] = subnet6
    obj["ix_wg_ip6"] = ix_ip6
    obj["ingress_wg_ip6"] = ing_ip6
print(json.dumps(obj, separators=(",", ":")))
PY
}

generate_exit_code() {
    render_exit_code_json | base64url_encode | sed 's/^/WMGF1:/'
}

parse_code() {
    local code="$1" json schema role
    json="$(parse_wmgf_code "$code")"
    schema="$(json_get "$json" code_schema)"
    role="$(json_get "$json" role)"
    # 公共 WG 字段（transit-code 与 exit-code 都有）
    CODE_PROFILE_ID="$(json_get "$json" profile_id)"
    CODE_WG_MESH_SUBNET="$(json_get "$json" wg_mesh_subnet)"
    CODE_IX_WG_IP="$(json_get "$json" ix_wg_ip)"
    CODE_INGRESS_WG_IP="$(json_get "$json" ingress_wg_ip)"
    CODE_IX_WG_PUBKEY="$(json_get "$json" ix_wg_pubkey)"
    CODE_INGRESS_PRIVKEY_B64="$(json_get "$json" ingress_wg_privkey_b64)"
    CODE_IX_ENDPOINT_HOST="$(json_get "$json" ix_endpoint_host)"
    CODE_WG_PORT="$(json_get "$json" wg_port)"
    CODE_WG_MTU="$(json_get "$json" wg_mtu)"
    CODE_MIMIC_KEEPALIVE="$(json_get "$json" mimic_keepalive)"
    CODE_IP_VERSION="$(json_get "$json" ip_version)"
    CODE_WG_MESH_SUBNET6="$(json_get "$json" wg_mesh_subnet6)"
    CODE_IX_WG_IP6="$(json_get "$json" ix_wg_ip6)"
    CODE_INGRESS_WG_IP6="$(json_get "$json" ingress_wg_ip6)"
    if [[ "$role" == "nat-transit-code" && "$schema" == "5" ]]; then
        CODE_KIND="transit"
        CODE_FORWARD_PROTO="$(json_get "$json" forward_proto)"
        CODE_RULES_TSV="$(json_get "$json" rules_b64 | base64url_decode)"
    elif [[ "$role" == "nat-exit-code" && "$schema" == "6" ]]; then
        CODE_KIND="exit"
        CODE_OBFS_MODE="$(json_get "$json" obfs_mode)"
        CODE_SWGP_MODE="$(json_get "$json" swgp_mode)"
        CODE_SWGP_PSK="$(json_get "$json" swgp_psk)"
        CODE_SWGP_PORT="$(json_get "$json" swgp_port)"
        CODE_EXIT_MODE="$(json_get "$json" exit_mode)"
    else
        die "不是有效的接入码（需 nat-transit-code/schema5 或 nat-exit-code/schema6）"
    fi
}

ensure_mimic() {
    command_exists mimic || die "未找到 mimic，请安装：apt install mimic mimic-dkms"
    modprobe mimic 2>/dev/null || warn "mimic 内核模块未加载，请安装 mimic-dkms"
}

mimic_module_loaded() { lsmod 2>/dev/null | awk '$1=="mimic"{f=1} END{exit !f}'; }

# True when mimic CLI is installed but the module cannot load now — typically a
# DKMS build for a not-yet-running kernel; a reboot will usually fix it.
mimic_needs_reboot() {
    mimic_module_loaded && return 1
    command_exists mimic || return 1
    modprobe mimic 2>/dev/null && return 1
    return 0
}

# Install a one-shot unit that, on next boot, loads mimic and resumes the
# pending command (e.g. "start ix-nat"), then removes itself.
install_resume_unit() {
    local cmd="$1"
    ensure_dirs
    printf '%s\n' "$cmd" >"$RESUME_MARKER"
    chmod 600 "$RESUME_MARKER"
    local tmp; tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric post-reboot resume
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WM_BIN} resume

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_RESUME_SERVICE"
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable wg-mimic-resume.service 2>/dev/null || true
}

resume_after_boot() {
    require_root
    modprobe mimic 2>/dev/null || true
    local cmd=""
    [[ -f "$RESUME_MARKER" ]] && cmd="$(cat "$RESUME_MARKER" 2>/dev/null || true)"
    systemctl disable wg-mimic-resume.service 2>/dev/null || true
    rm -f "$SYSTEMD_RESUME_SERVICE" "$RESUME_MARKER"
    systemctl daemon-reload 2>/dev/null || true
    if [[ -n "$cmd" ]]; then
        info "开机自动继续：wm ${cmd}"
        # shellcheck disable=SC2086
        main $cmd
    fi
}

# Interactive: offer to reboot now (optionally auto-resuming a command on boot).
offer_reboot() {
    local resume_cmd="${1:-}"
    if [[ ! -e /dev/tty ]]; then
        warn "mimic 内核模块未加载，需重启后生效：sudo reboot（之后 wm ${resume_cmd:-start <ID>}）"
        return 0
    fi
    printf '\n检测到 mimic 内核模块需重启后才能加载（运行内核与已编译模块不一致）。\n' >&2
    [[ -n "$resume_cmd" ]] && printf '  1) 现在重启，开机后自动继续：wm %s\n' "$resume_cmd" >&2
    printf '  2) 现在重启（开机后手动操作）\n' >&2
    printf '  0) 暂不重启\n' >&2
    local ans=""; read -r -p "选择: " ans </dev/tty || ans=""
    case "$(trim "$ans")" in
        1) [[ -n "$resume_cmd" ]] && install_resume_unit "$resume_cmd"; warn "正在重启..."; reboot ;;
        2) warn "正在重启..."; reboot ;;
        *) warn "未重启；稍后 sudo reboot 后再执行 wm ${resume_cmd:-start <ID>}" ;;
    esac
}

detect_default_iface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# First global IPv4 bound to the default interface — the inbound/bindable IP,
# which (unlike curl's egress IP) is what Mimic must bind and clients reach.
detect_local_ipv4() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || iface="$(detect_default_iface)"
    [[ -n "$iface" ]] || return 0
    ip -4 addr show dev "$iface" scope global 2>/dev/null \
        | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

# Resolve a host to an IP. Literal IPv4/IPv6 pass through unchanged; hostnames
# are resolved (getent, then python3 fallback). Used by nft render + DDNS so
# domain landings/endpoints work and IP changes can be detected.
resolve_host_ip() {
    local h="$1" ip=""
    [[ -z "$h" ]] && return 0
    if [[ "$h" == *:* ]] || [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$h"; return 0
    fi
    ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1; exit}')"
    [[ -z "$ip" ]] && ip="$(getent ahosts "$h" 2>/dev/null | awk 'NR==1{print $1; exit}')"
    if [[ -z "$ip" ]] && command_exists python3; then
        ip="$(python3 -c 'import socket,sys
try: print(socket.getaddrinfo(sys.argv[1],None)[0][4][0])
except Exception: pass' "$h" 2>/dev/null)"
    fi
    printf '%s' "$ip"
}

validate_mtu() {
    local mtu="$1"
    [[ "$mtu" =~ ^[0-9]+$ ]] || die "MTU 必须是数字"
    (( mtu >= 1280 && mtu <= 1500 )) || die "MTU 应在 1280–1500 之间（当前 ${mtu}）"
}

format_mimic_ip() {
    local ip="$1"
    if [[ "$ip" == *:* ]]; then printf '[%s]' "$ip"; else printf '%s' "$ip"; fi
}

# ── download / upgrade ─────────────────────────────────────────────────────

mirror_url() {
    local base="$1" path="$2"
    printf '%s%s' "${base%/}/" "${path#/}"
}

download_with_mirrors() {
    local relpath="$1" dest="$2" ref="${3:-main}"
    local repo="${WMF_REPO:-ike-sh/wg-mimic-fabric}"
    local mirrors="" m
    IFS=',' read -ra mirrors <<< "${WMF_GITHUB_MIRRORS:-$DEFAULT_GITHUB_MIRRORS}"
    if curl -fsSL -H "Accept: application/vnd.github.raw+json" \
        -o "$dest" "https://api.github.com/repos/${repo}/contents/${relpath}?ref=${ref}" 2>/dev/null; then
        return 0
    fi
    for m in "${mirrors[@]}" "" ; do
        local url
        if [[ -n "$m" ]]; then
            url="$(mirror_url "$m" "https://raw.githubusercontent.com/${repo}/${ref}/${relpath}")"
        else
            url="https://raw.githubusercontent.com/${repo}/${ref}/${relpath}?ts=$(date +%s)"
        fi
        if curl -fsSL -o "$dest" "$url" 2>/dev/null; then return 0; fi
    done
    return 1
}

# 下载任意 GitHub/api/raw 资源：优先走镜像（国内可达），逐个轮询，最后直连兜底。
# $1=完整 URL（github.com / api.github.com / *.githubusercontent.com）  $2=落地文件
gh_curl() {
    local url="$1" dest="$2" m u mirrors=()
    IFS=',' read -ra mirrors <<< "${WMF_GITHUB_MIRRORS:-$DEFAULT_GITHUB_MIRRORS}"
    for m in "${mirrors[@]}" "" ; do
        if [[ -n "$m" ]]; then u="$(mirror_url "$m" "$url")"; else u="$url"; fi
        if curl -fsSL --connect-timeout 10 --max-time 300 --retry 1 -o "$dest" "$u" 2>/dev/null \
            && [[ -s "$dest" ]]; then
            return 0
        fi
    done
    return 1
}

upgrade_script() {
    require_root
    local ref="${WMF_TAG:-main}"
    [[ "$ref" == v* ]] || [[ "$ref" == "main" ]] || ref="v${ref}"
    local tmp remote_ver
    tmp="$(mktemp)"
    info "下载 ${WMF_REPO:-ike-sh/wg-mimic-fabric} @ ${ref} ..."
    download_with_mirrors "install.sh" "$tmp" "$ref" || die "下载 install.sh 失败"
    remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')"
    local cur="$SCRIPT_VERSION"
    if [[ -n "$remote_ver" && "$remote_ver" == "$cur" && "${WMF_UPGRADE_YES:-}" != "1" ]]; then
        ok "已是最新版本：${cur}"
        rm -f "$tmp"
        return 0
    fi
    if [[ "${WMF_UPGRADE_YES:-}" != "1" ]]; then
        [[ -e /dev/tty ]] || { rm -f "$tmp"; die "非交互环境，请用 WMF_UPGRADE_YES=1 wm upgrade-script"; }
        # 循环读取 + 容错：读空（SSH 偶发漏键）就重问，而不是直接按 N 取消
        local ans=""
        while true; do
            printf '当前 %s → 远端 %s。确认升级？[y/N] ' "$cur" "${remote_ver:-?}" >&2
            read -r ans </dev/tty || { rm -f "$tmp"; die "无法读取确认输入，请用 WMF_UPGRADE_YES=1 wm upgrade-script"; }
            case "$(trim "$ans")" in
                [yY]|[yY][eE][sS]) break ;;
                [nN]|[nN][oO])     rm -f "$tmp"; die "已取消" ;;
                "")               warn "读到空输入，请重新输入 y 或 n（Ctrl-C 退出）" ;;
                *)                warn "请输入 y 或 n" ;;
            esac
        done
    fi
    install -d -m 755 "$BACKUP_DIR"
    [[ -f "$WM_CLI_INSTALL_SH" ]] && cp -a "$WM_CLI_INSTALL_SH" "${BACKUP_DIR}/install.sh.bak.$(date +%Y%m%d%H%M%S)"
    install -m 755 "$tmp" "$WM_CLI_INSTALL_SH"
    rm -f "$tmp"
    ok "已升级至 ${remote_ver:-unknown}"
}

# ── DDNS（域名 IP 变化自动刷新）──────────────────────────────────────────────

ddns_state_file() { printf '%s/ddns.state' "$STATE_DIR"; }

ddns_state_get() {
    local k="$1" f; f="$(ddns_state_file)"
    [[ -f "$f" ]] || return 0
    grep -m1 "^${k}=" "$f" 2>/dev/null | cut -d= -f2-
}

ddns_state_set() {
    local k="$1" v="$2" f; f="$(ddns_state_file)"
    install -d -m 700 "$STATE_DIR"
    [[ -f "$f" ]] || : >"$f"
    if grep -q "^${k}=" "$f" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
    chmod 600 "$f"
}

# Re-resolve ingress WG endpoints; on change update the live peer endpoint.
# Landing domains follow automatically because apply_nft_all re-resolves them.
ddns_refresh() {
    require_root
    ensure_dirs
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${ENABLED:-true}" == "true" ]] || exit 0
            [[ "${ROLE:-}" == "nat-ingress" && -n "${IX_ENDPOINT_HOST:-}" ]] || exit 0
            [[ "$IX_ENDPOINT_HOST" =~ [a-zA-Z] ]] || exit 0
            local newip key old wg_iface
            newip="$(resolve_host_ip "$IX_ENDPOINT_HOST")"
            [[ -n "$newip" ]] || exit 0
            key="endpoint:${PROFILE_ID}"
            old="$(ddns_state_get "$key")"
            if [[ "$newip" != "$old" ]]; then
                wg_iface="$(wg_iface_for "$PROFILE_ID")"
                wg set "$wg_iface" peer "$WG_PEER_PUBLIC_KEY" \
                    endpoint "$(format_mimic_ip "$newip"):${WG_PORT}" 2>/dev/null || true
                ddns_state_set "$key" "$newip"
                info "DDNS ${PROFILE_ID}: ${IX_ENDPOINT_HOST} ${old:-?} → ${newip}"
            fi
        )
    done
    apply_nft_all
    ok "DDNS 刷新完成"
}

install_ddns_timer() {
    local tmp; tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric DDNS refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WM_BIN} ddns-refresh
EOF
    install -m 644 "$tmp" "$SYSTEMD_DDNS_SERVICE"
    cat >"$tmp" <<'EOF'
[Unit]
Description=wg-mimic-fabric DDNS timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_DDNS_TIMER"
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
}

ddns_enable() {
    require_root
    install_ddns_timer
    systemctl enable --now wg-mimic-ddns.timer 2>/dev/null || true
    ok "DDNS 定时已启用（每 3 分钟）"
}

ddns_disable() {
    require_root
    systemctl disable --now wg-mimic-ddns.timer 2>/dev/null || true
    ok "DDNS 定时已停用"
}

ddns_status() {
    systemctl list-timers wg-mimic-ddns.timer --no-pager 2>/dev/null || true
    if [[ -f "$(ddns_state_file)" ]]; then
        printf '── 已解析 ──\n'; cat "$(ddns_state_file)"
    else
        printf '（无 DDNS 状态）\n'
    fi
}

# ── 主备（手动切换，对标 ix-transit「不自动切换」安全边界）─────────────────────

set_or_append_kv() {
    local f="$1" k="$2" v="$3"
    if grep -q "^${k}=" "$f" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
}

group_members() {
    local grp="$1" p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${LINE_GROUP:-}" == "$grp" ]] && printf '%s\n' "$PROFILE_ID"
        )
    done
}

set_line_group() {
    local id grp role pri; id="$(resolve_profile_id "${1:-}")"; grp="${2:-}"; role="${3:-backup}"; pri="${4:-100}"
    require_root
    [[ -n "$grp" ]] || die "用法: wm set-group <ID> <组名> [primary|backup|standalone] [优先级]"
    case "$role" in primary|backup|standalone) ;; *) die "角色只能 primary/backup/standalone" ;; esac
    load_profile "$id"
    local path; path="$(profile_env_path "$PROFILE_ID")"
    set_or_append_kv "$path" LINE_GROUP "$grp"
    set_or_append_kv "$path" LINE_ROLE "$role"
    set_or_append_kv "$path" LINE_PRIORITY "$pri"
    ok "已设置 ${PROFILE_ID}: group=${grp} role=${role} pri=${pri}"
}

list_groups() {
    printf '线路分组：\n'
    local p out
    out="$(
        for p in "$PROFILES_DIR"/*.env; do
            [[ -f "$p" ]] || continue
            (
                # shellcheck disable=SC1090
                source "$p"
                [[ -n "${LINE_GROUP:-}" ]] || exit 0
                printf '%s\t%s\t%s\t%s\t%s\n' "$LINE_GROUP" "$PROFILE_ID" \
                    "${LINE_ROLE:-standalone}" "${LINE_PRIORITY:-100}" "${ENABLED:-true}"
            )
        done | sort
    )"
    [[ -n "$out" ]] || { printf '  (无分组线路；用 wm set-group 设置)\n'; return; }
    printf '%s\n' "$out" | awk -F'\t' '{printf "  [%s] %s  role=%s pri=%s enabled=%s\n",$1,$2,$3,$4,$5}'
}

switch_line() {
    local grp target members m found=0; grp="${1:-}"; target="$(sanitize_id "${2:-}")"
    require_root
    [[ -n "$grp" && -n "${2:-}" ]] || die "用法: wm switch-line <组名> <目标线路ID>"
    members="$(group_members "$grp")"
    [[ -n "$members" ]] || die "分组无成员：$grp"
    while IFS= read -r m; do [[ "$m" == "$target" ]] && found=1; done <<<"$members"
    [[ "$found" == "1" ]] || die "目标不在分组 ${grp}：${target}"
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        if [[ "$m" == "$target" ]]; then start_profile "$m"; else stop_profile "$m" 2>/dev/null || true; fi
    done <<<"$members"
    ddns_state_set "active:${grp}" "$target"
    ok "已切换分组 ${grp} → ${target}"
}

health_all() {
    local id
    for id in $(list_profile_ids 2>/dev/null || true); do
        printf '──────── %s ────────\n' "$id"
        health_profile "$id" 2>/dev/null || true
    done
}

primary_backup_check() {
    local grp="${1:-}" active m
    [[ -n "$grp" ]] || die "用法: wm primary-backup-check <组名>"
    active="$(ddns_state_get "active:${grp}")"
    printf '分组 %s（active=%s）：\n' "$grp" "${active:-未记录}"
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        (
            load_profile "$m"
            local st mark=""
            st="$(health_profile "$m" 2>/dev/null | sed -n 's/^HEALTH_STATUS=//p')"
            [[ "$m" == "$active" ]] && mark=" [active]"
            printf '  %s  role=%s pri=%s enabled=%s health=%s%s\n' \
                "$m" "${LINE_ROLE:-standalone}" "${LINE_PRIORITY:-100}" "${ENABLED:-true}" "${st:-unknown}" "$mark"
        )
    done <<<"$(group_members "$grp")"
    printf '主备为手动切换：wm switch-line %s <目标线路ID>\n' "$grp"
}

# ── render configs ─────────────────────────────────────────────────────────

# 混淆层判断（OBFS_MODE 缺省=mimic → 保持旧 nat-transit/nat-ingress 行为不变）。
obfs_has_mimic() { [[ "${OBFS_MODE:-mimic}" == *mimic* ]]; }
obfs_has_swgp()  { [[ "${OBFS_MODE:-mimic}" == *swgp* ]]; }
# 线上端口（mimic filter / swgp 对端）：含 swgp 时为 SWGP_PORT，否则 WG_PORT。
obfs_wire_port() { if obfs_has_swgp; then printf '%s' "${SWGP_PORT:-${WG_PORT}}"; else printf '%s' "${WG_PORT}"; fi; }

render_mimic_conf_for_profile() {
    local role="${ROLE:-}" port="${WG_PORT:-}"
    if [[ "$role" == "nat-transit" ]]; then
        # IX = WG listener. Mimic does EXACT IP matching and XDP/TC see the address
        # actually on the NIC — on NAT/floating-IP VPS that is the private NIC IP, NOT
        # the public endpoint (mimic#43). So match the WG port on the real local NIC IP
        # (auto-detected from WAN_IFACE; override via MIMIC_LOCAL_IP). The 0.0.0.0/[::]
        # wildcard only works on mimic builds >= 2025-11 (mimic#32) → last-resort only.
        local lip="${MIMIC_LOCAL_IP:-}"
        [[ -n "$lip" ]] || lip="$(detect_local_ipv4 "${WAN_IFACE:-}")"
        [[ -n "$lip" ]] || lip="0.0.0.0"
        printf 'filter = local=%s:%s\n' "$(format_mimic_ip "$lip")" "$port"
    elif [[ "$role" == "nat-ingress" ]]; then
        # ingress = WG dialer → match the remote IX endpoint IP it connects to
        printf 'filter = remote=%s:%s\n' "$(format_mimic_ip "${IX_ENDPOINT_HOST:-}")" "$port"
    elif [[ "$role" == "exit" ]]; then
        # exit = WG/ swgp listener；mimic 仅在 OBFS 含 mimic 时挂，端口对准线上端口
        obfs_has_mimic || return 0
        local lip="${MIMIC_LOCAL_IP:-}"
        [[ -n "$lip" ]] || lip="$(detect_local_ipv4 "${WAN_IFACE:-}")"
        [[ -n "$lip" ]] || lip="0.0.0.0"
        printf 'filter = local=%s:%s\n' "$(format_mimic_ip "$lip")" "$(obfs_wire_port)"
    elif [[ "$role" == "relay" ]]; then
        # relay = 拨号端 → match 远端 B 的线上端口
        obfs_has_mimic || return 0
        printf 'filter = remote=%s:%s\n' "$(format_mimic_ip "${IX_ENDPOINT_HOST:-}")" "$(obfs_wire_port)"
    fi
}

render_mimic_conf_iface() {
    local iface="$1" p
    {
        printf '# Generated by wg-mimic-fabric — iface %s\n' "$iface"
        printf 'log.verbosity = info\n'
        printf 'keepalive = 300:::\n'
        for p in "$PROFILES_DIR"/*.env; do
            [[ -f "$p" ]] || continue
            (
                # shellcheck disable=SC1090
                source "$p"
                [[ "${WAN_IFACE:-}" == "$iface" ]] || exit 0
                [[ "${ENABLED:-true}" == "true" ]] || exit 0
                render_mimic_conf_for_profile
            )
        done
    }
}

# mimic 的 XDP attach 模式只能用命令行 -x 传:mimic 0.7.0 的配置文件不支持
# xdp_mode 键,写进 .conf 会让 mimic 解析失败、丢掉 filter（隧道直接不通）。
# 取该网卡上 enabled profile 选定的模式（skb 优先，virtio 上 native 常挂）。
iface_xdp_mode() {
    local iface="$1" p mode="" any=""
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        mode="$(
            # shellcheck disable=SC1090
            source "$p" 2>/dev/null
            [[ "${WAN_IFACE:-}" == "$iface" ]] || exit 0
            [[ "${ENABLED:-true}" == "true" ]] || exit 0
            printf '%s' "${MIMIC_XDP_MODE:-}"
        )"
        [[ "$mode" == "skb" ]] && { printf 'skb'; return 0; }
        [[ -n "$mode" ]] && any="$mode"
    done
    [[ -n "$any" ]] && printf '%s' "$any"
    return 0
}

# 把网卡的 XDP 模式落到 EnvironmentFile，由 mimic@.service 注入 `-x <mode>`。
# 空模式 → 删除文件 → mimic 自动选择（native 支持则 native，否则 skb）。
write_mimic_xdp_env() {
    local iface="${1:-}"; [[ -n "$iface" ]] || return 0
    local envf="${MIMIC_CONF_DIR}/${iface}.xdp" mode
    mode="$(iface_xdp_mode "$iface")"
    if [[ "$mode" == "skb" || "$mode" == "native" ]]; then
        printf 'MIMIC_XDP_ARGS=-x %s\n' "$mode" >"$envf"
        chmod 644 "$envf" 2>/dev/null || true
    else
        rm -f "$envf"
    fi
}

apply_mimic_conf_iface() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || die "WAN_IFACE 不能为空"
    local path="${MIMIC_CONF_DIR}/${iface}.conf"
    backup_file "$path"
    render_mimic_conf_iface "$iface" >"$path"
    chmod 644 "$path"
    write_mimic_xdp_env "$iface"
}

render_wg_conf() {
    local ix_addr ing_addr ix_allowed ing_allowed endpoint
    ix_addr="Address = ${WG_IX_IP}/32"
    [[ -n "${WG_IX_IP6:-}" ]] && ix_addr="${ix_addr}"$'\n'"Address = ${WG_IX_IP6}/128"
    ing_addr="Address = ${WG_INGRESS_IP}/32"
    [[ -n "${WG_INGRESS_IP6:-}" ]] && ing_addr="${ing_addr}"$'\n'"Address = ${WG_INGRESS_IP6}/128"
    ix_allowed="${WG_IX_IP}/32"; [[ -n "${WG_IX_IP6:-}" ]] && ix_allowed="${ix_allowed}, ${WG_IX_IP6}/128"
    ing_allowed="${WG_INGRESS_IP}/32"; [[ -n "${WG_INGRESS_IP6:-}" ]] && ing_allowed="${ing_allowed}, ${WG_INGRESS_IP6}/128"
    endpoint="$(format_mimic_ip "${IX_ENDPOINT_HOST}"):${WG_PORT}"
    if [[ "${ROLE:-}" == "nat-transit" ]]; then
        cat <<EOF
# Generated by wg-mimic-fabric — nat-transit ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
${ix_addr}
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${ing_allowed}
PersistentKeepalive = 25
EOF
    elif [[ "${ROLE:-}" == "exit" ]]; then
        # B 出口 = WG 监听端（对端 A relay）；swgp server 在外层解包后转发到本机 WG
        cat <<EOF
# Generated by wg-mimic-fabric — exit ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
${ix_addr}
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${ing_allowed}
PersistentKeepalive = 25
EOF
    elif [[ "${ROLE:-}" == "relay" ]]; then
        # A 网关 = 拨号端 + 客户端 WG 服务端（单接口承载）。
        # 含 swgp 时 WG 拨本机 swgp client(127.0.0.1:SWGP_PORT)，否则直拨 B。
        local relay_ep peerb_allowed addr extra c
        if obfs_has_swgp; then relay_ep="127.0.0.1:${SWGP_PORT}"; else relay_ep="${endpoint}"; fi
        addr="${ing_addr}"
        # 客户端入口已配置 → 加客户端子网网关地址
        [[ -n "${CLIENT_SUBNET:-}" ]] && addr="${addr}"$'\n'"Address = ${CLIENT_SUBNET%.*}.1/24"
        extra=""
        [[ -n "${CLIENT_WG_PORT:-}" ]] && extra="${extra}ListenPort = ${CLIENT_WG_PORT}"$'\n'
        if [[ "${EXIT_MODE:-global}" == "global" ]]; then
            # 全局出口：peer B 收所有目的地（crypto-routing）。
            # 关键：Table=off 让 wg-quick 不把 0/0 塞进主表（否则劫持 A 自身 SSH/现有线路）；
            # 改用「仅客户端子网」策略路由，A 自身流量保持原默认路由不变。
            peerb_allowed="0.0.0.0/0"; [[ -n "${WG_IX_IP6:-}" ]] && peerb_allowed="0.0.0.0/0, ::/0"
            extra="${extra}Table = off"$'\n'
            if [[ -n "${CLIENT_SUBNET:-}" ]]; then
                local _t; _t=$(( 8000 + $(printf '%s' "$PROFILE_ID" | cksum | cut -d' ' -f1) % 1000 ))
                extra="${extra}PostUp = ip route replace default dev %i table ${_t}; ip rule del from ${CLIENT_SUBNET} lookup ${_t} 2>/dev/null || true; ip rule add from ${CLIENT_SUBNET} lookup ${_t}"$'\n'
                extra="${extra}PostDown = ip rule del from ${CLIENT_SUBNET} lookup ${_t} 2>/dev/null || true; ip route flush table ${_t} 2>/dev/null || true; true"$'\n'
            fi
        else
            peerb_allowed="${ix_allowed}"
        fi
        cat <<EOF
# Generated by wg-mimic-fabric — relay ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
${addr}
${extra}MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint = ${relay_ep}
AllowedIPs = ${peerb_allowed}
PersistentKeepalive = 25
EOF
        for c in $(list_client_ids "$PROFILE_ID"); do
            ( # shellcheck disable=SC1090
              source "$(client_env_path "$PROFILE_ID" "$c")" 2>/dev/null
              [[ -n "${CLIENT_PUBKEY:-}" && -n "${CLIENT_IP:-}" ]] || exit 0
              printf '\n[Peer]\n# client %s\nPublicKey = %s\nAllowedIPs = %s/32\n' \
                  "${CLIENT_NAME:-$c}" "$CLIENT_PUBKEY" "$CLIENT_IP" )
        done
    else
        cat <<EOF
# Generated by wg-mimic-fabric — nat-ingress ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
${ing_addr}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint = ${endpoint}
AllowedIPs = ${ix_allowed}
PersistentKeepalive = 25
EOF
    fi
}

apply_profile_configs() {
    [[ -n "${WAN_IFACE:-}" ]] || die "配置缺少 WAN_IFACE（Mimic 绑定网卡）"
    apply_mimic_conf_iface "$WAN_IFACE"
    local wg_iface; wg_iface="$(wg_iface_for "$PROFILE_ID")"
    local wg_path="${WG_CONF_DIR}/${wg_iface}.conf"
    backup_file "$wg_path"
    render_wg_conf >"$wg_path"
    chmod 600 "$wg_path"
    if obfs_has_swgp; then
        if [[ "${ROLE:-}" == "exit" ]]; then
            apply_swgp_conf "$PROFILE_ID" server "${SWGP_PORT}" "127.0.0.1:${WG_PORT}" \
                "${SWGP_MODE:-zero-overhead-2026}" "${SWGP_PSK}" 1500
        elif [[ "${ROLE:-}" == "relay" ]]; then
            # 全局出口时给 swgp 打 fwmark，使其到 B 的流量避开 WG 默认路由(防环)
            local _fw=0; [[ "${EXIT_MODE:-global}" == "global" ]] && _fw=$((WMF_FWMARK))
            apply_swgp_conf "$PROFILE_ID" client "${SWGP_PORT}" \
                "$(format_mimic_ip "${IX_ENDPOINT_HOST}"):${SWGP_PORT}" \
                "${SWGP_MODE:-zero-overhead-2026}" "${SWGP_PSK}" 1500 "$_fw"
        fi
    fi
    write_tunnel_mimic_dropin "$PROFILE_ID" "$WAN_IFACE"
}

# Collect DNAT entries across enabled profiles+rules as TSV:
#   daddr_match \t proto \t dport \t target_ip \t target_port \t tag
# nat-transit: 客户端流量到 IX 虚拟IP:transit_port → DNAT 落地
# nat-ingress: 客户端到 公网:client_port → DNAT IX虚拟IP:transit_port（经 WG）
collect_dnat_entries() {
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${ENABLED:-true}" == "true" ]] || exit 0
            local rid fam mesh_ip landing_ip
            for rid in $(list_rule_ids "$PROFILE_ID"); do
                (
                    load_rule "$PROFILE_ID" "$rid" || exit 0
                    [[ "${RULE_ENABLED:-true}" == "true" ]] || exit 0
                    landing_ip="$(resolve_host_ip "$LANDING_HOST")"
                    [[ -n "$landing_ip" ]] || exit 0
                    if [[ "$landing_ip" == *:* ]]; then fam="ip6"; mesh_ip="${WG_IX_IP6:-}"; else fam="ip"; mesh_ip="${WG_IX_IP:-}"; fi
                    [[ -n "$mesh_ip" ]] || exit 0
                    if [[ "${ROLE:-}" == "nat-transit" ]]; then
                        [[ -n "$TRANSIT_PORT" && -n "$LANDING_HOST" && -n "$LANDING_PORT" ]] || exit 0
                        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                            "$fam" "$mesh_ip" "${FORWARD_PROTO:-both}" "$TRANSIT_PORT" \
                            "$landing_ip" "$LANDING_PORT" "${PROFILE_ID}-${rid}"
                    elif [[ "${ROLE:-}" == "nat-ingress" ]]; then
                        [[ -n "${CLIENT_PORT:-}" && -n "$TRANSIT_PORT" ]] || exit 0
                        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                            "$fam" "-" "${FORWARD_PROTO:-both}" "$CLIENT_PORT" \
                            "$mesh_ip" "$TRANSIT_PORT" "${PROFILE_ID}-${rid}"
                    fi
                )
            done
        )
    done
}

# Collect input-open ports as TSV: tag \t port
collect_input_ports() {
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${ENABLED:-true}" == "true" && "${FW_OPEN_PORT:-true}" == "true" ]] || exit 0
            if [[ "${ROLE:-}" == "nat-transit" ]]; then
                printf '%s\t%s\n' "${PROFILE_ID}-wg" "$WG_PORT"
            elif [[ "${ROLE:-}" == "exit" ]]; then
                # B 出口放行线上端口（含 swgp 时为 SWGP_PORT，否则 WG_PORT）
                printf '%s\t%s\n' "${PROFILE_ID}-wire" "$(obfs_wire_port)"
            elif [[ "${ROLE:-}" == "relay" ]]; then
                # A 网关放行客户端 WG 入口端口（若已配置客户端入口）
                [[ -n "${CLIENT_WG_PORT:-}" ]] && printf '%s\t%s\n' "${PROFILE_ID}-cli" "$CLIENT_WG_PORT"
            elif [[ "${ROLE:-}" == "nat-ingress" ]]; then
                local rid
                for rid in $(list_rule_ids "$PROFILE_ID"); do
                    (
                        load_rule "$PROFILE_ID" "$rid" || exit 0
                        [[ "${RULE_ENABLED:-true}" == "true" && -n "${CLIENT_PORT:-}" ]] || exit 0
                        printf '%s\t%s\n' "${PROFILE_ID}-${rid}" "$CLIENT_PORT"
                    )
                done
            fi
        )
    done
}

nft_emit_dnat() {
    local entries="$1" fam daddr proto dport tip tport tag match tgt
    [[ -n "$entries" ]] || return 0
    while IFS=$'\t' read -r fam daddr proto dport tip tport tag; do
        [[ -n "$dport" && -n "$tip" && -n "$tport" ]] || continue
        if [[ "$fam" == "ip6" ]]; then tgt="[${tip}]:${tport}"; else tgt="${tip}:${tport}"; fi
        if [[ "$daddr" != "-" && -n "$daddr" ]]; then
            match="${fam} daddr ${daddr} "
        elif [[ "$fam" == "ip6" ]]; then
            match="meta nfproto ipv6 "
        else
            match="meta nfproto ipv4 "
        fi
        case "$proto" in
            tcp)
                printf '        %stcp dport %s counter dnat to %s comment "wm-%s"\n' "$match" "$dport" "$tgt" "$tag" ;;
            udp)
                printf '        %sudp dport %s counter dnat to %s comment "wm-%s"\n' "$match" "$dport" "$tgt" "$tag" ;;
            *)
                printf '        %stcp dport %s counter dnat to %s comment "wm-%s-tcp"\n' "$match" "$dport" "$tgt" "$tag"
                printf '        %sudp dport %s counter dnat to %s comment "wm-%s-udp"\n' "$match" "$dport" "$tgt" "$tag" ;;
        esac
    done <<<"$entries"
}

nft_emit_masq() {
    local entries="$1" fam daddr proto dport tip tport tag
    [[ -n "$entries" ]] || return 0
    while IFS=$'\t' read -r fam daddr proto dport tip tport tag; do
        [[ -n "$tip" && -n "$tport" ]] || continue
        case "$proto" in
            tcp)
                printf '        %s daddr %s tcp dport %s counter masquerade comment "wm-%s"\n' "$fam" "$tip" "$tport" "$tag" ;;
            udp)
                printf '        %s daddr %s udp dport %s counter masquerade comment "wm-%s"\n' "$fam" "$tip" "$tport" "$tag" ;;
            *)
                printf '        %s daddr %s tcp dport %s counter masquerade comment "wm-%s-tcp"\n' "$fam" "$tip" "$tport" "$tag"
                printf '        %s daddr %s udp dport %s counter masquerade comment "wm-%s-udp"\n' "$fam" "$tip" "$tport" "$tag" ;;
        esac
    done <<<"$entries"
}

nft_emit_input() {
    local inputs="$1" tag port
    [[ -n "$inputs" ]] || return 0
    while IFS=$'\t' read -r tag port; do
        [[ -n "$port" ]] || continue
        printf '        tcp dport %s counter accept comment "wm-%s-tcp"\n' "$port" "$tag"
        printf '        udp dport %s counter accept comment "wm-%s-udp"\n' "$port" "$tag"
    done <<<"$inputs"
}

# 混淆网关/出口的 masquerade（全局出口）：
#   relay(A)：客户端子网 → 出上行 WG 接口（src 变成 A 的 mesh IP，B 才认）
#   exit(B)： mesh 子网（含已被 A masq 的客户端流量）→ 出网卡
nft_emit_gw_masq() {
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${ENABLED:-true}" == "true" ]] || exit 0
            if [[ "${ROLE:-}" == "relay" && -n "${CLIENT_SUBNET:-}" ]]; then
                printf '        ip saddr %s oifname "%s" counter masquerade comment "wm-%s-cli"\n' \
                    "$CLIENT_SUBNET" "$(wg_iface_for "$PROFILE_ID")" "$PROFILE_ID"
            elif [[ "${ROLE:-}" == "exit" && -n "${WAN_IFACE:-}" ]]; then
                printf '        ip saddr %s oifname "%s" counter masquerade comment "wm-%s-exit"\n' \
                    "${WG_MESH_SUBNET:-10.88.0.0/24}" "$WAN_IFACE" "$PROFILE_ID"
            fi
        )
    done
}

render_nft_all() {
    local entries inputs
    entries="$(collect_dnat_entries)"
    inputs="$(collect_input_ports)"
    {
        printf 'table inet %s {\n' "$NFT_TABLE"
        printf '    chain prerouting {\n'
        printf '        type nat hook prerouting priority dstnat; policy accept;\n'
        nft_emit_dnat "$entries"
        printf '    }\n'
        printf '    chain postrouting {\n'
        printf '        type nat hook postrouting priority srcnat; policy accept;\n'
        printf '        oifname "lo" return\n'
        nft_emit_masq "$entries"
        nft_emit_gw_masq
        printf '    }\n'
        printf '    chain forward {\n'
        printf '        type filter hook forward priority filter; policy accept;\n'
        # MSS 钳制：把进/出隧道的 TCP SYN 的 MSS 钳到该路由的 MTU（隧道侧=WG_MTU-头部），
        # 这样两端 TCP 协商出能过隧道的段大小，不再依赖易被掐断的 PMTUD（修大包黑洞/卡顿）。
        printf '        tcp flags syn tcp option maxseg size set rt mtu counter comment "wm-mss-clamp"\n'
        printf '    }\n'
        printf '    chain input {\n'
        printf '        type filter hook input priority filter; policy accept;\n'
        nft_emit_input "$inputs"
        printf '    }\n'
        printf '}\n'
    }
}

apply_nft_all() {
    local tmp; tmp="$(mktemp)"
    render_nft_all >"$tmp"
    install -m 644 "$tmp" "$NFT_FILE"
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    fi
    nft -f "$NFT_FILE" 2>/dev/null || warn "nftables 加载失败（可能未安装/未启用）"
    rm -f "$tmp"
}

# ── systemd ────────────────────────────────────────────────────────────────

# Resolve a binary to an absolute path (PATH first, then common dirs).
resolve_bin() {
    local name="$1" def="$2" p c
    p="$(command -v "$name" 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        for c in "/usr/sbin/$name" "/usr/bin/$name" "/usr/local/sbin/$name" "/usr/local/bin/$name" "/sbin/$name" "/bin/$name"; do
            [[ -x "$c" ]] && { p="$c"; break; }
        done
    fi
    printf '%s' "${p:-$def}"
}

install_systemd_units() {
    local tmp mimic_bin wgquick_bin modprobe_bin
    # mimic/wg-quick paths vary by distro (Debian ships mimic under /usr/sbin),
    # so never hardcode /usr/bin — a wrong path makes the unit fail 203/EXEC.
    mimic_bin="$(resolve_bin mimic /usr/bin/mimic)"
    wgquick_bin="$(resolve_bin wg-quick /usr/bin/wg-quick)"
    modprobe_bin="$(resolve_bin modprobe /sbin/modprobe)"
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric Mimic on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-${modprobe_bin} mimic
EnvironmentFile=-/etc/mimic/%i.xdp
ExecStart=${mimic_bin} run %i \$MIMIC_XDP_ARGS -F /etc/mimic/%i.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_MIMIC_TEMPLATE"

    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric WireGuard tunnel %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${wgquick_bin} up /etc/wireguard/wm-%i.conf
ExecStop=${wgquick_bin} down /etc/wireguard/wm-%i.conf

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_TUNNEL_TEMPLATE"
    rm -f "$tmp"
    systemctl daemon-reload
}

# mimic@ is keyed by WAN_IFACE (one per nic, shared by lines); tunnel@ is keyed by
# profile id. A per-profile drop-in binds each tunnel@<id> to its real mimic@<iface>
# so boot ordering / Requires resolve to the correct unit instance.
write_tunnel_mimic_dropin() {
    local profile_id="$1" iface="$2"
    [[ -n "$profile_id" && -n "$iface" ]] || return 0
    local dir="/etc/systemd/system/wg-mimic-tunnel@${profile_id}.service.d"
    local wgi wgq
    wgi="$(wg_iface_for "$profile_id")"
    wgq="$(resolve_bin wg-quick /usr/bin/wg-quick)"
    local tmp; tmp="$(mktemp)"
    # Also override ExecStart to the (possibly shortened) interface's conf path, so
    # a long profile id never yields an interface name > 15 chars.
    cat >"$tmp" <<EOF
[Unit]
After=wg-mimic-mimic@${iface}.service
Requires=wg-mimic-mimic@${iface}.service

[Service]
ExecStart=
ExecStart=${wgq} up ${WG_CONF_DIR}/${wgi}.conf
ExecStop=
ExecStop=${wgq} down ${WG_CONF_DIR}/${wgi}.conf
EOF
    install -d -m 755 "$dir"
    install -m 644 "$tmp" "${dir}/10-mimic-dep.conf"
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
}

remove_tunnel_mimic_dropin() {
    local profile_id="$1"
    [[ -n "$profile_id" ]] || return 0
    rm -rf "/etc/systemd/system/wg-mimic-tunnel@${profile_id}.service.d" 2>/dev/null || true
}

# Force-detach any XDP program left on the NIC. A failed native attach (e.g. on
# virtio_net) can leave a stale program that blocks the NEXT attach — even skb —
# trapping mimic in a "仍未启动" loop until cleared manually. Clearing before each
# (re)attach makes the native→skb fallback recover cleanly instead of bricking the
# line. Detach all modes (generic / native-drv / offload) to be thorough.
detach_xdp() {
    local iface="$1"
    [[ -n "$iface" ]] || return 0
    command_exists ip || return 0
    ip link set dev "$iface" xdpgeneric off 2>/dev/null || true
    ip link set dev "$iface" xdpdrv off 2>/dev/null || true
    ip link set dev "$iface" xdp off 2>/dev/null || true
}

# Kernel driver behind a NIC (e.g. virtio_net, e1000, ixgbe). Empty if unknown.
nic_driver() {
    local iface="$1" l
    [[ -n "$iface" ]] || return 0
    l="$(readlink "/sys/class/net/${iface}/device/driver" 2>/dev/null)" || return 0
    printf '%s' "${l##*/}"
}

# True when this NIC should default to XDP skb mode: native XDP is unreliable on
# virtio_net (needs GRO off and frequently still fails), so prefer skb there to
# avoid the native-fail churn / stale-program lockups.
nic_prefers_skb() {
    case "$(nic_driver "$1")" in
        virtio_net|virtio) return 0 ;;
        *) return 1 ;;
    esac
}

# Poll until mimic@<iface> is active, up to <secs> seconds. The unit has
# Restart=on-failure (RestartSec=3), so a transient first-attach failure recovers
# within a few seconds — a single 1s check would falsely report "未起来".
wait_mimic_active() {
    local iface="$1" secs="${2:-8}" i
    for ((i = 0; i < secs; i++)); do
        systemctl is-active --quiet "wg-mimic-mimic@${iface}.service" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Force skb mode for every profile bound to this nic (used as the universal
# fallback, and proactively on NICs where native is known to be unreliable).
force_iface_skb() {
    local iface="$1" p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        grep -q "^WAN_IFACE=${iface}\$" "$p" 2>/dev/null || continue
        grep -q '^MIMIC_XDP_MODE=skb$' "$p" 2>/dev/null || set_or_append_kv "$p" MIMIC_XDP_MODE skb
    done
    apply_mimic_conf_iface "$iface"
}

# Start mimic@<iface> and verify it actually came up. On failure (e.g. XDP native
# rejected on virtio_net + GRO), force skb mode for that nic's profiles and retry.
ensure_mimic_service_up() {
    local iface="$1"
    # 总是按最新 unit/conf/env(含命令行 -x XDP 模式)干净重启 mimic。
    # 旧逻辑“见 active 就 return 0”会在 set-mtu/restart/upgrade 后遗留旧 mimic 进程
    # (旧 XDP 模式 / 解析失败丢 filter)→ virtio 网卡上重启后隧道直接不通,必须手动救。
    # 代价:同一网卡多线路时这会顺带重启共享 mimic(秒级抖动),换取重启后状态必定一致。
    # 先清残留 XDP,virtio 直接 skb,再 restart(不在则等同 start)。
    detach_xdp "$iface"
    nic_prefers_skb "$iface" && force_iface_skb "$iface"
    systemctl enable "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
    systemctl restart "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
    wait_mimic_active "$iface" 8 && return 0
    warn "mimic@${iface} 未起来，改用 XDP skb 模式重试..."
    # Fully stop the failed unit and clear the leftover program before retrying —
    # otherwise the stale native attach blocks the skb attach too.
    systemctl stop "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
    detach_xdp "$iface"
    force_iface_skb "$iface"
    systemctl restart "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
    if wait_mimic_active "$iface" 8; then
        ok "mimic@${iface} 已用 skb 模式启动"
        return 0
    fi
    warn "mimic@${iface} 仍未启动 — 排查：journalctl -xeu wg-mimic-mimic@${iface}.service"
    return 1
}

start_profile() {
    require_root
    load_profile "$1"
    local path; path="$(profile_env_path "$PROFILE_ID")"
    grep -q '^ENABLED=' "$path" 2>/dev/null && sed -i 's/^ENABLED=.*/ENABLED=true/' "$path"
    load_profile "$1"
    if obfs_has_mimic; then
        mimic_needs_reboot && offer_reboot "start ${PROFILE_ID}"
        ensure_mimic
    fi
    install_systemd_units
    if obfs_has_swgp; then install_swgp; install_swgp_units; fi
    apply_profile_configs
    apply_nft_all
    ensure_ip_forward
    # swgp 必须先于 WG 隧道起来（relay 的 WG 拨本机 swgp client）
    if obfs_has_swgp; then systemctl enable --now "wg-mimic-swgp@${PROFILE_ID}.service" 2>/dev/null || true; fi
    if obfs_has_mimic; then ensure_mimic_service_up "$WAN_IFACE"; fi
    # 用 restart 显式拉起隧道:隧道单元 Requires=mimic,上面重启 mimic 可能级联停掉
    # 隧道,这里 restart 保证最终一定起来(且套用最新 WG conf),enable 仅保证开机自启。
    systemctl enable "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null || true
    systemctl restart "wg-mimic-tunnel@${PROFILE_ID}.service"
    ok "已启动线路：${PROFILE_ID} (${ROLE:-})"
    if [[ "${ROLE:-}" == "nat-ingress" ]]; then
        ok "客户端连接：${INGRESS_PUBLIC_HOST:-本机公网IP}:<client_port>（wm show-port-map ${PROFILE_ID}）"
    fi
}

stop_profile() {
    require_root
    load_profile "$1"
    local path; path="$(profile_env_path "$PROFILE_ID")"
    if grep -q '^ENABLED=' "$path" 2>/dev/null; then
        sed -i 's/^ENABLED=.*/ENABLED=false/' "$path"
    else
        printf 'ENABLED=false\n' >>"$path"
    fi
    systemctl disable --now "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null || true
    systemctl disable --now "wg-mimic-swgp@${PROFILE_ID}.service" 2>/dev/null || true
    apply_nft_all
    if [[ -n "${WAN_IFACE:-}" ]]; then
        apply_mimic_conf_iface "$WAN_IFACE"
        systemctl try-restart "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null \
            || systemctl stop "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null || true
        # If mimic no longer runs on this nic (no other profile uses it), clear its
        # XDP program so the NIC is left clean and the next start attaches cleanly.
        systemctl is-active --quiet "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null \
            || detach_xdp "$WAN_IFACE"
    fi
    ok "已停止线路：${PROFILE_ID}"
}

# 删除整条线路（保留同机其它线路）：停服务 → 删 conf/env/code/clients/drop-in → 重渲染
# nft + 该网卡 mimic。WMF_DELETE_YES=1 跳过确认。
delete_profile() {
    local id; id="$(sanitize_id "${1:-}")"
    [[ -n "$id" ]] || die "用法: wm delete-line <线路ID>（先 wm list-profiles 查看）"
    require_root
    [[ -f "$(profile_env_path "$id")" ]] || die "线路不存在：${id}"
    local _c="N"
    [[ "${WMF_DELETE_YES:-}" == "1" ]] || prompt _c "确认删除线路 ${id}（配置/密钥/接入码/客户端全部删除,不可恢复）？[y/N]" "N"
    case "$_c" in [Yy]*) ;; *) die "已取消" ;; esac
    load_profile "$id" 2>/dev/null || true
    local iface="${WAN_IFACE:-}" wgi; wgi="$(wg_iface_for "$id")"
    systemctl disable --now "wg-mimic-tunnel@${id}.service" 2>/dev/null || true
    systemctl disable --now "wg-mimic-swgp@${id}.service" 2>/dev/null || true
    rm -f "$(profile_env_path "$id")" "${WG_CONF_DIR}/${wgi}.conf" \
        "${CODES_DIR}/${id}.code" "${SWGP_CONF_DIR}/${id}.json"
    rm -rf "${PROFILES_DIR}/${id}" "/etc/systemd/system/wg-mimic-tunnel@${id}.service.d"
    systemctl daemon-reload 2>/dev/null || true
    apply_nft_all
    if [[ -n "$iface" ]]; then
        apply_mimic_conf_iface "$iface"
        systemctl try-restart "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
        systemctl is-active --quiet "wg-mimic-mimic@${iface}.service" 2>/dev/null || detach_xdp "$iface"
    fi
    ok "已删除线路：${id}"
}

# ── create server / import code ────────────────────────────────────────────

prompt() {
    local var="$1" prompt_text="$2" default="${3:-}"
    local __prompt_val=""
    if [[ -n "$default" ]]; then
        read -r -p "${prompt_text} [${default}]: " __prompt_val </dev/tty || true
        __prompt_val="${__prompt_val:-$default}"
    else
        read -r -p "${prompt_text}: " __prompt_val </dev/tty || true
    fi
    printf -v "$var" '%s' "$(trim "$__prompt_val")"
}

# ── 混淆组网：B(exit) 生成 / A(relay) 导入 ─────────────────────────────────────

create_exit_interactive() {
    require_root
    ensure_dirs
    command_exists nft || die "需要 nftables，请 apt install nftables"
    command_exists wg || die "需要 wireguard-tools，请 apt install wireguard-tools"

    local profile_id endpoint_host wg_port wg_mtu wan_iface
    local subnet ix_ip ingress_ip obfs_mode swgp_mode swgp_port swgp_psk
    prompt profile_id "出口线路 ID（B 国外）" "exit"
    profile_id="$(sanitize_id "$profile_id")"
    [[ ! -f "$(profile_env_path "$profile_id")" ]] || die "线路已存在：$profile_id"
    info "填「A(国内网关)能连到本机 B 的公网/中转地址」（中转机填入口IP）"
    prompt endpoint_host "A 可达的 B 公网/中转地址（域名或IP）" ""
    [[ -n "$endpoint_host" ]] || die "B 可达地址不能为空"
    prompt_port wg_port "WireGuard 监听端口" "51820"
    prompt obfs_mode "混淆方式 direct/mimic/swgp/swgp+mimic" "swgp+mimic"
    case "$obfs_mode" in direct|mimic|swgp|swgp+mimic) ;; *) die "混淆方式只能 direct/mimic/swgp/swgp+mimic" ;; esac
    swgp_port=0; swgp_mode=""; swgp_psk=""
    if [[ "$obfs_mode" == *swgp* ]]; then
        prompt_port swgp_port "swgp-go 线上端口（A 连这个）" "$((wg_port + 1))"
        [[ "$swgp_port" != "$wg_port" ]] || die "swgp 端口不能与 WG 端口相同"
        prompt swgp_mode "swgp 模式 zero-overhead-2026/paranoid-2026" "zero-overhead-2026"
        install_swgp
        swgp_psk="$(swgp_genpsk)"
    fi
    local mtu_def=1400; [[ "$obfs_mode" == *paranoid* ]] && mtu_def=1360; [[ "$obfs_mode" == direct ]] && mtu_def=1420
    prompt wg_mtu "WG 隧道 MTU" "$mtu_def"
    validate_mtu "$wg_mtu"
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic/出网绑定网卡" "${wan_iface:-eth0}"
    prompt subnet "组网网段" "$(next_free_mesh_subnet)"
    prompt ix_ip "B 虚拟 IP" "$(mesh_host_ip "$subnet" 2)"
    prompt ingress_ip "A 虚拟 IP" "$(mesh_host_ip "$subnet" 1)"
    validate_ipv4 "$ix_ip" || die "B 虚拟 IP 非法"
    validate_ipv4 "$ingress_ip" || die "A 虚拟 IP 非法"

    local b_priv b_pub a_priv a_pub a_priv_b64
    b_priv="$(wg_genkey)"; b_pub="$(wg_pubkey_of "$b_priv")"
    a_priv="$(wg_genkey)"; a_pub="$(wg_pubkey_of "$a_priv")"
    a_priv_b64="$(printf '%s' "$a_priv" | base64url_encode)"

    write_profile_kv "$(profile_env_path "$profile_id")" \
        "PROFILE_ID=${profile_id}" "PROFILE_NAME=${profile_id}" "ROLE=exit" "ENABLED=true" \
        "WAN_IFACE=${wan_iface}" "WG_MESH_SUBNET=${subnet}" "WG_IX_IP=${ix_ip}" \
        "WG_INGRESS_IP=${ingress_ip}" "IP_VERSION=4" "WG_PORT=${wg_port}" "WG_MTU=${wg_mtu}" \
        "IX_ENDPOINT_HOST=${endpoint_host}" "WG_PRIVATE_KEY=${b_priv}" "WG_PUBLIC_KEY=${b_pub}" \
        "WG_PEER_PUBLIC_KEY=${a_pub}" "INGRESS_PRIVKEY_B64=${a_priv_b64}" "MIMIC_KEEPALIVE=300:::" \
        "MIMIC_XDP_MODE=" "OBFS_MODE=${obfs_mode}" "SWGP_MODE=${swgp_mode}" \
        "SWGP_PSK=${swgp_psk}" "SWGP_PORT=${swgp_port}" "EXIT_MODE=global" "FW_OPEN_PORT=true"

    load_profile "$profile_id"
    apply_nft_all
    ensure_ip_forward
    local code; code="$(generate_exit_code)"
    printf '%s\n' "$code" >"${CODES_DIR}/${profile_id}.code"; chmod 600 "${CODES_DIR}/${profile_id}.code"
    printf '\n═══ 出口接入码（复制到 A 国内网关：wm import-exit-code）═══\n%s\n════════════════════════════════════════════\n' "$code"
    local _autostart=""; prompt _autostart "现在就启动该线路吗？[Y/n]" "Y"
    case "$_autostart" in [Nn]*) info "稍后：wm start ${profile_id}" ;; *) start_profile "$profile_id" ;; esac
}

import_exit_code() {
    require_root
    ensure_dirs
    command_exists nft || die "需要 nftables"
    command_exists wg || die "需要 wireguard-tools"
    local code relay_id wan_iface a_priv a_pub xdp
    printf '请粘贴 WMGF1: 出口接入码：' >&2
    read -r code </dev/tty; code="$(trim "$code")"
    parse_code "$code"
    [[ "${CODE_KIND:-}" == "exit" ]] || die "这不是出口接入码（需 nat-exit-code）；普通中转码请用 wm import-code"
    relay_id="${CODE_PROFILE_ID}-relay"
    local prev_ahost="" prev_cport=""
    if [[ -f "$(profile_env_path "$relay_id")" ]]; then
        local _u="Y"; prompt _u "网关线路 ${relay_id} 已存在，用此码更新它吗？[Y/n]" "Y"
        case "$_u" in [Nn]*) die "已取消" ;; esac
        local _pv; _pv="$(load_profile "$relay_id" 2>/dev/null; printf '%s\t%s' "${A_PUBLIC_HOST:-}" "${CLIENT_WG_PORT:-}")" || _pv=""
        prev_ahost="${_pv%%$'\t'*}"; prev_cport="${_pv#*$'\t'}"
        stop_profile "$relay_id" >/dev/null 2>&1 || true
    fi
    a_priv="$(printf '%s' "$CODE_INGRESS_PRIVKEY_B64" | base64url_decode)"
    a_pub="$(wg_pubkey_of "$a_priv")"
    [[ "$CODE_OBFS_MODE" == *swgp* ]] && install_swgp
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic/绑定网卡" "${wan_iface:-eth0}"
    xdp="native"; nic_prefers_skb "$wan_iface" && xdp="skb"

    printf '\n── 出口接入码摘要 ──\n  B 端点: %s:%s\n  混淆: %s  swgp端口: %s\n  组网: A %s ⇄ B %s\n\n' \
        "$CODE_IX_ENDPOINT_HOST" "$CODE_WG_PORT" "$CODE_OBFS_MODE" "${CODE_SWGP_PORT}" \
        "$CODE_INGRESS_WG_IP" "$CODE_IX_WG_IP"

    # 客户端入口（A 当客户端 WG 服务端；这些不进接入码，按本机配置）
    local a_public client_port egress_ip local_ip
    egress_ip="$(detect_public_ipv4)"; local_ip="$(detect_local_ipv4)"
    [[ -n "$egress_ip" ]] && info "出网 IPv4：${egress_ip}"
    [[ -n "$local_ip" ]] && info "本机网卡 IPv4：${local_ip}（NAT 机此为内网IP）"
    prompt a_public "A 公网IP（客户端连接本网关的地址）" "${prev_ahost:-${egress_ip:-$local_ip}}"
    prompt_port client_port "客户端 WG 入口端口" "${prev_cport:-51820}"

    write_profile_kv "$(profile_env_path "$relay_id")" \
        "PROFILE_ID=${relay_id}" "PROFILE_NAME=${relay_id}" "ROLE=relay" "ENABLED=true" \
        "WAN_IFACE=${wan_iface}" "WG_MESH_SUBNET=${CODE_WG_MESH_SUBNET}" "WG_IX_IP=${CODE_IX_WG_IP}" \
        "WG_INGRESS_IP=${CODE_INGRESS_WG_IP}" "IP_VERSION=${CODE_IP_VERSION:-4}" \
        "WG_PORT=${CODE_WG_PORT}" "WG_MTU=${CODE_WG_MTU}" "IX_ENDPOINT_HOST=${CODE_IX_ENDPOINT_HOST}" \
        "WG_PRIVATE_KEY=${a_priv}" "WG_PUBLIC_KEY=${a_pub}" "WG_PEER_PUBLIC_KEY=${CODE_IX_WG_PUBKEY}" \
        "MIMIC_KEEPALIVE=${CODE_MIMIC_KEEPALIVE:-300:::}" "MIMIC_XDP_MODE=${xdp}" \
        "OBFS_MODE=${CODE_OBFS_MODE}" "SWGP_MODE=${CODE_SWGP_MODE}" "SWGP_PSK=${CODE_SWGP_PSK}" \
        "SWGP_PORT=${CODE_SWGP_PORT}" "EXIT_MODE=${CODE_EXIT_MODE:-global}" \
        "A_PUBLIC_HOST=${a_public}" "CLIENT_WG_PORT=${client_port}" \
        "CLIENT_SUBNET=${CLIENT_SUBNET_DEFAULT}" "CLIENT_DNS=1.1.1.1" "CLIENT_MTU=1280" \
        "FW_OPEN_PORT=true"

    load_profile "$relay_id"
    apply_nft_all
    ensure_ip_forward
    local _autostart=""; prompt _autostart "现在就启动该线路吗？[Y/n]" "Y"
    case "$_autostart" in [Nn]*) info "稍后：wm start ${relay_id}" ;; *) start_profile "$relay_id" ;; esac
    ok "验证 A↔B 隧道：wm test ${relay_id}"
}

# ── relay 客户端管理（客户端 WG 接入 A → A 路由到 B 出口）──────────────────────

clients_dir_for() { printf '%s/%s/clients' "$PROFILES_DIR" "$(sanitize_id "$1")"; }
client_env_path() { printf '%s/%s.env' "$(clients_dir_for "$1")" "$(sanitize_id "$2")"; }

list_client_ids() {
    local d f; d="$(clients_dir_for "$1")"
    [[ -d "$d" ]] || return 0
    for f in "$d"/*.env; do [[ -f "$f" ]] && basename "$f" .env; done
}

# 客户端子网内下一个空闲 IP（A=.1，客户端 .2 起）。
alloc_client_ip() {
    local pid="$1" subnet="${2:-$CLIENT_SUBNET_DEFAULT}" base used n ip c
    base="${subnet%.*}"
    used="$(for c in $(list_client_ids "$pid"); do
        ( # shellcheck disable=SC1090
          source "$(client_env_path "$pid" "$c")" 2>/dev/null; printf '%s\n' "${CLIENT_IP:-}" )
    done)"
    for ((n = 2; n <= 254; n++)); do
        ip="${base}.${n}"
        grep -qxF "$ip" <<<"$used" || { printf '%s' "$ip"; return 0; }
    done
    return 1
}

# 标准 WG 客户端配置（官方App/小火箭/mihomo/sing-box 通吃）。
render_client_conf() {
    local priv="$1" ip="$2" peer_pub="$3" endpoint="$4" dns="${5:-1.1.1.1}" mtu="${6:-1280}" allowed="${7:-0.0.0.0/0}"
    cat <<EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}/32
DNS = ${dns}
MTU = ${mtu}

[Peer]
PublicKey = ${peer_pub}
Endpoint = ${endpoint}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
}

add_client() {
    local id name; id="$(resolve_profile_id "${1:-}")"; name="$(sanitize_id "${2:-}")"
    require_root
    [[ -n "${2:-}" ]] || die "用法: wm add-client <网关线路> <客户端名>"
    load_profile "$id"
    [[ "${ROLE:-}" == "relay" ]] || die "add-client 仅用于 relay(国内网关)线路"
    [[ -n "${A_PUBLIC_HOST:-}" && -n "${CLIENT_WG_PORT:-}" ]] \
        || die "该网关未配置客户端入口（重新 wm import-exit-code 设置 A 公网IP/客户端端口）"
    [[ ! -f "$(client_env_path "$id" "$name")" ]] || die "客户端已存在：$name"
    local ip priv pub tmp
    ip="$(alloc_client_ip "$id" "${CLIENT_SUBNET:-$CLIENT_SUBNET_DEFAULT}")" || die "客户端子网已满"
    priv="$(wg_genkey)"; pub="$(wg_pubkey_of "$priv")"
    install -d -m 700 "$(clients_dir_for "$id")"
    tmp="$(mktemp)"
    printf '%s\n' "CLIENT_ID=${name}" "CLIENT_NAME=${name}" "CLIENT_PRIVKEY=${priv}" \
        "CLIENT_PUBKEY=${pub}" "CLIENT_IP=${ip}" >"$tmp"
    install -m 600 "$tmp" "$(client_env_path "$id" "$name")"; rm -f "$tmp"
    apply_profile_configs
    systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null \
        && restart_profile "$PROFILE_ID" >/dev/null 2>&1 || true
    local conf; conf="$(render_client_conf "$priv" "$ip" "$WG_PUBLIC_KEY" \
        "$(format_mimic_ip "$A_PUBLIC_HOST"):${CLIENT_WG_PORT}" "${CLIENT_DNS:-1.1.1.1}" "${CLIENT_MTU:-1280}")"
    printf '\n═══ 客户端 %s 配置（导入 官方WG/小火箭/mihomo/sing-box）═══\n%s\n' "$name" "$conf"
    if command_exists qrencode; then
        printf '\n── 二维码（WG App 扫码导入）──\n'; printf '%s' "$conf" | qrencode -t ANSIUTF8
    else
        info "装 qrencode 可出二维码：apt install qrencode"
    fi
    ok "已新增客户端 ${name}（${ip}）"
}

list_clients() {
    local id c; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    printf '网关 %s 客户端：\n' "$PROFILE_ID"
    for c in $(list_client_ids "$PROFILE_ID"); do
        ( # shellcheck disable=SC1090
          source "$(client_env_path "$PROFILE_ID" "$c")" 2>/dev/null
          printf '  - %s\t%s\n' "${CLIENT_NAME:-$c}" "${CLIENT_IP:-?}" )
    done
    [[ -n "$(list_client_ids "$PROFILE_ID")" ]] || printf '  (无客户端；wm add-client %s <名>)\n' "$PROFILE_ID"
}

del_client() {
    local id name p; id="$(resolve_profile_id "${1:-}")"; name="$(sanitize_id "${2:-}")"
    require_root
    [[ -n "${2:-}" ]] || die "用法: wm del-client <网关线路> <客户端名>"
    load_profile "$id"
    p="$(client_env_path "$PROFILE_ID" "$name")"
    [[ -f "$p" ]] || die "客户端不存在：$name"
    rm -f "$p"
    apply_profile_configs
    systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null \
        && restart_profile "$PROFILE_ID" >/dev/null 2>&1 || true
    ok "已删除客户端 ${name}"
}

create_transit_interactive() {
    require_root
    ensure_dirs
    command_exists nft || die "需要 nftables，请 apt install nftables"
    command_exists wg || die "需要 wireguard-tools，请 apt install wireguard-tools"

    local profile_id endpoint_host wg_port wg_mtu wan_iface
    local subnet ix_ip ingress_ip transit_port landing_host landing_port proto ip_version
    local transit_pool="" tp_default="40000"
    prompt profile_id "IX 中转线路 ID" "ix-nat"
    profile_id="$(sanitize_id "$profile_id")"
    [[ ! -f "$(profile_env_path "$profile_id")" ]] || die "线路已存在：$profile_id"

    info "填「公网入口能连到本机的公网地址」= 商家给的公网IP/域名（NAT 机通常不是本机网卡IP，需手填；不自动填默认值以免误填出网IP）"
    prompt endpoint_host "公网入口可达的 IX 公网地址（域名或IP）" ""
    [[ -n "$endpoint_host" ]] || die "IX 可达地址不能为空"
    prompt_port wg_port "WireGuard 监听端口（Mimic 伪 TCP 绑定）" "51820"
    prompt wg_mtu "WG 隧道 MTU" "1420"
    validate_mtu "$wg_mtu"
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${wan_iface:-eth0}"

    prompt subnet "组网网段" "$(next_free_mesh_subnet)"
    prompt ix_ip "IX 虚拟 IP" "$(mesh_host_ip "$subnet" 2)"
    prompt ingress_ip "公网入口虚拟 IP" "$(mesh_host_ip "$subnet" 1)"
    validate_ipv4 "$ix_ip" || die "IX 虚拟 IP 非法"
    validate_ipv4 "$ingress_ip" || die "入口虚拟 IP 非法"

    prompt ip_version "IP 版本 4 / 6 / dual" "4"
    case "$ip_version" in 4|6|dual) ;; *) die "IP_VERSION 只能是 4/6/dual" ;; esac
    local subnet6="" ix_ip6="" ingress_ip6=""
    if [[ "$ip_version" == "6" || "$ip_version" == "dual" ]]; then
        prompt subnet6 "IPv6 组网网段" "fd88:6d6d::/64"
        prompt ix_ip6 "IX 虚拟 IPv6" "fd88:6d6d::2"
        prompt ingress_ip6 "公网入口虚拟 IPv6" "fd88:6d6d::1"
    fi

    prompt transit_pool "中转端口池（如 18300-18399；商家给的可用端口段；留空=手动指定）" ""
    if [[ -n "$transit_pool" ]]; then
        validate_port_pool "$transit_pool" || die "端口池格式非法：$transit_pool"
        # 防呆：WG 监听端口=公网入口要连的传输端口，必须落在商家放行的池范围内
        if ! pool_contains "$transit_pool" "$wg_port"; then
            warn "WG 监听端口 ${wg_port} 不在端口池 ${transit_pool} 内；商家若只放行池内端口，公网入口将连不上 IX"
            prompt_port wg_port "改用池内的 WG 监听端口" "$(pool_alloc_port "$profile_id" "$transit_pool")"
            pool_contains "$transit_pool" "$wg_port" || die "WG 端口仍不在端口池内：${wg_port}"
        fi
        tp_default="$(pool_alloc_port "$profile_id" "$transit_pool" "$wg_port")" || die "端口池已无空闲端口"
    fi

    info "首条转发规则（落地可填 IPv6）："
    prompt_port transit_port "中转端口（IX 虚拟IP 上的端口）" "$tp_default"
    if [[ -n "$transit_pool" ]]; then
        pool_contains "$transit_pool" "$transit_port" || die "端口 ${transit_port} 不在端口池 ${transit_pool} 内"
        [[ "$transit_port" != "$wg_port" ]] || die "中转端口不能与 WG 监听端口 ${wg_port} 相同"
    fi
    prompt landing_host "落地 IP/域名"
    [[ -n "$landing_host" ]] || die "落地地址不能为空"
    prompt_port landing_port "落地端口"
    prompt proto "协议 tcp / udp / both" "both"
    validate_proto "$proto" || die "协议必须是 tcp、udp 或 both"

    local ix_priv ix_pub ing_priv ing_pub ing_priv_b64
    ix_priv="$(wg_genkey)"; ix_pub="$(wg_pubkey_of "$ix_priv")"
    ing_priv="$(wg_genkey)"; ing_pub="$(wg_pubkey_of "$ing_priv")"
    ing_priv_b64="$(printf '%s' "$ing_priv" | base64url_encode)"

    write_profile_kv "$(profile_env_path "$profile_id")" \
        "PROFILE_ID=${profile_id}" \
        "PROFILE_NAME=${profile_id}" \
        "ROLE=nat-transit" \
        "ENABLED=true" \
        "WAN_IFACE=${wan_iface}" \
        "WG_MESH_SUBNET=${subnet}" \
        "WG_IX_IP=${ix_ip}" \
        "WG_INGRESS_IP=${ingress_ip}" \
        "IP_VERSION=${ip_version}" \
        "WG_MESH_SUBNET6=${subnet6}" \
        "WG_IX_IP6=${ix_ip6}" \
        "WG_INGRESS_IP6=${ingress_ip6}" \
        "WG_PORT=${wg_port}" \
        "WG_MTU=${wg_mtu}" \
        "IX_ENDPOINT_HOST=${endpoint_host}" \
        "WG_PRIVATE_KEY=${ix_priv}" \
        "WG_PUBLIC_KEY=${ix_pub}" \
        "WG_PEER_PUBLIC_KEY=${ing_pub}" \
        "INGRESS_PRIVKEY_B64=${ing_priv_b64}" \
        "FORWARD_PROTO=${proto}" \
        "TRANSIT_PORT_POOL=${transit_pool}" \
        "MIMIC_KEEPALIVE=300:::" \
        "MIMIC_XDP_MODE=" \
        "FW_OPEN_PORT=true"

    write_rule "$profile_id" "rule-main" \
        "RULE_ID=rule-main" \
        "RULE_NOTE=默认转发" \
        "RULE_ENABLED=true" \
        "TRANSIT_PORT=${transit_port}" \
        "LANDING_HOST=${landing_host}" \
        "LANDING_PORT=${landing_port}" \
        "FORWARD_PROTO=${proto}"

    load_profile "$profile_id"
    apply_nft_all
    ensure_ip_forward

    local code
    code="$(generate_code)"
    printf '%s\n' "$code" >"${CODES_DIR}/${profile_id}.code"
    chmod 600 "${CODES_DIR}/${profile_id}.code"

    printf '\n═══ IX 接入码（复制到公网入口机）═══\n'
    printf '%s\n' "$code"
    printf '════════════════════════════════════════════\n'
    printf '公网入口：wm import-code 粘贴上方接入码\n'
    printf 'IX 机启动：wm start %s\n' "$profile_id"
    local _autostart=""
    prompt _autostart "现在就启动该线路吗？[Y/n]" "Y"
    case "$_autostart" in
        [Nn]*) info "稍后手动启动：wm start ${profile_id}" ;;
        *) start_profile "$profile_id" ;;
    esac
}

import_code_interactive() {
    require_root
    ensure_dirs
    command_exists nft || die "需要 nftables"
    command_exists wg || die "需要 wireguard-tools"
    install_mimic_packages || die "公网入口需要 mimic（UDP 伪装 TCP）"
    ensure_mimic_kmod_loaded || warn "mimic 内核模块未加载，请 reboot 或安装 linux-headers-\$(uname -r)"

    local code ingress_id wan_iface public_ip ing_priv ing_pub
    local updating=0 prev_host="" prev_iface=""
    printf '请粘贴 WMGF1: IX 接入码：' >&2
    read -r code </dev/tty
    code="$(trim "$code")"
    parse_code "$code"
    [[ "${CODE_KIND:-transit}" == "transit" ]] \
        || die "这是出口接入码（nat-exit-code），请用 wm import-exit-code 导入"

    ingress_id="${CODE_PROFILE_ID}-ingress"
    if [[ -f "$(profile_env_path "$ingress_id")" ]]; then
        # 入口线路已存在（IX 改/增规则后重导接入码）→ 更新而非报错
        local _upd="Y"
        prompt _upd "入口线路 ${ingress_id} 已存在，用此接入码更新它吗？[Y/n]" "Y"
        case "$_upd" in
            [Nn]*) die "已取消（如需彻底重建：wm stop ${ingress_id} 后删除其 profile 再重导）" ;;
        esac
        updating=1
        # 保留本机已配置的公网IP/网卡作默认值
        local _pv
        _pv="$(load_profile "$ingress_id" 2>/dev/null; printf '%s\t%s' "${INGRESS_PUBLIC_HOST:-}" "${WAN_IFACE:-}")" || _pv=""
        prev_host="${_pv%%$'\t'*}"
        prev_iface="${_pv#*$'\t'}"
        info "更新模式：停止旧线路 → 同步新接入码的规则集（保留各规则已选客户端入口端口）"
        stop_profile "$ingress_id" >/dev/null 2>&1 || true
    fi

    ing_priv="$(printf '%s' "$CODE_INGRESS_PRIVKEY_B64" | base64url_decode)"
    ing_pub="$(wg_pubkey_of "$ing_priv")"

    local egress_ip local_ip
    egress_ip="$(detect_public_ipv4)"
    local_ip="$(detect_local_ipv4)"
    [[ -n "$egress_ip" ]] && info "出网 IPv4（curl 探测）：${egress_ip}"
    [[ -n "$local_ip" ]]  && info "本机网卡 IPv4：${local_ip}（NAT 机器此为内网IP）"
    prompt public_ip "公网 IPv4（客户端连接本入口的地址）" "${prev_host:-${egress_ip:-$local_ip}}"
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${prev_iface:-${wan_iface:-eth0}}"
    # virtio_net native XDP 不可靠 → 默认 skb，省去 native 失败的折腾
    local ing_xdp_mode="native"
    nic_prefers_skb "$wan_iface" && { ing_xdp_mode="skb"; info "检测到 ${wan_iface} 为 virtio 网卡，Mimic 默认用 XDP skb 模式"; }

    printf '\n── 接入码摘要 ──\n'
    printf '  IX 端点: %s:%s\n' "$CODE_IX_ENDPOINT_HOST" "$CODE_WG_PORT"
    printf '  组网: 入口 %s ⇄ IX %s\n\n' "$CODE_INGRESS_WG_IP" "$CODE_IX_WG_IP"

    write_profile_kv "$(profile_env_path "$ingress_id")" \
        "PROFILE_ID=${ingress_id}" \
        "PROFILE_NAME=${ingress_id}" \
        "ROLE=nat-ingress" \
        "ENABLED=true" \
        "WAN_IFACE=${wan_iface}" \
        "INGRESS_PUBLIC_HOST=${public_ip}" \
        "WG_MESH_SUBNET=${CODE_WG_MESH_SUBNET}" \
        "WG_IX_IP=${CODE_IX_WG_IP}" \
        "WG_INGRESS_IP=${CODE_INGRESS_WG_IP}" \
        "IP_VERSION=${CODE_IP_VERSION:-4}" \
        "WG_MESH_SUBNET6=${CODE_WG_MESH_SUBNET6}" \
        "WG_IX_IP6=${CODE_IX_WG_IP6}" \
        "WG_INGRESS_IP6=${CODE_INGRESS_WG_IP6}" \
        "WG_PORT=${CODE_WG_PORT}" \
        "WG_MTU=${CODE_WG_MTU}" \
        "IX_ENDPOINT_HOST=${CODE_IX_ENDPOINT_HOST}" \
        "WG_PRIVATE_KEY=${ing_priv}" \
        "WG_PUBLIC_KEY=${ing_pub}" \
        "WG_PEER_PUBLIC_KEY=${CODE_IX_WG_PUBKEY}" \
        "FORWARD_PROTO=${CODE_FORWARD_PROTO}" \
        "MIMIC_KEEPALIVE=${CODE_MIMIC_KEEPALIVE:-300:::}" \
        "MIMIC_XDP_MODE=${ing_xdp_mode}" \
        "FW_OPEN_PORT=true"

    # 更新模式：删除新接入码里已不存在的旧规则（IX 端已删的）
    if [[ "$updating" == 1 ]]; then
        local _new_ids _old_rid
        _new_ids="$(printf '%s' "$CODE_RULES_TSV" | cut -f1 | tr '\n' ' ')"
        for _old_rid in $(list_rule_ids "$ingress_id"); do
            case " $_new_ids " in
                *" $_old_rid "*) : ;;
                *) rm -f "$(rule_env_path "$ingress_id" "$_old_rid")"; info "移除 IX 已删规则：${_old_rid}" ;;
            esac
        done
    fi

    local client_port=30000 rid note tport lhost lport rproto keep_cp
    while IFS=$'\t' read -r rid note tport lhost lport rproto; do
        [[ -n "$rid" ]] || continue
        keep_cp=""
        if [[ "$updating" == 1 ]]; then
            # 沿用该规则已选的客户端入口端口（IX 改的是中转/落地，客户端口不应变）
            keep_cp="$(load_rule "$ingress_id" "$rid" >/dev/null 2>&1 && printf '%s' "${CLIENT_PORT:-}")" || keep_cp=""
        fi
        if [[ -n "$keep_cp" ]]; then
            client_port="$keep_cp"
            info "规则 ${rid}（${note:-}）沿用已有客户端入口端口 ${client_port}"
        else
            # 默认与落地端口一致（客户端用同一端口号），回车即可；可手动改
            prompt_port client_port "规则 ${rid}（${note:-}）客户端入口端口" "${lport:-$client_port}"
        fi
        write_rule "$ingress_id" "$rid" \
            "RULE_ID=${rid}" \
            "RULE_NOTE=${note}" \
            "RULE_ENABLED=true" \
            "TRANSIT_PORT=${tport}" \
            "LANDING_HOST=${lhost}" \
            "LANDING_PORT=${lport}" \
            "FORWARD_PROTO=${rproto:-both}" \
            "CLIENT_PORT=${client_port}"
        client_port=$((client_port + 1))
    done <<<"$CODE_RULES_TSV"

    load_profile "$ingress_id"
    apply_nft_all
    ensure_ip_forward

    printf '\n═══ 公网入口已配置 ═══\n'
    show_port_map "$ingress_id"
    printf '\n执行：wm start %s\n' "$ingress_id"
    local _autostart=""
    prompt _autostart "现在就启动该线路吗？[Y/n]" "Y"
    case "$_autostart" in
        [Nn]*) info "稍后手动启动：wm start ${ingress_id}" ;;
        *) start_profile "$ingress_id" ;;
    esac
}

regenerate_code_if_transit() {
    [[ "${ROLE:-}" == "nat-transit" ]] || return 0
    local code; code="$(generate_code)"
    printf '%s\n' "$code" >"${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    warn "规则已变更：公网入口需用新接入码重新 import-code"
    local _ans=""
    [[ -e /dev/tty ]] && prompt _ans "现在显示更新后的接入码吗？[Y/n]" "Y"
    case "$_ans" in
        [Nn]*) info "稍后可用 wm show-code ${PROFILE_ID} 查看" ;;
        *) printf '\n═══ 新接入码（复制到公网入口：wm import-code）═══\n%s\n════════════════════════════════════════════\n' "$code" ;;
    esac
}

show_port_map() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    local rid
    printf '端口地图 — %s (%s)\n' "$PROFILE_ID" "${ROLE:-}"
    for rid in $(list_rule_ids "$PROFILE_ID"); do
        (
            load_rule "$PROFILE_ID" "$rid" || exit 0
            if [[ "${ROLE:-}" == "nat-ingress" ]]; then
                printf '  [%s] %s:%s → IX %s:%s → 落地 %s:%s (%s)\n' \
                    "${RULE_NOTE:-$rid}" "${INGRESS_PUBLIC_HOST:-公网IP}" "${CLIENT_PORT:-?}" \
                    "$WG_IX_IP" "$TRANSIT_PORT" "$LANDING_HOST" "$LANDING_PORT" "${FORWARD_PROTO:-both}"
            else
                printf '  [%s] IX %s:%s → 落地 %s:%s (%s)\n' \
                    "${RULE_NOTE:-$rid}" "$WG_IX_IP" "$TRANSIT_PORT" "$LANDING_HOST" "$LANDING_PORT" "${FORWARD_PROTO:-both}"
            fi
        )
    done
}

list_rules() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    local rid
    printf '线路 %s (%s) 规则：\n' "$PROFILE_ID" "${ROLE:-}"
    if [[ "${ROLE:-}" == "nat-transit" && -n "${TRANSIT_PORT_POOL:-}" ]]; then
        printf '  端口池: %s（共/已用/剩 = %s）\n' "$TRANSIT_PORT_POOL" "$(pool_stats "$PROFILE_ID" "$TRANSIT_PORT_POOL")"
    fi
    [[ -n "$(list_rule_ids "$PROFILE_ID")" ]] || { printf '  (无规则)\n'; return; }
    for rid in $(list_rule_ids "$PROFILE_ID"); do
        (
            load_rule "$PROFILE_ID" "$rid" || exit 0
            printf '  ── %s ──\n' "$RULE_ID"
            printf '     备注:     %s\n' "${RULE_NOTE:-}"
            printf '     启用:     %s\n' "${RULE_ENABLED:-true}"
            printf '     协议:     %s\n' "${FORWARD_PROTO:-both}"
            if [[ "${ROLE:-}" == "nat-ingress" ]]; then
                printf '     客户入口: %s:%s\n' "${INGRESS_PUBLIC_HOST:-公网IP}" "${CLIENT_PORT:-?}"
                printf '     中转:     IX %s:%s\n' "$WG_IX_IP" "$TRANSIT_PORT"
            else
                printf '     中转端口: IX %s:%s\n' "$WG_IX_IP" "$TRANSIT_PORT"
            fi
            printf '     落地:     %s:%s\n' "$LANDING_HOST" "$LANDING_PORT"
        )
    done
}

add_rule() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    local rid note transit_port landing_host landing_port proto client_port
    local tp_default="40001"
    rid="$(generate_unique_rule_id "$PROFILE_ID" "rule")"
    prompt note "规则备注" "$rid"
    if [[ -n "${TRANSIT_PORT_POOL:-}" ]]; then
        tp_default="$(pool_alloc_port "$PROFILE_ID" "$TRANSIT_PORT_POOL" "${WG_PORT:-}")" \
            || die "端口池 ${TRANSIT_PORT_POOL} 已用尽，请 wm set-pool 扩充或清空后手动指定"
    fi
    prompt_port transit_port "中转端口（IX 虚拟IP）" "$tp_default"
    if [[ -n "${TRANSIT_PORT_POOL:-}" ]]; then
        pool_contains "$TRANSIT_PORT_POOL" "$transit_port" \
            || die "端口 ${transit_port} 不在端口池 ${TRANSIT_PORT_POOL} 内"
    fi
    ! transit_port_in_use "$PROFILE_ID" "$transit_port" \
        || die "中转端口 ${transit_port} 已被本线路其它规则占用"
    prompt landing_host "落地 IP/域名"
    [[ -n "$landing_host" ]] || die "落地地址不能为空"
    prompt_port landing_port "落地端口"
    prompt proto "协议 tcp/udp/both" "${FORWARD_PROTO:-both}"
    validate_proto "$proto" || die "协议非法"
    local kv=( "RULE_ID=${rid}" "RULE_NOTE=${note}" "RULE_ENABLED=true" \
        "TRANSIT_PORT=${transit_port}" "LANDING_HOST=${landing_host}" \
        "LANDING_PORT=${landing_port}" "FORWARD_PROTO=${proto}" )
    if [[ "${ROLE:-}" == "nat-ingress" ]]; then
        prompt_port client_port "客户端入口端口" "30001"
        kv+=( "CLIENT_PORT=${client_port}" )
    fi
    write_rule "$PROFILE_ID" "$rid" "${kv[@]}"
    apply_nft_all
    regenerate_code_if_transit
    ok "已新增规则 ${rid}"
}

edit_rule() {
    local id rid; id="$(resolve_profile_id "${1:-}")"; rid="$(sanitize_id "${2:-}")"
    require_root
    [[ -n "${2:-}" ]] || die "用法: wm edit-rule <线路> <规则ID>"
    load_profile "$id"
    load_rule "$PROFILE_ID" "$rid" || die "规则不存在：$rid"
    local note transit_port landing_host landing_port proto client_port
    prompt note "规则备注" "${RULE_NOTE:-$rid}"
    prompt_port transit_port "中转端口" "${TRANSIT_PORT}"
    if [[ -n "${TRANSIT_PORT_POOL:-}" ]]; then
        pool_contains "$TRANSIT_PORT_POOL" "$transit_port" \
            || die "端口 ${transit_port} 不在端口池 ${TRANSIT_PORT_POOL} 内"
    fi
    ! transit_port_in_use "$PROFILE_ID" "$transit_port" "$rid" \
        || die "中转端口 ${transit_port} 已被本线路其它规则占用"
    prompt landing_host "落地 IP/域名" "${LANDING_HOST}"
    prompt_port landing_port "落地端口" "${LANDING_PORT}"
    prompt proto "协议 tcp/udp/both" "${FORWARD_PROTO:-both}"
    validate_proto "$proto" || die "协议非法"
    local kv=( "RULE_ID=${rid}" "RULE_NOTE=${note}" "RULE_ENABLED=${RULE_ENABLED:-true}" \
        "TRANSIT_PORT=${transit_port}" "LANDING_HOST=${landing_host}" \
        "LANDING_PORT=${landing_port}" "FORWARD_PROTO=${proto}" )
    if [[ "${ROLE:-}" == "nat-ingress" ]]; then
        prompt_port client_port "客户端入口端口" "${CLIENT_PORT:-30000}"
        kv+=( "CLIENT_PORT=${client_port}" )
    fi
    write_rule "$PROFILE_ID" "$rid" "${kv[@]}"
    apply_nft_all
    regenerate_code_if_transit
    ok "已更新规则 ${rid}"
}

delete_rule() {
    local id rid; id="$(resolve_profile_id "${1:-}")"; rid="$(sanitize_id "${2:-}")"
    require_root
    [[ -n "${2:-}" ]] || die "用法: wm delete-rule <线路> <规则ID>"
    load_profile "$id"
    local p; p="$(rule_env_path "$PROFILE_ID" "$rid")"
    [[ -f "$p" ]] || die "规则不存在：$rid"
    rm -f "$p"
    apply_nft_all
    regenerate_code_if_transit
    ok "已删除规则 ${rid}"
}

set_rule_enabled() {
    local id rid val; id="$(resolve_profile_id "${1:-}")"; rid="$(sanitize_id "${2:-}")"; val="$3"
    require_root
    [[ -n "${2:-}" ]] || die "用法: wm enable-rule/disable-rule <线路> <规则ID>"
    load_profile "$id"
    local p; p="$(rule_env_path "$PROFILE_ID" "$rid")"
    [[ -f "$p" ]] || die "规则不存在：$rid"
    if grep -q '^RULE_ENABLED=' "$p"; then
        sed -i "s/^RULE_ENABLED=.*/RULE_ENABLED=${val}/" "$p"
    else
        printf 'RULE_ENABLED=%s\n' "$val" >>"$p"
    fi
    apply_nft_all
    regenerate_code_if_transit
    ok "规则 ${rid} enabled=${val}"
}

enable_rule()  { set_rule_enabled "$1" "$2" "true"; }
disable_rule() { set_rule_enabled "$1" "$2" "false"; }

apply_rules() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    apply_nft_all
    ensure_ip_forward
    ok "已重建 nft 规则：${PROFILE_ID}"
}

# ── health / diagnose ──────────────────────────────────────────────────────

health_profile() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    local status="healthy" wg_iface; wg_iface="$(wg_iface_for "$PROFILE_ID")"

    printf '线路: %s (%s)\n' "$PROFILE_ID" "${ROLE:-unknown}"
    printf '组网: 入口 %s ⇄ IX %s  端口 %s  MTU %s\n' \
        "${WG_INGRESS_IP:-?}" "${WG_IX_IP:-?}" "${WG_PORT:-?}" "${WG_MTU:-?}"
    [[ "${ROLE:-}" == "nat-ingress" && -n "${INGRESS_PUBLIC_HOST:-}" ]] && \
        printf '客户端入口: %s\n' "$INGRESS_PUBLIC_HOST"
    [[ "${ENABLED:-true}" == "true" ]] && printf '线路: enabled\n' || { printf '线路: disabled\n'; status="degraded"; }

    if command_exists mimic; then
        if systemctl is-active --quiet "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null; then
            printf 'Mimic: active (%s, UDP→TCP)\n' "$WAN_IFACE"
        else
            printf 'Mimic: inactive\n'; status="degraded"
        fi
    else
        printf 'Mimic: not installed\n'; status="degraded"
    fi

    if systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
        printf 'WireGuard: active (%s)\n' "$wg_iface"
        wg show "$wg_iface" 2>/dev/null | sed 's/^/  /' || true
    else
        printf 'WireGuard: inactive\n'; status="degraded"
    fi

    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && printf 'IP forward: on\n' || { printf 'IP forward: off\n'; status="degraded"; }
    printf '规则数: %s\n' "$(list_rule_ids "$PROFILE_ID" | grep -c . || true)"
    printf 'HEALTH_STATUS=%s\n' "$status"
}

diagnose_profile() {
    local id line; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    printf '=== OS compatibility ===\n'
    compat_os_report | while IFS= read -r line; do printf '  %s\n' "$line"; done
    printf '=== preflight ===\n'
    command_exists nft && ok "nftables" || warn "缺少 nftables"
    command_exists wg && ok "wireguard-tools" || warn "缺少 wireguard-tools"
    command_exists mimic && ok "mimic CLI" || warn "缺少 mimic"
    mimic_module_loaded && ok "mimic kernel module" || warn "mimic 内核模块未加载"
    if kernel_ge_61; then ok "kernel >= 6.1 ($(uname -r))"; else warn "kernel < 6.1 ($(uname -r))"; fi
    [[ -f /sys/kernel/btf/vmlinux ]] && ok "BTF vmlinux" || warn "无 BTF（精简内核可能需 kprobe 编 mimic）"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok "ip_forward" || warn "ip_forward 未开启"
    [[ -n "${WAN_IFACE:-}" ]] && printf '  Mimic 绑定网卡: %s（驱动 %s，XDP %s）\n' \
        "$WAN_IFACE" "$(nic_driver "$WAN_IFACE")" "${MIMIC_XDP_MODE:-auto}"
    if [[ -n "${WAN_IFACE:-}" && -f "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf" ]]; then
        # mimic >= 0.7 没有 run --check；仅在支持时才校验配置，否则跳过避免误报
        if mimic run --help 2>&1 | grep -q -- '--check'; then
            mimic run --check -F "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf" "$WAN_IFACE" 2>&1 | sed 's/^/  /' || warn "mimic --check 失败"
        else
            printf '  mimic 配置: %s（本版 mimic 无 --check，跳过校验）\n' "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf"
        fi
    fi
    health_profile "$id"
}

install_deps() {
    require_root
    local id; id="$(detect_os_id)"
    info "检测到 OS: $id  内核: $(uname -r)"
    compat_os_report | sed 's/^/  /'
    echo ""
    case "$id" in
        debian|ubuntu)
            info "Debian/Ubuntu 推荐："
            cat <<'EOF'
  apt update
  apt install wireguard-tools mimic mimic-dkms python3 nftables
  modprobe mimic
EOF
            ;;
        arch)
            info "Arch："
            cat <<'EOF'
  pacman -S wireguard-tools python nftables
  # AUR: yay -S mimic-bpf mimic-bpf-dkms  (或 mimic-bpf-git)
EOF
            ;;
        fedora|centos|rhel|rocky|almalinux|ol)
            warn "RHEL 系默认内核常为 5.x，Mimic 需内核 ≥6.1"
            cat <<'EOF'
  # 方案 A（推荐）：换 Debian 13 / Ubuntu 24.04 VPS
  # 方案 B：elrepo 新内核（自行承担 DKMS 风险）
  dnf install epel-release
  dnf install wireguard-tools python3 nftables
  # 内核升级参考: https://elrepo.org/tiki/kernel-ml
  # mimic 无官方 RPM，需从源码编译:
  # git clone https://github.com/hack3ric/mimic && cd mimic && make && make install
EOF
            ;;
        alpine)
            warn "Alpine 为实验性支持，无 mimic-dkms"
            cat <<'EOF'
  apk add wireguard-tools python3 nftables iptables linux-headers \
      build-base clang llvm bpftool libbpf-dev bison flex
  # 从源码编译 mimic（musl 环境需自行验证）:
  # git clone https://github.com/hack3ric/mimic && cd mimic && make CHECKSUM_HACK=kprobe
EOF
            ;;
        *)
            warn "未识别发行版，通用依赖：wireguard-tools python3 mimic mimic-dkms nftables"
            ;;
    esac
    if ! kernel_ge_61; then
        warn "当前内核 < 6.1，请先升级内核再安装 mimic"
    fi
}

show_code() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-transit" ]] || die "仅 IX(nat-transit) 线路可 show-code"
    if [[ -f "${CODES_DIR}/${PROFILE_ID}.code" ]]; then
        cat "${CODES_DIR}/${PROFILE_ID}.code"
    else
        generate_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
        chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    fi
}

# 按当前规则重新生成接入码 —— 不轮换密钥、不重启隧道（密钥不变两端不会断流）。
# 改/增/删规则后用它把新规则集打进接入码即可（add-rule/edit-rule/delete-rule 已自动
# 调过一次，这里供手动按需再生）。要轮换密钥见 rotate_keys（那才会重启 IX）。
refresh_code() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-transit" ]] || die "仅 IX(nat-transit) 线路可 refresh-code"
    apply_nft_all
    generate_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    ok "已按当前规则刷新接入码（密钥不变，公网入口重新 import-code 即可，不会断流）"
}

# 轮换入口 WG 密钥对 + 刷新接入码（仅用于密钥泄露等场景，会短暂中断两端）。
rotate_keys() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-transit" ]] || die "仅 IX(nat-transit) 线路可 rotate-keys"
    local ing_priv ing_pub ing_priv_b64 path
    ing_priv="$(wg_genkey)"; ing_pub="$(wg_pubkey_of "$ing_priv")"
    ing_priv_b64="$(printf '%s' "$ing_priv" | base64url_encode)"
    path="$(profile_env_path "$PROFILE_ID")"
    sed -i "s|^WG_PEER_PUBLIC_KEY=.*|WG_PEER_PUBLIC_KEY=${ing_pub}|" "$path"
    if grep -q '^INGRESS_PRIVKEY_B64=' "$path"; then
        sed -i "s|^INGRESS_PRIVKEY_B64=.*|INGRESS_PRIVKEY_B64=${ing_priv_b64}|" "$path"
    else
        printf 'INGRESS_PRIVKEY_B64=%s\n' "$ing_priv_b64" >>"$path"
    fi
    load_profile "$id"
    apply_profile_configs
    # 关键：apply_profile_configs 只重写 conf 文件，不会动正在运行的接口。轮换换掉了
    # 对端公钥，若不重启，IX 内核里仍是旧 ingress 公钥 —— 公网入口用新私钥重导后两端
    # 公钥对不上、WG 永远不握手 → 该隧道上的全部规则一起中断。隧道在跑就重启使其生效。
    if systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
        info "重启 IX 隧道以加载新的对端公钥..."
        restart_profile "$PROFILE_ID"
    fi
    generate_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    warn "已轮换入口密钥：公网入口必须用新接入码重新 import-code（两端会短暂中断）"
}

# ── tunnel quality test / endpoint switch / auto-switch ─────────────────────

# The OTHER end's mesh IP — what we ping to measure tunnel quality end-to-end.
peer_mesh_ip() {
    if [[ "${ROLE:-}" == "nat-ingress" ]]; then printf '%s' "${WG_IX_IP:-}"; else printf '%s' "${WG_INGRESS_IP:-}"; fi
}

# Ping the peer over the tunnel; echo integer loss%% (0-100). Empty target → 100.
measure_tunnel_loss() {
    local target="$1" count="${2:-20}" out loss
    [[ -n "$target" ]] || { printf '100'; return 0; }
    out="$(ping -c "$count" -i 0.2 -W 2 "$target" 2>/dev/null || true)"
    loss="$(printf '%s' "$out" | sed -n 's/.* \([0-9]\{1,3\}\)% packet loss.*/\1/p' | head -1)"
    [[ "$loss" =~ ^[0-9]+$ ]] || loss=100
    printf '%s' "$loss"
}

# wm test [ID] [count] — measure real tunnel packet loss + rtt, with a verdict.
test_profile() {
    local id count; id="$(resolve_profile_id "${1:-}")"; count="${2:-100}"
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || count=100
    load_profile "$id"
    local target; target="$(peer_mesh_ip)"
    [[ -n "$target" ]] || die "线路 ${PROFILE_ID} 无对端虚拟IP，无法测试"
    printf '隧道测试 %s：ping 对端 %s（%s 包）...\n' "$PROFILE_ID" "$target" "$count"
    local out loss rtt
    out="$(ping -c "$count" -i 0.2 -W 2 "$target" 2>/dev/null || true)"
    loss="$(printf '%s' "$out" | sed -n 's/.* \([0-9]\{1,3\}\)% packet loss.*/\1/p' | head -1)"
    [[ "$loss" =~ ^[0-9]+$ ]] || loss=100
    rtt="$(printf '%s' "$out" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p' | head -1)"
    printf '  丢包: %s%%   平均延迟: %s ms\n' "$loss" "${rtt:-?}"
    if   (( loss <= 2 ));  then ok   "线路质量良好（丢包 ${loss}%）"
    elif (( loss <= 10 )); then warn "线路质量一般（丢包 ${loss}%，TCP/延迟测速可能受影响）"
    else                        warn "线路质量差（丢包 ${loss}%，建议换中转：wm set-endpoint ${PROFILE_ID} <新中转IP>）"
    fi
}

# wm set-endpoint <ID> <host> — switch which IX public/中转 address is used.
#  nat-ingress: rewrites mimic(remote=)/wg(Endpoint=) and restarts (dials the new 中转).
#  nat-transit: only goes into the access code → refresh it so ingresses re-import.
set_endpoint() {
    local id host; id="$(resolve_profile_id "${1:-}")"; host="${2:-}"
    require_root
    [[ -n "$host" ]] || die "用法: wm set-endpoint <线路> <新IX公网地址/中转IP>"
    load_profile "$id"
    set_or_append_kv "$(profile_env_path "$PROFILE_ID")" IX_ENDPOINT_HOST "$host"
    load_profile "$id"
    if [[ "${ROLE:-}" == "nat-ingress" ]]; then
        apply_profile_configs
        if systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
            restart_profile "$PROFILE_ID"
        fi
        ok "入口 ${PROFILE_ID} 已切到 IX 端点 ${host}:${WG_PORT}"
        sleep 3
        info "切换后隧道丢包：$(measure_tunnel_loss "$(peer_mesh_ip)" 20)%（wm test ${PROFILE_ID} 看详情）"
    else
        regenerate_code_if_transit
        ok "IX ${PROFILE_ID} 端点已设为 ${host}：公网入口需重新 import-code"
    fi
}

# wm set-endpoints <ID> ip1,ip2,... — candidate 中转 IPs for auto-switch.
set_endpoints() {
    local id csv; id="$(resolve_profile_id "${1:-}")"; csv="${2:-}"
    require_root
    load_profile "$id"
    set_or_append_kv "$(profile_env_path "$PROFILE_ID")" ENDPOINT_CANDIDATES "$csv"
    ok "候选中转(${PROFILE_ID})已设：${csv:-（已清空）}"
}

# wm autoswitch <ID> [threshold%] — if current 中转 loss exceeds threshold, probe
# the candidates and switch to the best one. Disruptive only when current is bad.
autoswitch_once() {
    local id threshold; id="$(resolve_profile_id "${1:-}")"; threshold="${2:-10}"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-ingress" ]] || die "autoswitch 仅用于公网入口(nat-ingress)线路"
    [[ -n "${ENDPOINT_CANDIDATES:-}" ]] || die "请先设候选中转：wm set-endpoints ${PROFILE_ID} ip1,ip2,..."
    local cur loss; cur="${IX_ENDPOINT_HOST}"
    loss="$(measure_tunnel_loss "$(peer_mesh_ip)" 20)"
    if (( loss <= threshold )); then
        info "autoswitch ${PROFILE_ID}: 当前 ${cur} 丢包 ${loss}% ≤ ${threshold}%，保持"
        return 0
    fi
    warn "autoswitch ${PROFILE_ID}: 当前 ${cur} 丢包 ${loss}% > ${threshold}%，探测候选..."
    local best="$cur" best_loss="$loss" ip l _arr
    IFS=',' read -ra _arr <<<"$ENDPOINT_CANDIDATES"
    for ip in "${_arr[@]}"; do
        ip="$(trim "$ip")"; [[ -n "$ip" && "$ip" != "$cur" ]] || continue
        set_or_append_kv "$(profile_env_path "$PROFILE_ID")" IX_ENDPOINT_HOST "$ip"
        load_profile "$id"; apply_profile_configs; restart_profile "$PROFILE_ID" >/dev/null 2>&1 || true
        sleep 3
        l="$(measure_tunnel_loss "$(peer_mesh_ip)" 20)"
        info "  候选 ${ip} 丢包 ${l}%"
        (( l < best_loss )) && { best="$ip"; best_loss="$l"; }
        (( l <= threshold )) && break
    done
    set_or_append_kv "$(profile_env_path "$PROFILE_ID")" IX_ENDPOINT_HOST "$best"
    load_profile "$id"; apply_profile_configs; restart_profile "$PROFILE_ID" >/dev/null 2>&1 || true
    ddns_state_set "autoswitch:${PROFILE_ID}" "$best"
    ok "autoswitch ${PROFILE_ID}: 选定 ${best}（丢包 ${best_loss}%）"
}

install_autoswitch_units() {
    local tmp; tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric autoswitch %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WM_BIN} autoswitch %i
EOF
    install -m 644 "$tmp" "$SYSTEMD_AUTOSWITCH_SERVICE"
    cat >"$tmp" <<'EOF'
[Unit]
Description=wg-mimic-fabric autoswitch timer %i

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_AUTOSWITCH_TIMER"
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
}

autoswitch_enable() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    [[ -n "${ENDPOINT_CANDIDATES:-}" ]] || die "请先 wm set-endpoints ${PROFILE_ID} ip1,ip2,..."
    install_autoswitch_units
    systemctl enable --now "wg-mimic-autoswitch@${PROFILE_ID}.timer" 2>/dev/null || true
    ok "已启用自动切换(${PROFILE_ID})：每 5 分钟测丢包，超阈值自动切候选中转"
}

autoswitch_disable() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    systemctl disable --now "wg-mimic-autoswitch@${id}.timer" 2>/dev/null || true
    ok "已停用自动切换(${id})"
}

set_profile_mtu() {
    local id mtu; id="$(resolve_profile_id "${1:-}")"; mtu="$2"
    [[ -n "$mtu" ]] || die "用法: wm set-mtu <ID> <MTU>"
    validate_mtu "$mtu"
    require_root
    load_profile "$id"
    sed -i "s/^WG_MTU=.*/WG_MTU=${mtu}/" "$(profile_env_path "$id")"
    load_profile "$id"
    apply_profile_configs
    if systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
        restart_profile "$id"
    fi
    ok "MTU 已设为 ${mtu}"
}

# 自动探测隧道可用 MTU：临时把 WG 接口 MTU 抬到探测上限，带 DF 二分 ping 对端虚拟IP，
# 找出封装(mimic+WG)后能过中转线路的最大内层包，据此 set-mtu。换中转线路后跑一下即
# 自适应；MSS 钳制(nft rt mtu)随 WG_MTU 自动跟随，无需手算。
auto_mtu() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    command_exists ping || die "需要 ping (iputils-ping)"
    local peer wgi
    case "${ROLE:-}" in
        nat-transit|exit)  peer="${WG_INGRESS_IP:-}" ;;
        nat-ingress|relay) peer="${WG_IX_IP:-}" ;;
        *) die "automtu 仅支持 nat-transit/nat-ingress/exit/relay 线路" ;;
    esac
    [[ -n "$peer" ]] || die "线路缺少对端虚拟IP"
    wgi="$(wg_iface_for "$id")"
    [[ -d "/sys/class/net/${wgi}" ]] || die "隧道接口 ${wgi} 未就绪，先 wm start ${id}"
    ping -c1 -W2 "$peer" >/dev/null 2>&1 \
        || die "隧道不通（ping ${peer} 失败）——先确保 wm test ${id} 能通再 automtu"

    local orig_mtu probe_ceiling=1440
    orig_mtu="$(cat "/sys/class/net/${wgi}/mtu" 2>/dev/null || echo 1420)"
    info "探测线路 ${id} 隧道 MTU（对端 ${peer}，接口 ${wgi}）..."
    ip link set dev "$wgi" mtu "$probe_ceiling" 2>/dev/null || true

    # 二分内层 ping 负载 N（实际内层 IP 包 = N + 28）。下限 1252→新 MTU≥1280(WG下限)。
    local lo=1252 hi=$((probe_ceiling - 28)) mid best=0
    while (( lo <= hi )); do
        mid=$(( (lo + hi) / 2 ))
        if ping -c1 -W2 -M do -s "$mid" "$peer" >/dev/null 2>&1; then
            best=$mid; lo=$(( mid + 1 ))
        else
            hi=$(( mid - 1 ))
        fi
    done
    ip link set dev "$wgi" mtu "$orig_mtu" 2>/dev/null || true

    if (( best == 0 )); then
        die "探测失败：内层 1280 字节都过不去，隧道路径 MTU < 1280(WG下限)。保持 MTU ${orig_mtu}，请排查中转线路"
    fi
    local new_mtu=$(( best + 28 ))
    info "探测结果：最大可过内层包 ${new_mtu} 字节"
    if (( new_mtu == orig_mtu )); then
        ok "当前 MTU ${orig_mtu} 已是最优，无需调整"
        return 0
    fi
    set_profile_mtu "$id" "$new_mtu"
    sleep 2
    if ping -c4 -W2 -M do -s "$(( new_mtu - 28 ))" "$peer" >/dev/null 2>&1; then
        ok "已自适应 WG_MTU=${new_mtu}（满包复测通过）"
    else
        warn "设为 ${new_mtu} 后满包复测仍丢包，可手动再降：wm set-mtu ${id} $(( new_mtu - 20 ))"
    fi
    info "⚠️ 对端需设同值：在对端机执行 wm set-mtu <对端线路ID> ${new_mtu}（或对端也跑 wm automtu）"
}

set_profile_xdp_mode() {
    local id mode; id="$(resolve_profile_id "${1:-}")"; mode="${2:-}"
    require_root
    load_profile "$id"
    if [[ -n "$mode" ]]; then
        [[ "$mode" == "skb" || "$mode" == "native" ]] || die "xdp_mode 只能是 skb 或 native"
        if grep -q '^MIMIC_XDP_MODE=' "$(profile_env_path "$id")"; then
            sed -i "s/^MIMIC_XDP_MODE=.*/MIMIC_XDP_MODE=${mode}/" "$(profile_env_path "$id")"
        else
            echo "MIMIC_XDP_MODE=${mode}" >>"$(profile_env_path "$id")"
        fi
    else
        sed -i '/^MIMIC_XDP_MODE=/d' "$(profile_env_path "$id")"
    fi
    load_profile "$id"
    apply_profile_configs
    restart_profile "$id"
    ok "XDP 模式已更新：${mode:-auto}"
}

set_transit_pool() {
    local id pool; id="$(resolve_profile_id "${1:-}")"; pool="${2:-}"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-transit" ]] || die "端口池仅用于 IX（nat-transit）线路"
    if [[ -n "$pool" ]]; then
        validate_port_pool "$pool" || die "端口池格式非法：$pool（示例 40000-40010,40050）"
    fi
    set_or_append_kv "$(profile_env_path "$PROFILE_ID")" TRANSIT_PORT_POOL "$pool"
    if [[ -n "$pool" ]]; then
        ok "端口池已设为 ${pool}（共/已用/剩 = $(pool_stats "$PROFILE_ID" "$pool")）"
    else
        ok "已清除端口池（恢复每条规则手动指定中转端口）"
    fi
}

restart_profile() {
    stop_profile "$(resolve_profile_id "${1:-}")"
    start_profile "$(resolve_profile_id "${1:-}")"
}

stop_all_profiles() {
    local id
    for id in $(list_profile_ids 2>/dev/null || true); do
        stop_profile "$id" 2>/dev/null || true
    done
}

stop_mimic_services() {
    local u
    for u in $(systemctl list-units --all --no-legend 'wg-mimic-mimic@*' 'mimic@*' 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$u" 2>/dev/null || true
        systemctl disable "$u" 2>/dev/null || true
    done
}

install_base_packages() {
    local id; id="$(detect_os_id)"
    info "安装基础依赖（wireguard-tools 等）..."
    case "$id" in
        debian|ubuntu)
            ensure_debian_kernel_headers || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                wireguard-tools python3 nftables curl git ca-certificates \
                build-essential pkg-config libbpf-dev libffi-dev \
                clang llvm bpftool pahole \
                2>/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y \
                wireguard-tools python3 nftables curl git ca-certificates
            ;;
        arch)
            pacman -Sy --noconfirm --needed wireguard-tools python3 nftables curl git \
                base-devel clang llvm bpftool libbpf libffi linux-headers 2>/dev/null \
                || pacman -Sy --noconfirm wireguard-tools python3 nftables
            ;;
        fedora)
            dnf install -y wireguard-tools python3 nftables curl git \
                gcc make clang llvm bpftool libbpf-devel libffi-devel \
                kernel-devel kernel-headers 2>/dev/null \
                || dnf install -y wireguard-tools python3 curl git
            ;;
        alpine)
            apk add --no-cache wireguard-tools python3 nftables curl git \
                build-base clang llvm bpftool-dev libbpf-dev libffi-dev linux-headers
            ;;
        rhel|centos|rocky|almalinux|ol)
            dnf install -y epel-release 2>/dev/null || true
            dnf install -y wireguard-tools python3 curl git gcc make \
                clang llvm libbpf-devel libffi-devel kernel-devel 2>/dev/null \
                || dnf install -y wireguard-tools python3 curl git
            ;;
        opensuse-leap|opensuse-tumbleweed|opensuse|sles)
            zypper -n install wireguard-tools python3 nftables curl git \
                gcc make clang llvm bpftool libbpf-devel libffi-devel kernel-devel 2>/dev/null \
                || zypper -n install wireguard-tools python3 curl git
            ;;
        *)
            warn "未识别 OS，跳过基础包批量安装"
            ;;
    esac
}

ensure_debian_kernel_headers() {
    local kver pkg
    command_exists apt-get || return 1
    kver="$(uname -r)"
    [[ -d "/lib/modules/${kver}/build" ]] && return 0
    pkg="linux-headers-${kver}"
    info "安装内核头文件：${pkg} ..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" 2>/dev/null; then
        [[ -d "/lib/modules/${kver}/build" ]] && return 0
    fi
    warn "运行内核 ${kver} 的精确头文件不可用"
    info "尝试 linux-headers-$(dpkg --print-architecture 2>/dev/null || echo amd64)（安装后可能需要 reboot）..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "linux-headers-$(dpkg --print-architecture 2>/dev/null || echo amd64)" || return 1
    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        warn "头文件与运行内核 ${kver} 不匹配 — 请 reboot 到新内核后再 wm install-mimic"
        return 1
    fi
}

ensure_mimic_kmod_loaded() {
    local kver dkms_ver
    kver="$(uname -r)"
    if modprobe mimic 2>/dev/null; then
        ok "mimic 内核模块已加载（内核 ${kver}）"
        return 0
    fi
    if command_exists dkms; then
        dkms_ver="$(dkms status mimic 2>/dev/null | head -1 | awk -F, '{gsub(/^ +| +$/,"",$2); print $2}')"
        [[ -n "$dkms_ver" ]] || dkms_ver="0.7.0+ds"
        if [[ -d "/lib/modules/${kver}/build" ]]; then
            info "为当前内核 ${kver} 编译 mimic 模块..."
            dkms install "mimic/${dkms_ver}" -k "$kver" 2>/dev/null || dkms autoinstall 2>/dev/null || true
        else
            warn "内核 ${kver} 无 build 目录，DKMS 无法为当前内核编译"
            warn "请执行：sudo reboot  或  sudo apt install linux-headers-${kver}"
        fi
        modprobe mimic 2>/dev/null && { ok "mimic 内核模块已加载"; return 0; }
    fi
    warn "mimic 内核模块未加载。运行：uname -r && lsmod | grep mimic"
    return 1
}

install_mimic_github_deb() {
    # shellcheck disable=SC1091
    [[ -f /etc/os-release ]] && source /etc/os-release
    local codename="${VERSION_CODENAME:-}"
    [[ -n "$codename" ]] || return 1
    command_exists apt-get || return 1
    local arch tmpd mimic_deb dkms_deb url
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
    tmpd="$(mktemp -d)"
    info "尝试从 GitHub Releases 下载 ${codename} .deb (${MIMIC_UPSTREAM_TAG})..."
    gh_curl "https://api.github.com/repos/hack3ric/mimic/releases/tags/${MIMIC_UPSTREAM_TAG}" "$tmpd/rel.json" \
        || { rm -rf "$tmpd"; return 1; }
    mapfile -t urls < <(python3 - "$tmpd/rel.json" "$codename" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
codename = sys.argv[2]
for a in data.get("assets", []):
    n = a["name"]
    if codename not in n or not n.endswith(".deb"):
        continue
    if "dbgsym" in n or "ddeb" in n:
        continue
    if "_mimic-dkms_" in n or n.endswith("_mimic-dkms.deb") or "mimic-dkms" in n:
        print("DKMS", a["browser_download_url"])
    elif "_mimic_" in n:
        print("MIMIC", a["browser_download_url"])
PY
)
    mimic_deb=""; dkms_deb=""
    local line kind u
    for line in "${urls[@]}"; do
        kind="${line%% *}"; u="${line#* }"
        [[ "$kind" == "MIMIC" ]] && mimic_deb="$u"
        [[ "$kind" == "DKMS" ]] && dkms_deb="$u"
    done
    [[ -n "$mimic_deb" && -n "$dkms_deb" ]] || { rm -rf "$tmpd"; return 1; }
    gh_curl "$mimic_deb" "$tmpd/mimic.deb" || { rm -rf "$tmpd"; return 1; }
    gh_curl "$dkms_deb" "$tmpd/mimic-dkms.deb" || { rm -rf "$tmpd"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmpd/mimic.deb" "$tmpd/mimic-dkms.deb" \
        || { rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    ok "已通过 GitHub .deb 安装 mimic"
    return 0
}

install_mimic_from_source() {
    local hack="${1:-kfunc}"
    local dir tag="${MIMIC_UPSTREAM_TAG}"
    [[ "$(detect_os_id)" == "alpine" ]] && hack="kprobe"
    kernel_ge_61 || warn "内核 < 6.1，源码编译的 mimic 可能无法运行"
    install_base_packages || true
    dir="$(mktemp -d /tmp/mimic-src.XXXXXX)"
    info "源码编译 mimic (${tag}, CHECKSUM_HACK=${hack})..."
    if command_exists git \
        && git clone --depth 1 --branch "$tag" https://github.com/hack3ric/mimic.git "$dir" 2>/dev/null; then
        :
    elif gh_curl "https://github.com/hack3ric/mimic/archive/refs/tags/${tag}.tar.gz" "$dir/src.tgz"; then
        tar xzf "$dir/src.tgz" -C "$dir" --strip-components=1 2>/dev/null
    fi
    [[ -f "$dir/Makefile" ]] || { rm -rf "$dir"; return 1; }
    make -C "$dir" CHECKSUM_HACK="$hack" build-cli build-kmod 2>/dev/null \
        || make -C "$dir" CHECKSUM_HACK="$hack" 2>/dev/null \
        || { rm -rf "$dir"; return 1; }
    [[ -x "$dir/out/mimic" ]] || { rm -rf "$dir"; return 1; }
    install -m 755 "$dir/out/mimic" /usr/local/bin/mimic
    if [[ -f "$dir/kmod/mimic.ko" ]]; then
        install -D -m 644 "$dir/kmod/mimic.ko" "/lib/modules/$(uname -r)/extra/mimic.ko" 2>/dev/null \
            || insmod "$dir/kmod/mimic.ko" 2>/dev/null || true
        depmod -a 2>/dev/null || true
    fi
    rm -rf "$dir"
    ok "mimic 已从源码安装到 /usr/local/bin/mimic"
    return 0
}

install_mimic_arch() {
    if pacman -Sy --noconfirm --needed mimic-bpf 2>/dev/null; then
        pacman -Sy --noconfirm --needed mimic-bpf-dkms 2>/dev/null || true
        return 0
    fi
    if command -v yay >/dev/null; then
        yay -S --noconfirm --needed mimic-bpf mimic-bpf-dkms && return 0
    fi
    if command -v paru >/dev/null; then
        paru -S --noconfirm --needed mimic-bpf mimic-bpf-dkms && return 0
    fi
    return 1
}

install_mimic_packages() {
    require_root
    local id; id="$(detect_os_id)"
    if command_exists mimic; then
        ok "mimic 已安装：$(mimic --version 2>/dev/null || command -v mimic)"
        ensure_mimic_kmod_loaded || true
        return 0
    fi
    if ! kernel_ge_61; then
        die "内核 $(uname -r) < 6.1，Mimic 无法运行。请升级内核（如 elrepo kernel-ml）或换 Debian/Ubuntu VPS"
    fi
    info "自动安装 mimic（OS: ${id}）..."
    case "$id" in
        debian|ubuntu)
            ensure_debian_kernel_headers || warn "内核头文件未就绪，mimic-dkms 可能无法编译"
            apt-get update -qq || true
            if apt-cache show mimic &>/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    wireguard-tools python3 nftables mimic mimic-dkms \
                    && { ensure_mimic_kmod_loaded || true; ok "apt 安装 mimic 完成"; return 0; }
            fi
            install_mimic_github_deb && { ensure_mimic_kmod_loaded || true; return 0; }
            warn "apt/GitHub .deb 失败，尝试源码编译..."
            install_mimic_from_source kfunc || die "mimic 安装失败"
            ;;
        arch)
            install_base_packages || true
            install_mimic_arch && { modprobe mimic 2>/dev/null || true; ok "Arch 包安装完成"; return 0; }
            warn "AUR 不可用，尝试源码编译..."
            install_mimic_from_source kfunc || die "mimic 安装失败"
            ;;
        fedora)
            install_mimic_from_source kfunc || die "mimic 源码安装失败"
            ;;
        alpine)
            install_mimic_from_source kprobe || die "mimic 源码安装失败（Alpine 用 kprobe）"
            ;;
        rhel|centos|rocky|almalinux|ol)
            install_mimic_from_source kfunc || die "mimic 源码安装失败"
            ;;
        opensuse-leap|opensuse-tumbleweed|opensuse|sles)
            install_mimic_from_source kfunc || die "mimic 源码安装失败"
            ;;
        *)
            install_base_packages || true
            install_mimic_from_source kfunc || {
                install_deps
                die "自动安装 mimic 失败，请按 install-deps 指引手动处理"
            }
            ;;
    esac
    modprobe mimic 2>/dev/null || insmod /lib/modules/"$(uname -r)"/extra/mimic.ko 2>/dev/null \
        || warn "modprobe mimic 失败，请检查内核模块"
    command_exists wg || warn "wireguard-tools 未就绪"
    ok "mimic 安装流程完成"
}

# Force-upgrade mimic (unlike install_mimic_packages it does NOT早退 when present).
# `wm update-mimic` → apt 仓库最新；`wm update-mimic <版本>` → 指定版本(GitHub .deb/源码)。
# 升级后卸载/重载内核模块并重启之前启用的线路，让新版本生效。
update_mimic() {
    require_root
    local want="${1:-}"
    [[ -n "$want" ]] && { [[ "$want" == v* ]] || want="v${want}"; export MIMIC_UPSTREAM_TAG="$want"; }
    kernel_ge_61 || die "内核 $(uname -r) < 6.1，Mimic 无法运行"
    local id before; id="$(detect_os_id)"
    before="$(mimic --version 2>/dev/null || echo 未装)"
    info "升级 mimic（当前 ${before}；目标 ${want:-apt仓库最新}）..."
    # 记录当前启用的线路，升级后重启
    local lines=() pid p
    while IFS= read -r pid; do [[ -n "$pid" ]] && lines+=("$pid"); done < <(
        for p in "$PROFILES_DIR"/*.env; do
            [[ -f "$p" ]] || continue
            # shellcheck disable=SC1090
            ( source "$p"; [[ "${ENABLED:-true}" == "true" ]] && printf '%s\n' "$PROFILE_ID" )
        done)
    case "$id" in
        debian|ubuntu)
            ensure_debian_kernel_headers || warn "内核头文件未就绪，DKMS 可能无法编译"
            apt-get update -qq 2>/dev/null || true
            if [[ -z "$want" ]] && apt-cache show mimic >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade mimic mimic-dkms 2>/dev/null \
                    || DEBIAN_FRONTEND=noninteractive apt-get install -y mimic mimic-dkms 2>/dev/null \
                    || install_mimic_github_deb || die "mimic 升级失败"
            else
                install_mimic_github_deb || install_mimic_from_source kfunc || die "mimic 升级失败"
            fi
            ;;
        arch)   install_mimic_arch || install_mimic_from_source kfunc || die "mimic 升级失败" ;;
        alpine) install_mimic_from_source kprobe || die "mimic 升级失败" ;;
        *)      install_mimic_from_source kfunc || die "mimic 升级失败" ;;
    esac
    # 停服务 → 卸旧模块 → 载新模块（XDP 占用时必须先停服务才能 modprobe -r）
    stop_mimic_services
    modprobe -r mimic 2>/dev/null || true
    ensure_mimic_kmod_loaded || warn "新模块未能加载，可能需 reboot 后 wm start <线路>"
    # 重启之前启用的线路，让新 CLI/模块生效
    for pid in "${lines[@]}"; do start_profile "$pid" >/dev/null 2>&1 || true; done
    local after; after="$(mimic --version 2>/dev/null || echo 未知)"
    ok "mimic 升级完成：${before} → ${after}"
}

# ── swgp-go（WireGuard 流量混淆，抗 DPI/过墙；可与 mimic 叠加）────────────────
# 链路: WG → swgp-go → mimic。swgp-go 是用户态 Go 代理，把 WG 的 UDP 混淆/加密成
# 另一种 UDP；mimic 再在外层把它伪装成 TCP。本节负责装它、渲染配置、跑 systemd。

# swgp-go 的 PSK 与 WireGuard PSK 同格式（base64 32B）。
swgp_genpsk() { wg genpsk; }

# 从 GitHub release 动态匹配 linux+arch 资产并安装 swgp-go 二进制（在线运行时调用）。
download_swgp_release() {
    local dest="$1" tmpd url
    command_exists python3 || return 1
    tmpd="$(mktemp -d)"
    gh_curl "https://api.github.com/repos/${SWGP_REPO}/releases/latest" "$tmpd/rel.json" \
        || { rm -rf "$tmpd"; return 1; }
    url="$(python3 - "$tmpd/rel.json" <<'PY' 2>/dev/null
import json, sys, platform
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
m = platform.machine().lower()
if m in ("x86_64", "amd64"):
    arch = ["x86-64-v3", "x86-64-v2", "x86-64", "amd64", "x86_64"]
elif m in ("aarch64", "arm64"):
    arch = ["arm64", "aarch64"]
else:
    arch = [m]
best = None; best_score = -1
for a in d.get("assets", []):
    n = a["name"].lower()
    if "linux" not in n or not any(t in n for t in arch):
        continue
    if n.endswith((".sha256", ".asc", ".sig", ".sbom", ".json", ".txt")):
        continue
    score = 2 if n.endswith((".tar.gz", ".tgz", ".zip")) else 1
    if score > best_score:
        best, best_score = a["browser_download_url"], score
print(best or "")
PY
)"
    [[ -n "$url" ]] || { rm -rf "$tmpd"; return 1; }
    gh_curl "$url" "$tmpd/pkg" || { rm -rf "$tmpd"; return 1; }
    case "$url" in
        *.zip)            command_exists unzip && unzip -o "$tmpd/pkg" -d "$tmpd" >/dev/null 2>&1 ;;
        *.tar.gz|*.tgz)   tar -xzf "$tmpd/pkg" -C "$tmpd" 2>/dev/null ;;
        *)                cp "$tmpd/pkg" "$tmpd/swgp-go" ;;
    esac
    local bin; bin="$(find "$tmpd" -type f -name 'swgp-go' 2>/dev/null | head -1)"
    [[ -n "$bin" ]] || { rm -rf "$tmpd"; return 1; }
    install -m 755 "$bin" "$dest"
    rm -rf "$tmpd"
}

install_swgp() {
    require_root
    if [[ -x "$SWGP_BIN" ]] || command_exists swgp-go; then
        ok "swgp-go 已安装"; return 0
    fi
    info "安装 swgp-go（WireGuard 混淆）..."
    if download_swgp_release "$SWGP_BIN"; then
        ok "已通过 GitHub release 安装 swgp-go"
    elif command_exists go; then
        info "release 不可用，改用 go install..."
        GOBIN=/usr/local/bin go install "github.com/${SWGP_REPO}/cmd/swgp-go@latest" \
            || die "swgp-go 安装失败（go install）"
        ok "已通过 go install 安装 swgp-go"
    else
        die "swgp-go 安装失败：无可用 release 资产且未装 go（可 apt install golang 后重试）"
    fi
}

# 渲染 swgp-go 配置 JSON：
#   render_swgp_conf server <proxy_listen_port> <wg_endpoint> <mode> <psk> [mtu] [fwmark]
#   render_swgp_conf client <wg_listen_port>   <proxy_endpoint> <mode> <psk> [mtu] [fwmark]
render_swgp_conf() {
    local kind="$1" p2="$2" p3="$3" mode="$4" psk="$5" mtu="${6:-1500}" fwmark="${7:-0}"
    python3 - "$kind" "$p2" "$p3" "$mode" "$psk" "$mtu" "$fwmark" <<'PY'
import json, sys
kind, p2, p3, mode, psk, mtu, fwmark = sys.argv[1:8]
mtu = int(mtu); fwmark = int(fwmark)
if kind == "server":
    obj = {"servers": [{
        "name": "wm", "proxyListen": f":{p2}", "proxyMode": mode, "proxyPSK": psk,
        "proxyFwmark": fwmark, "wgEndpoint": p3, "wgFwmark": 0, "mtu": mtu}]}
else:
    obj = {"clients": [{
        "name": "wm", "wgListen": f":{p2}", "wgFwmark": 0, "proxyEndpoint": p3,
        "proxyMode": mode, "proxyPSK": psk, "proxyFwmark": fwmark, "mtu": mtu}]}
print(json.dumps(obj, indent=2))
PY
}

# 写 swgp-go 配置到 /etc/wg-mimic-fabric/swgp/<id>.json（由 profile 字段渲染）。
apply_swgp_conf() {
    local id="$1"; shift
    install -d -m 700 "$SWGP_CONF_DIR"
    local tmp; tmp="$(mktemp)"
    render_swgp_conf "$@" >"$tmp"
    install -m 600 "$tmp" "${SWGP_CONF_DIR}/${id}.json"
    rm -f "$tmp"
}

install_swgp_units() {
    local swgp_bin; swgp_bin="$(resolve_bin swgp-go "$SWGP_BIN")"
    local tmp; tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric swgp-go %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${swgp_bin} -confPath ${SWGP_CONF_DIR}/%i.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_SWGP_TEMPLATE"
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
}

install_all() {
    require_root
    install_wm_cli
    if [[ "${WMF_SKIP_MIMIC:-}" != "1" ]]; then
        install_mimic_packages || warn "mimic 自动安装未成功，可稍后 wm install-mimic"
    else
        info "已跳过 mimic 安装（WMF_SKIP_MIMIC=1）"
    fi
    ok "install-all 完成"
}

uninstall_mimic_packages() {
    local id; id="$(detect_os_id)"
    info "卸载 mimic 相关组件..."
    modprobe -r mimic 2>/dev/null || true
    case "$id" in
        debian|ubuntu)
            if command_exists apt-get; then
                DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge mimic mimic-dkms 2>/dev/null \
                    || apt-get remove -y mimic mimic-dkms 2>/dev/null \
                    || warn "apt 移除 mimic 失败（可能未通过 apt 安装）"
            fi
            ;;
        arch)
            if command_exists pacman; then
                pacman -Rns --noconfirm mimic-bpf mimic-bpf-dkms 2>/dev/null \
                    || pacman -Rns --noconfirm mimic-bpf-git 2>/dev/null \
                    || warn "pacman 未找到 mimic 包（可能未安装）"
            fi
            ;;
        alpine)
            if command_exists apk; then
                apk del mimic mimic-dkms 2>/dev/null || warn "apk 未找到 mimic 包"
            fi
            ;;
        fedora|centos|rhel|rocky|almalinux|ol)
            warn "RHEL 系通常无 mimic 包，请手动删除源码安装文件"
            ;;
        *)
            warn "未识别 OS，请手动卸载 mimic"
            ;;
    esac
    # 清理可能残留的 mimic 配置（purge 时全部删除）
    if [[ -d "$MIMIC_CONF_DIR" ]]; then
        find "$MIMIC_CONF_DIR" -maxdepth 1 -name '*.conf' -type f -delete 2>/dev/null || true
    fi
    ok "mimic 卸载流程已执行"
}

purge_installation() {
    require_root
    local remove_mimic="true"
    if [[ "${WMF_PURGE_YES:-}" != "1" ]]; then
        cat <<'EOF' >&2

将完全清理 wg-mimic-fabric，包括：
  - 全部线路配置与密钥 (/etc/wg-mimic-fabric)
  - wm 管理脚本 (/usr/local/bin/wm, libexec)
  - WireGuard / Mimic 生成的配置
  - nft 防火墙规则
  - mimic 与 mimic-dkms 系统包（apt/pacman）

EOF
        printf '确认完全清理？[y/N] ' >&2
        local ans; read -r ans </dev/tty
        [[ "$(trim "${ans:-n}")" =~ ^[yY] ]] || die "已取消"
        if [[ "${WMF_PURGE_NO_MIMIC:-}" != "1" ]]; then
            printf '同时卸载系统 mimic 包？[Y/n] ' >&2
            read -r ans </dev/tty
            [[ "$(trim "${ans:-y}")" =~ ^[nN] ]] && remove_mimic="false"
        fi
    else
        [[ "${WMF_PURGE_NO_MIMIC:-}" == "1" ]] && remove_mimic="false"
    fi
    stop_mimic_services
    uninstall_wm_core true
    rm -rf "$BACKUP_DIR"
    [[ "$remove_mimic" == "true" ]] && uninstall_mimic_packages
    ok "已完全 purge（含本地脚本与 mimic）"
}

# remove_configs=true → purge；false → uninstall（保留 /etc/wg-mimic-fabric）
uninstall_wm_core() {
    local remove_configs="${1:-false}"
    local ids=() ifaces=() id iface wg_iface
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(list_profile_ids 2>/dev/null || true)
    stop_mimic_services
    stop_all_profiles 2>/dev/null || true
    for id in "${ids[@]}"; do
        wg_iface="$(wg_iface_for "$id")"
        systemctl disable "wg-mimic-tunnel@${id}.service" 2>/dev/null || true
        remove_tunnel_mimic_dropin "$id"
        load_profile "$id" 2>/dev/null && ifaces+=("$WAN_IFACE") || true
        if [[ "$remove_configs" == "true" ]]; then
            rm -f "${WG_CONF_DIR}/${wg_iface}.conf"
        fi
    done
    for iface in $(printf '%s\n' "${ifaces[@]}" | sort -u); do
        [[ -n "$iface" ]] || continue
        systemctl disable "wg-mimic-mimic@${iface}.service" 2>/dev/null || true
        if [[ "$remove_configs" == "true" ]]; then
            rm -f "${MIMIC_CONF_DIR}/${iface}.conf"
        fi
    done
    if [[ "$remove_configs" == "true" ]]; then
        if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
            nft delete table inet "$NFT_TABLE" 2>/dev/null || true
        fi
        rm -f "$NFT_FILE" "$SYSCTL_FILE"
        rm -rf "$CONFIG_DIR" "$LIBEXEC_DIR"
    fi
    systemctl disable --now wg-mimic-ddns.timer 2>/dev/null || true
    systemctl disable wg-mimic-resume.service 2>/dev/null || true
    local _asw
    for _asw in $(systemctl list-units --all --no-legend 'wg-mimic-autoswitch@*.timer' 2>/dev/null | awk '{print $1}'); do
        systemctl disable --now "$_asw" 2>/dev/null || true
    done
    rm -f "$WM_BIN" "$SYSTEMD_MIMIC_TEMPLATE" "$SYSTEMD_TUNNEL_TEMPLATE" "$SYSTEMD_DDNS_SERVICE" "$SYSTEMD_DDNS_TIMER" "$SYSTEMD_AUTOSWITCH_SERVICE" "$SYSTEMD_AUTOSWITCH_TIMER" "$SYSTEMD_RESUME_SERVICE"
    # 大写别名（若存在）
    rm -f "/usr/local/bin/WM" 2>/dev/null || true
    if [[ "$remove_configs" == "true" ]]; then
        rmdir "$LIBEXEC_DIR" 2>/dev/null || true
    fi
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$remove_configs" != "true" ]]; then
        info "配置保留于 ${CONFIG_DIR}，备份目录 ${BACKUP_DIR}"
    fi
}

uninstall_wm() {
    require_root
    if [[ "${WMF_UNINSTALL_YES:-}" != "1" ]]; then
        printf '卸载 wm CLI 与 systemd 服务，保留线路配置。确认？[y/N] ' >&2
        local ans; read -r ans </dev/tty
        [[ "$(trim "${ans:-n}")" =~ ^[yY] ]] || die "已取消"
    fi
    uninstall_wm_core false
    ok "已卸载 wm（配置已保留，可重新 install-wm-cli 后 wm start）"
}

uninstall_from_menu() {
    require_root
    [[ -t 0 ]] || die "需要交互终端"
    cat <<'EOF'

卸载 wg-mimic-fabric

  1) 卸载服务（保留 /etc/wg-mimic-fabric 配置）
  2) 完全清理 purge（配置+本地脚本+mimic 包）
  0) 取消
EOF
    local mode; read -r -p "请选择: " mode </dev/tty
    case "$(trim "$mode")" in
        1) uninstall_wm ;;
        2) purge_installation ;;
        0|"") return 0 ;;
        *) warn "未知选项" ;;
    esac
}

# ── CLI install ────────────────────────────────────────────────────────────

install_wm_cli() {
    require_root
    ensure_dirs
    install -d -m 755 "$LIBEXEC_DIR"
    install -m 755 "$0" "$WM_CLI_INSTALL_SH"
    cat >"$WM_BIN" <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/libexec/wg-mimic-fabric/install.sh "$@"
WRAP
    chmod 755 "$WM_BIN"
    install_systemd_units
    ok "已安装 wm 命令：$WM_BIN"
    if [[ "${WMF_AUTO_MIMIC:-1}" == "1" && "${WMF_SKIP_MIMIC:-}" != "1" ]]; then
        install_mimic_packages 2>/dev/null || warn "mimic 未自动装上，请运行：wm install-mimic"
    fi
}

usage() {
    cat <<EOF
wg-mimic-fabric ${SCRIPT_VERSION} — 公网入口 ⇄ IX WireGuard 组网 + Mimic 伪 TCP + nft 转发

用法:
  wm                              交互菜单
  wm --version
  wm create-transit               IX 机：创建组网线路+首条规则并生成接入码
  wm import-code                  公网入口：粘贴接入码，自动组网与转发
  wm create-exit                  B(国外出口)：建混淆组网(WG+swgp-go+mimic)并生成出口接入码
  wm import-exit-code             A(国内网关)：粘贴出口接入码，建到 B 的混淆隧道
  wm add-client <网关> <名>        A：生成客户端 WG 配置+二维码（官方App/小火箭/mihomo/sing-box）
  wm list-clients [网关] / wm del-client <网关> <名>
  wm start|stop|restart [ID]      启停线路（两端均需 WG+Mimic）
  wm delete-line <ID>             删除整条线路（保留同机其它线路；WMF_DELETE_YES=1 跳过确认）
  wm list-profiles
  wm show-config [ID]
  wm show-code [ID]               显示 IX 接入码
  wm refresh-code [ID]            按当前规则刷新接入码（不换密钥、不断流）
  wm rotate-keys [ID]             轮换入口密钥并刷新接入码（会重启IX，公网入口需重导）
  wm show-port-map [ID]           端口地图
  wm list-rules [ID]
  wm add-rule [ID]
  wm edit-rule <ID> <规则ID>
  wm delete-rule <ID> <规则ID>
  wm enable-rule|disable-rule <ID> <规则ID>
  wm apply-rules [ID]             重建 nft 规则
  wm set-pool <ID> [端口池]        IX 中转端口池(如 40000-40010,40050；留空=清除，规则自动分配)
  wm health [ID] / wm diagnose [ID] / wm health-all
  wm test [ID] [包数]             测隧道真实丢包/延迟（判断中转线路质量；默认100包）
  wm set-endpoint <ID> <中转IP>    切换该线路用的 IX 公网/中转地址（入口侧即时生效）
  wm set-endpoints <ID> ip1,ip2,..  设置自动切换的候选中转列表
  wm autoswitch <ID> [阈值%]       测当前丢包，超阈值(默认10%)自动切到最优候选中转
  wm autoswitch-enable|autoswitch-disable <ID>   定时自动切换(每5分钟)
  wm ddns-enable|ddns-disable|ddns-status|ddns-refresh   域名 IP 变化自动刷新(每3分钟)
  wm set-group <ID> <组名> [primary|backup|standalone] [优先级]
  wm list-groups / switch-line <组名> <目标ID> / primary-backup-check <组名>
  wm set-mtu <ID> <MTU> / wm set-xdp-mode <ID> [skb|native]
  wm automtu <ID>                 自动探测隧道可用 MTU 并设置（换中转线路后跑一下即自适应；两端各跑）
  wm install-all|install-mimic|install-deps|compat
  wm update-mimic [版本]           升级 mimic 到 apt 最新或指定版本（重载模块+重启线路）
  wm install-swgp                  安装 swgp-go（WireGuard 混淆，过墙用）
  wm upgrade-script / wm uninstall / wm purge

架构: 客户端 → 公网入口:client_port → WG(Mimic 伪TCP) → IX 虚拟IP:transit_port → 落地

环境变量:
  WMF_TAG=v1.0.0                  安装/升级时指定版本
  WMF_REPO=ike-sh/wg-mimic-fabric GitHub 仓库
  WMF_UPGRADE_YES=1               升级跳过确认
  WMF_PURGE_YES=1                 purge 跳过确认
  WMF_UNINSTALL_YES=1             uninstall 跳过确认
  WMF_SKIP_MIMIC=1                跳过 mimic 自动安装
  WMF_AUTO_MIMIC=0                install-wm-cli 时不自动装 mimic
  WMF_PURGE_NO_MIMIC=1            purge 时保留 mimic 系统包
  WMF_GITHUB_MIRRORS=url,...      GitHub 下载镜像
EOF
}

show_menu() {
    require_tty() { [[ -t 0 ]] || die "需要交互终端"; }
    require_tty
    while true; do
        cat <<'MENU'

╔══════════════════════════════════════╗
║     wg-mimic-fabric 管理菜单         ║
╠══════════════════════════════════════╣
║  1) IX 创建组网线路（生成接入码）    ║
║  2) 公网入口导入接入码               ║
║  3) 启动线路                         ║
║  4) 停止线路                         ║
║  5) 健康检查                         ║
║  6) 列出线路                         ║
║  7) 显示接入码（IX）                 ║
║  8) 刷新接入码（IX）                 ║
║  9) 端口地图                         ║
║ 10) 规则管理（列出/增/删）           ║
╟─── 混淆组网 / 全局出口 ──────────────╢
║ 11) 创建国外出口 B（create-exit）    ║
║ 12) 导入出口接入码 A                 ║
║ 13) 客户端管理（增/列/删）           ║
╟──────────────────────────────────────╢
║ 14) 删除线路（delete-line）          ║
║ 15) 升级脚本                         ║
║ 16) 卸载 / 完全清理                  ║
║  0) 退出                             ║
╚══════════════════════════════════════╝
MENU
        local choice id rid
        read -r -p "选择: " choice </dev/tty
        case "$(trim "$choice")" in
            1) create_transit_interactive ;;
            2) import_code_interactive ;;
            3) if id="$(menu_pick_profile)"; then start_profile "$id"; fi ;;
            4) if id="$(menu_pick_profile)"; then stop_profile "$id"; fi ;;
            5) if id="$(menu_pick_profile)"; then health_profile "$id"; fi ;;
            6) list_profile_ids | sed 's/^/  /' || printf '  (无线路)\n' ;;
            7) if id="$(menu_pick_profile)"; then show_code "$id"; fi ;;
            8) if id="$(menu_pick_profile)"; then refresh_code "$id"; fi ;;
            9) if id="$(menu_pick_profile)"; then show_port_map "$id"; fi ;;
            10)
                local _lines _l
                _lines="$(list_profile_ids)"
                if [[ -z "$_lines" ]]; then
                    warn "暂无线路，请先用 1)IX 创建 或 2)入口导入"
                else
                    printf '\n现有线路与规则：\n'
                    while IFS= read -r _l; do [[ -n "$_l" ]] && list_rules "$_l"; done <<<"$_lines"
                    if id="$(menu_pick_profile)"; then
                        printf '  操作:\n'
                        printf '    1) 新增规则\n'
                        printf '    2) 编辑规则\n'
                        printf '    3) 删除规则\n'
                        printf '    4) 设置端口池\n'
                        printf '    回车) 返回\n'
                        read -r -p "选择操作: " rid </dev/tty
                        case "$(trim "$rid")" in
                            1|add) add_rule "$id" ;;
                            2|edit) if rid="$(menu_pick_rule "$id")"; then edit_rule "$id" "$rid"; fi ;;
                            3|del) if rid="$(menu_pick_rule "$id")"; then delete_rule "$id" "$rid"; fi ;;
                            4|pool) read -r -p "端口池(如 18300-18399；留空=清除): " rid </dev/tty; set_transit_pool "$id" "$(trim "$rid")" ;;
                            *) : ;;
                        esac
                    fi
                fi
                ;;
            11) create_exit_interactive ;;
            12) import_exit_code ;;
            13)
                if id="$(menu_pick_profile relay)"; then
                    printf '  操作:\n'
                    printf '    1) 新增客户端\n'
                    printf '    2) 列出客户端\n'
                    printf '    3) 删除客户端\n'
                    printf '    回车) 返回\n'
                    read -r -p "选择操作: " rid </dev/tty
                    case "$(trim "$rid")" in
                        1) read -r -p "客户端名: " rid </dev/tty; add_client "$id" "$(trim "$rid")" ;;
                        2) list_clients "$id" ;;
                        3) if rid="$(menu_pick_client "$id")"; then del_client "$id" "$rid"; fi ;;
                        *) : ;;
                    esac
                fi
                ;;
            14) if id="$(menu_pick_profile)"; then delete_profile "$id"; fi ;;
            15) upgrade_script; ok "重新加载菜单以应用新版本..."; exec "$WM_BIN" ;;
            16) uninstall_from_menu ;;
            0|q|Q) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        --version|-V) printf 'wg-mimic-fabric %s\n' "$SCRIPT_VERSION"; exit 0 ;;
        --help|-h|help) usage; exit 0 ;;
        install-wm-cli) install_wm_cli ;;
        install-mimic) install_mimic_packages ;;
        update-mimic) update_mimic "${2:-}" ;;
        install-swgp) install_swgp ;;
        install-all) install_all ;;
        install-deps) install_deps ;;
        compat) compat_os_report ;;
        resume) resume_after_boot ;;
        create-transit) create_transit_interactive ;;
        import-code) import_code_interactive ;;
        create-exit) create_exit_interactive ;;
        import-exit-code) import_exit_code ;;
        add-client) add_client "${2:-}" "${3:-}" ;;
        list-clients) list_clients "${2:-}" ;;
        del-client) del_client "${2:-}" "${3:-}" ;;
        start) start_profile "$(resolve_profile_id "${2:-}")" ;;
        stop) stop_profile "$(resolve_profile_id "${2:-}")" ;;
        restart) restart_profile "${2:-}" ;;
        delete-line|remove) delete_profile "${2:-}" ;;
        list-profiles) list_profile_ids ;;
        show-config) load_profile "$(resolve_profile_id "${2:-}")"; cat "$(profile_env_path "$PROFILE_ID")" ;;
        show-code) show_code "${2:-}" ;;
        refresh-code) refresh_code "${2:-}" ;;
        rotate-keys) rotate_keys "${2:-}" ;;
        show-port-map) show_port_map "${2:-}" ;;
        list-rules) list_rules "${2:-}" ;;
        add-rule) add_rule "${2:-}" ;;
        edit-rule) edit_rule "${2:-}" "${3:-}" ;;
        delete-rule) delete_rule "${2:-}" "${3:-}" ;;
        enable-rule) enable_rule "${2:-}" "${3:-}" ;;
        disable-rule) disable_rule "${2:-}" "${3:-}" ;;
        apply-rules) apply_rules "${2:-}" ;;
        ddns-refresh) ddns_refresh ;;
        ddns-enable) ddns_enable ;;
        ddns-disable) ddns_disable ;;
        ddns-status) ddns_status ;;
        set-group) set_line_group "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
        list-groups) list_groups ;;
        switch-line) switch_line "${2:-}" "${3:-}" ;;
        primary-backup-check) primary_backup_check "${2:-}" ;;
        health-all) health_all ;;
        test) test_profile "${2:-}" "${3:-}" ;;
        set-endpoint) set_endpoint "${2:-}" "${3:-}" ;;
        set-endpoints) set_endpoints "${2:-}" "${3:-}" ;;
        autoswitch) autoswitch_once "${2:-}" "${3:-}" ;;
        autoswitch-enable) autoswitch_enable "${2:-}" ;;
        autoswitch-disable) autoswitch_disable "${2:-}" ;;
        set-pool) set_transit_pool "${2:-}" "${3:-}" ;;
        set-mtu) set_profile_mtu "${2:-}" "${3:-}" ;;
        automtu) auto_mtu "${2:-}" ;;
        set-xdp-mode) set_profile_xdp_mode "${2:-}" "${3:-}" ;;
        apply-nft-all) require_root; apply_nft_all; ok "nft 规则已重建" ;;
        upgrade-script) upgrade_script ;;
        uninstall) uninstall_wm ;;
        purge) purge_installation ;;
        health) health_profile "${2:-}" ;;
        diagnose) diagnose_profile "${2:-}" ;;
        "") [[ -t 0 ]] && show_menu || { usage; exit 1; } ;;
        *) usage; die "未知命令：$cmd" ;;
    esac
}

[[ "${WMF_SOURCED:-}" == "1" ]] || main "$@"
