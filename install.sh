#!/usr/bin/env bash
# wg-mimic-fabric — WireGuard + Mimic tunnel orchestrator (MVP)
set -Eeuo pipefail

SCRIPT_VERSION="0.6.7"
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

wg_iface_for() { printf 'wm-%s' "$(sanitize_id "$1")"; }

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
    local pid="$1" spec="$2" used p
    used="$(pool_used_ports "$pid" | sort -u)"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        grep -qxF "$p" <<<"$used" && continue
        printf '%s' "$p"; return 0
    done < <(expand_port_pool "$spec")
    return 1
}

# True when PORT belongs to the expanded pool SPEC.
pool_contains() {
    local spec="$1" port="$2"
    expand_port_pool "$spec" | grep -qxF "$port"
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

parse_code() {
    local code="$1" json schema role
    json="$(parse_wmgf_code "$code")"
    schema="$(json_get "$json" code_schema)"
    role="$(json_get "$json" role)"
    [[ "$schema" == "5" && "$role" == "nat-transit-code" ]] \
        || die "不是有效的 v0.6 接入码（需 code_schema=5 nat-transit-code）"
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
    CODE_FORWARD_PROTO="$(json_get "$json" forward_proto)"
    CODE_IP_VERSION="$(json_get "$json" ip_version)"
    CODE_WG_MESH_SUBNET6="$(json_get "$json" wg_mesh_subnet6)"
    CODE_IX_WG_IP6="$(json_get "$json" ix_wg_ip6)"
    CODE_INGRESS_WG_IP6="$(json_get "$json" ingress_wg_ip6)"
    CODE_RULES_TSV="$(json_get "$json" rules_b64 | base64url_decode)"
}

ensure_mimic() {
    command_exists mimic || die "未找到 mimic，请安装：apt install mimic mimic-dkms"
    modprobe mimic 2>/dev/null || warn "mimic 内核模块未加载，请安装 mimic-dkms"
}

mimic_module_loaded() { lsmod 2>/dev/null | grep -q '^mimic '; }

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
        printf '当前 %s → 远端 %s。确认升级？[y/N] ' "$cur" "${remote_ver:-?}" >&2
        local ans; read -r ans </dev/tty
        [[ "$(trim "${ans:-n}")" =~ ^[yY] ]] || { rm -f "$tmp"; die "已取消"; }
    fi
    install -d -m 755 "$BACKUP_DIR"
    [[ -f "$WM_CLI_INSTALL_SH" ]] && cp -a "$WM_CLI_INSTALL_SH" "${BACKUP_DIR}/install.sh.bak.$(date +%Y%m%d%H%M%S)"
    install -m 755 "$tmp" "$WM_CLI_INSTALL_SH"
    rm -f "$tmp"
    ok "已升级至 ${remote_ver:-unknown}"
}

assume_yes() { [[ "${WMF_PURGE_YES:-}${WMF_UPGRADE_YES:-}" == *1* ]]; }

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
                [[ -n "${MIMIC_XDP_MODE:-}" ]] && printf 'xdp_mode = %s\n' "$MIMIC_XDP_MODE"
                render_mimic_conf_for_profile
            )
        done
    }
}

apply_mimic_conf_iface() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || die "WAN_IFACE 不能为空"
    local path="${MIMIC_CONF_DIR}/${iface}.conf"
    backup_file "$path"
    render_mimic_conf_iface "$iface" >"$path"
    chmod 644 "$path"
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
        printf '    }\n'
        printf '    chain forward {\n'
        printf '        type filter hook forward priority filter; policy accept;\n'
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

install_systemd_units() {
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric Mimic on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStartPre=/sbin/modprobe mimic
ExecStart=/usr/bin/mimic run %i -F /etc/mimic/%i.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    install -m 644 "$tmp" "$SYSTEMD_MIMIC_TEMPLATE"

    cat >"$tmp" <<'EOF'
[Unit]
Description=wg-mimic-fabric WireGuard tunnel %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up /etc/wireguard/wm-%i.conf
ExecStop=/usr/bin/wg-quick down /etc/wireguard/wm-%i.conf

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
    local tmp; tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
After=wg-mimic-mimic@${iface}.service
Requires=wg-mimic-mimic@${iface}.service
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

start_profile() {
    require_root
    load_profile "$1"
    local path; path="$(profile_env_path "$PROFILE_ID")"
    grep -q '^ENABLED=' "$path" 2>/dev/null && sed -i 's/^ENABLED=.*/ENABLED=true/' "$path"
    load_profile "$1"
    if mimic_needs_reboot; then
        offer_reboot "start ${PROFILE_ID}"
    fi
    ensure_mimic
    apply_profile_configs
    apply_nft_all
    ensure_ip_forward
    systemctl enable --now "wg-mimic-mimic@${WAN_IFACE}.service"
    systemctl enable --now "wg-mimic-tunnel@${PROFILE_ID}.service"
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
    apply_nft_all
    if [[ -n "${WAN_IFACE:-}" ]]; then
        apply_mimic_conf_iface "$WAN_IFACE"
        systemctl try-restart "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null \
            || systemctl stop "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null || true
    fi
    ok "已停止线路：${PROFILE_ID}"
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

    local egress_ip local_ip
    egress_ip="$(detect_public_ipv4)"
    local_ip="$(detect_local_ipv4)"
    [[ -n "$egress_ip" ]] && info "出网 IPv4（curl 探测）：${egress_ip}"
    [[ -n "$local_ip" ]]  && info "本机网卡 IPv4：${local_ip}（NAT 机器此为内网IP）"
    info "请填「公网入口能连到本机的公网地址」；NAT/多IP 机器若是另配的浮动公网IP，请手动填写"
    prompt endpoint_host "公网入口可达的 IX 公网地址（域名或IP）" "${egress_ip:-$local_ip}"
    [[ -n "$endpoint_host" ]] || die "IX 可达地址不能为空"
    prompt_port wg_port "WireGuard 监听端口（Mimic 伪 TCP 绑定）" "51820"
    prompt wg_mtu "WG 隧道 MTU" "1420"
    validate_mtu "$wg_mtu"
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${wan_iface:-eth0}"

    prompt subnet "组网网段" "$(default_mesh_subnet)"
    prompt ix_ip "IX 虚拟 IP" "$(default_ix_ip)"
    prompt ingress_ip "公网入口虚拟 IP" "$(default_ingress_ip)"
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

    prompt transit_pool "中转端口池（如 40000-40010,40050；留空=每条规则手动指定）" ""
    if [[ -n "$transit_pool" ]]; then
        validate_port_pool "$transit_pool" || die "端口池格式非法：$transit_pool"
        tp_default="$(pool_alloc_port "$profile_id" "$transit_pool")" || die "端口池为空"
    fi

    info "首条转发规则（落地可填 IPv6）："
    prompt_port transit_port "中转端口（IX 虚拟IP 上的端口）" "$tp_default"
    if [[ -n "$transit_pool" ]]; then
        pool_contains "$transit_pool" "$transit_port" || die "端口 ${transit_port} 不在端口池 ${transit_pool} 内"
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
    if mimic_needs_reboot; then
        offer_reboot "start ${profile_id}"
    fi
}

import_code_interactive() {
    require_root
    ensure_dirs
    command_exists nft || die "需要 nftables"
    command_exists wg || die "需要 wireguard-tools"
    install_mimic_packages || die "公网入口需要 mimic（UDP 伪装 TCP）"
    ensure_mimic_kmod_loaded || warn "mimic 内核模块未加载，请 reboot 或安装 linux-headers-\$(uname -r)"

    local code ingress_id wan_iface public_ip ing_priv ing_pub
    printf '请粘贴 WMGF1: IX 接入码：' >&2
    read -r code </dev/tty
    code="$(trim "$code")"
    parse_code "$code"

    ingress_id="${CODE_PROFILE_ID}-ingress"
    [[ ! -f "$(profile_env_path "$ingress_id")" ]] || die "入口线路已存在：$ingress_id（可先 wm stop 后删除）"

    ing_priv="$(printf '%s' "$CODE_INGRESS_PRIVKEY_B64" | base64url_decode)"
    ing_pub="$(wg_pubkey_of "$ing_priv")"

    local egress_ip local_ip
    egress_ip="$(detect_public_ipv4)"
    local_ip="$(detect_local_ipv4)"
    [[ -n "$egress_ip" ]] && info "出网 IPv4（curl 探测）：${egress_ip}"
    [[ -n "$local_ip" ]]  && info "本机网卡 IPv4：${local_ip}（NAT 机器此为内网IP）"
    prompt public_ip "公网 IPv4（客户端连接本入口的地址）" "${egress_ip:-$local_ip}"
    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${wan_iface:-eth0}"

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
        "MIMIC_XDP_MODE=native" \
        "FW_OPEN_PORT=true"

    local client_port=30000 rid note tport lhost lport rproto
    while IFS=$'\t' read -r rid note tport lhost lport rproto; do
        [[ -n "$rid" ]] || continue
        # 默认与落地端口一致（客户端用同一端口号），回车即可；可手动改
        prompt_port client_port "规则 ${rid}（${note:-}）客户端入口端口" "${lport:-$client_port}"
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
    if mimic_needs_reboot; then
        offer_reboot "start ${ingress_id}"
    fi
}

regenerate_code_if_transit() {
    [[ "${ROLE:-}" == "nat-transit" ]] || return 0
    local code; code="$(generate_code)"
    printf '%s\n' "$code" >"${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    info "接入码已更新（公网入口需重新 import-code）"
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
            if [[ "${ROLE:-}" == "nat-ingress" ]]; then
                printf '  %s [%s] %s  入口:%s → IX:%s → %s:%s (%s)\n' \
                    "$RULE_ID" "${RULE_ENABLED:-true}" "${RULE_NOTE:-}" \
                    "${CLIENT_PORT:-?}" "$TRANSIT_PORT" "$LANDING_HOST" "$LANDING_PORT" "${FORWARD_PROTO:-both}"
            else
                printf '  %s [%s] %s  IX:%s → %s:%s (%s)\n' \
                    "$RULE_ID" "${RULE_ENABLED:-true}" "${RULE_NOTE:-}" \
                    "$TRANSIT_PORT" "$LANDING_HOST" "$LANDING_PORT" "${FORWARD_PROTO:-both}"
            fi
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
        tp_default="$(pool_alloc_port "$PROFILE_ID" "$TRANSIT_PORT_POOL")" \
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
    lsmod 2>/dev/null | grep -q '^mimic ' && ok "mimic kernel module" || warn "mimic 内核模块未加载"
    if kernel_ge_61; then ok "kernel >= 6.1 ($(uname -r))"; else warn "kernel < 6.1 ($(uname -r))"; fi
    [[ -f /sys/kernel/btf/vmlinux ]] && ok "BTF vmlinux" || warn "无 BTF（精简内核可能需 kprobe 编 mimic）"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok "ip_forward" || warn "ip_forward 未开启"
    if [[ -n "${WAN_IFACE:-}" && -f "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf" ]]; then
        mimic run --check -F "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf" "$WAN_IFACE" 2>&1 | sed 's/^/  /' || warn "mimic --check 失败"
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

refresh_code() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "nat-transit" ]] || die "仅 IX(nat-transit) 线路可 refresh-code"
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
    generate_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    ok "已刷新接入码与入口密钥（公网入口需重新 import-code）"
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
    mapfile -t urls < <(python3 - "$MIMIC_UPSTREAM_TAG" "$codename" <<'PY'
import json, sys, urllib.request
tag, codename = sys.argv[1], sys.argv[2]
api = f"https://api.github.com/repos/hack3ric/mimic/releases/tags/{tag}"
with urllib.request.urlopen(api, timeout=60) as r:
    data = json.load(r)
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
    curl -fsSL -o "$tmpd/mimic.deb" "$mimic_deb" || { rm -rf "$tmpd"; return 1; }
    curl -fsSL -o "$tmpd/mimic-dkms.deb" "$dkms_deb" || { rm -rf "$tmpd"; return 1; }
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
    if command_exists git; then
        git clone --depth 1 --branch "$tag" https://github.com/hack3ric/mimic.git "$dir" 2>/dev/null \
            || curl -fsSL "https://github.com/hack3ric/mimic/archive/refs/tags/${tag}.tar.gz" \
                | tar xz -C "$dir" --strip-components=1
    else
        curl -fsSL "https://github.com/hack3ric/mimic/archive/refs/tags/${tag}.tar.gz" \
            | tar xz -C "$dir" --strip-components=1
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
    rm -f "$WM_BIN" "$SYSTEMD_MIMIC_TEMPLATE" "$SYSTEMD_TUNNEL_TEMPLATE" "$SYSTEMD_DDNS_SERVICE" "$SYSTEMD_DDNS_TIMER" "$SYSTEMD_RESUME_SERVICE"
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
  wm start|stop|restart [ID]      启停线路（两端均需 WG+Mimic）
  wm list-profiles
  wm show-config [ID]
  wm show-code [ID]               显示 IX 接入码
  wm refresh-code [ID]            轮换入口密钥并刷新接入码
  wm show-port-map [ID]           端口地图
  wm list-rules [ID]
  wm add-rule [ID]
  wm edit-rule <ID> <规则ID>
  wm delete-rule <ID> <规则ID>
  wm enable-rule|disable-rule <ID> <规则ID>
  wm apply-rules [ID]             重建 nft 规则
  wm set-pool <ID> [端口池]        IX 中转端口池(如 40000-40010,40050；留空=清除，规则自动分配)
  wm health [ID] / wm diagnose [ID] / wm health-all
  wm ddns-enable|ddns-disable|ddns-status|ddns-refresh   域名 IP 变化自动刷新(每3分钟)
  wm set-group <ID> <组名> [primary|backup|standalone] [优先级]
  wm list-groups / switch-line <组名> <目标ID> / primary-backup-check <组名>
  wm set-mtu <ID> <MTU> / wm set-xdp-mode <ID> [skb|native]
  wm install-all|install-mimic|install-deps|compat
  wm upgrade-script / wm uninstall / wm purge

架构: 客户端 → 公网入口:client_port → WG(Mimic 伪TCP) → IX 虚拟IP:transit_port → 落地

环境变量:
  WMF_TAG=v0.6.0                  安装/升级时指定版本
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
║ 11) 升级脚本                         ║
║ 12) 卸载 / 完全清理                  ║
║  0) 退出                             ║
╚══════════════════════════════════════╝
MENU
        local choice id rid
        read -r -p "选择: " choice </dev/tty
        case "$(trim "$choice")" in
            1) create_transit_interactive ;;
            2) import_code_interactive ;;
            3) read -r -p "线路 ID: " id </dev/tty; start_profile "$(sanitize_id "$(trim "$id")")" ;;
            4) read -r -p "线路 ID: " id </dev/tty; stop_profile "$(sanitize_id "$(trim "$id")")" ;;
            5) read -r -p "线路 ID（回车=唯一）: " id </dev/tty; health_profile "$(trim "$id")" ;;
            6) list_profile_ids | sed 's/^/  /' || printf '  (无线路)\n' ;;
            7) read -r -p "IX 线路 ID: " id </dev/tty; show_code "$(sanitize_id "$(trim "$id")")" ;;
            8) read -r -p "IX 线路 ID: " id </dev/tty; refresh_code "$(sanitize_id "$(trim "$id")")" ;;
            9) read -r -p "线路 ID（回车=唯一）: " id </dev/tty; show_port_map "$(trim "$id")" ;;
            10)
                read -r -p "线路 ID（回车=唯一）: " id </dev/tty; id="$(trim "$id")"
                list_rules "$id"
                read -r -p "操作 add/del/pool/skip: " rid </dev/tty
                case "$(trim "$rid")" in
                    add) add_rule "$id" ;;
                    del) read -r -p "规则 ID: " rid </dev/tty; delete_rule "$id" "$(trim "$rid")" ;;
                    pool) read -r -p "端口池(如 40000-40010；留空=清除): " rid </dev/tty; set_transit_pool "$id" "$(trim "$rid")" ;;
                esac
                ;;
            11) upgrade_script ;;
            12) uninstall_from_menu ;;
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
        install-all) install_all ;;
        install-deps) install_deps ;;
        compat) compat_os_report ;;
        resume) resume_after_boot ;;
        create-transit) create_transit_interactive ;;
        import-code) import_code_interactive ;;
        start) start_profile "$(resolve_profile_id "${2:-}")" ;;
        stop) stop_profile "$(resolve_profile_id "${2:-}")" ;;
        restart) restart_profile "${2:-}" ;;
        list-profiles) list_profile_ids ;;
        show-config) load_profile "$(resolve_profile_id "${2:-}")"; cat "$(profile_env_path "$PROFILE_ID")" ;;
        show-code) show_code "${2:-}" ;;
        refresh-code) refresh_code "${2:-}" ;;
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
        set-pool) set_transit_pool "${2:-}" "${3:-}" ;;
        set-mtu) set_profile_mtu "${2:-}" "${3:-}" ;;
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
