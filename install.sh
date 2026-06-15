#!/usr/bin/env bash
# wg-mimic-fabric — WireGuard + Mimic tunnel orchestrator (MVP)
set -Eeuo pipefail

SCRIPT_VERSION="0.3.4"
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
    if [[ -f "$SYSCTL_FILE" ]]; then
        grep -q 'net.ipv4.ip_forward' "$SYSCTL_FILE" 2>/dev/null || \
            echo 'net.ipv4.ip_forward=1' >>"$SYSCTL_FILE"
    else
        printf 'net.ipv4.ip_forward=1\n' >"$SYSCTL_FILE"
    fi
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

json_encode_pairing() {
    python3 - "$@" <<'PY'
import base64, json, sys
from datetime import datetime, timezone
args = sys.argv[1:]
(
    profile_id, server_pubkey, server_endpoint, wg_port, wg_mtu, ip_version,
    wg_ipv4_subnet, server_ipv4, client_ipv4,
    wg_ipv6_subnet, server_ipv6, client_ipv6,
    client_pubkey, client_privkey, mimic_keepalive, wan_iface,
) = args[:16]
obj = {
    "version": 1,
    "code_schema": 2,
    "project": "wg-mimic-fabric",
    "role": "server",
    "profile_id": profile_id,
    "server_pubkey": server_pubkey,
    "server_endpoint": server_endpoint,
    "wg_port": int(wg_port),
    "wg_mtu": int(wg_mtu),
    "ip_version": ip_version,
    "wg_ipv4_subnet": wg_ipv4_subnet,
    "server_ipv4": server_ipv4,
    "client_ipv4": client_ipv4,
    "client_pubkey": client_pubkey,
    "client_privkey_b64": base64.urlsafe_b64encode(client_privkey.encode()).decode().rstrip("="),
    "mimic_keepalive": mimic_keepalive,
    "wan_iface_hint": wan_iface,
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
if wg_ipv6_subnet:
    obj["wg_ipv6_subnet"] = wg_ipv6_subnet
    obj["server_ipv6"] = server_ipv6
    obj["client_ipv6"] = client_ipv6
print(json.dumps(obj, separators=(",", ":")))
PY
}

base64url_encode() {
    python3 -c 'import base64,sys; d=sys.stdin.buffer.read(); print(base64.urlsafe_b64encode(d).decode().rstrip("="))'
}

base64url_decode() {
    python3 -c 'import base64,sys; s=sys.stdin.read().strip(); s+="="*(-len(s)%4); sys.stdout.buffer.write(base64.urlsafe_b64decode(s))'
}

generate_pairing_code() {
    local json b64 client_priv
    client_priv="$(cat "${KEYS_DIR}/${PROFILE_ID}/client.key" 2>/dev/null || true)"
    [[ -n "$client_priv" ]] || client_priv="$(wg_genkey)"
    json="$(json_encode_pairing \
        "$PROFILE_ID" "$WG_PUBLIC_KEY" "${PUBLIC_IP}:${WG_PORT}" \
        "$WG_PORT" "$WG_MTU" "${IP_VERSION:-4}" \
        "$WG_IPV4_SUBNET" "$WG_SERVER_IPV4" "$WG_CLIENT_IPV4" \
        "${WG_IPV6_SUBNET:-}" "${WG_SERVER_IPV6:-}" "${WG_CLIENT_IPV6:-}" \
        "$WG_PEER_PUBLIC_KEY" "$client_priv" \
        "$MIMIC_KEEPALIVE" "$WAN_IFACE")"
    b64="$(printf '%s' "$json" | base64url_encode)"
    printf 'WMGF1:%s' "$b64"
}

parse_pairing_code() {
    local code="${1#WMGF1:}"
    [[ "$1" == WMGF1:* ]] || die "配对码必须以 WMGF1: 开头"
    printf '%s' "$code" | base64url_decode
}

json_get() {
    local json="$1" key="$2"
    python3 -c 'import json,sys; o=json.load(sys.stdin); print(o.get(sys.argv[1],""))' "$key" <<<"$json"
}

# ── WireGuard keys ─────────────────────────────────────────────────────────

wg_genkey() { wg genkey; }
wg_pubkey() { wg pubkey; }

ensure_wg_tools() {
    command_exists wg || die "未找到 wg，请安装：apt install wireguard-tools"
}

ensure_mimic() {
    command_exists mimic || die "未找到 mimic，请安装：apt install mimic mimic-dkms"
    modprobe mimic 2>/dev/null || warn "mimic 内核模块未加载，请安装 mimic-dkms"
}

detect_default_iface() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

suggest_wg_mtu() {
    local mode="${1:-4}"
    case "$mode" in
        6|dual) printf '1408' ;;
        *) printf '1420' ;;
    esac
}

print_mtu_guide() {
    local mode="${1:-4}" suggested
    suggested="$(suggest_wg_mtu "$mode")"
    cat <<EOF

── MTU 说明（Mimic 核心参数）──
  Mimic 每包额外占用 12 字节，WG 接口 MTU 必须减去 12。

  推荐值：
    IPv4 单栈     → 1420（最大可试 1428）
    IPv6 / dual   → 1408（从默认 1420 减 12）

  若还有 PPPoE/VPN 等封装，在现有 MTU 基础上再减 12。
  当前 IP 模式「${mode}」建议：${suggested}

EOF
}

validate_mtu() {
    local mtu="$1"
    [[ "$mtu" =~ ^[0-9]+$ ]] || die "MTU 必须是数字"
    (( mtu >= 1280 && mtu <= 1500 )) || die "MTU 应在 1280–1500 之间（当前 ${mtu}）"
}

prompt_mtu() {
    local var="$1" mode="${2:-4}" default
    default="$(suggest_wg_mtu "$mode")"
    print_mtu_guide "$mode"
    prompt "$var" "WG 隧道接口 MTU" "$default"
    validate_mtu "${!var}"
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

# ── render configs ─────────────────────────────────────────────────────────

render_mimic_conf_for_profile() {
    local role="${ROLE:-}" pub_ip="${PUBLIC_IP:-}" port="${WG_PORT:-}" endpoint="${SERVER_ENDPOINT:-}"
    if [[ "$role" == "server" ]]; then
        printf 'filter = %s=%s:%s\n' "local" "$(format_mimic_ip "$pub_ip")" "$port"
    elif [[ "$role" == "forwarder" ]]; then
        printf 'filter = %s=%s:%s\n' "remote" "$(format_mimic_ip "${SERVER_PUBLIC_IP:-}")" "${SERVER_WG_PORT:-$port}"
    else
        local rip="${endpoint%:*}"
        printf 'filter = %s=%s:%s\n' "remote" "$(format_mimic_ip "$rip")" "$port"
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

render_wg_server_conf() {
    cat <<EOF
# Generated by wg-mimic-fabric — server ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_SERVER_IPV4}
${WG_SERVER_IPV6:+Address = ${WG_SERVER_IPV6}}
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY:-REPLACE_CLIENT_PUBKEY}
AllowedIPs = ${WG_CLIENT_IPV4}${WG_CLIENT_IPV6:+, ${WG_CLIENT_IPV6}}
PersistentKeepalive = 25
EOF
}

render_wg_client_conf() {
    local allowed="${WG_IPV4_SUBNET}"
    [[ -n "${WG_IPV6_SUBNET:-}" ]] && allowed="${allowed}, ${WG_IPV6_SUBNET}"
    cat <<EOF
# Generated by wg-mimic-fabric — client ${PROFILE_ID}
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_CLIENT_IPV4}
${WG_CLIENT_IPV6:+Address = ${WG_CLIENT_IPV6}}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = ${allowed}
PersistentKeepalive = 25
EOF
}

apply_profile_configs() {
    [[ -n "${WAN_IFACE:-}" ]] || die "配置缺少 WAN_IFACE（Mimic 绑定网卡）"
    apply_mimic_conf_iface "$WAN_IFACE"
    [[ "${ROLE:-}" == "forwarder" ]] && return 0

    local wg_iface; wg_iface="$(wg_iface_for "$PROFILE_ID")"
    local wg_path="${WG_CONF_DIR}/${wg_iface}.conf"
    backup_file "$wg_path"
    if [[ "${ROLE:-}" == "server" ]]; then
        render_wg_server_conf >"$wg_path"
    else
        render_wg_client_conf >"$wg_path"
    fi
    chmod 600 "$wg_path"
}

collect_nft_input_ports() {
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${FW_OPEN_PORT:-true}" == "true" ]] || exit 0
            if [[ "${ROLE:-}" == "server" ]]; then
                printf '%s %s-server\n' "$WG_PORT" "$PROFILE_ID"
            elif [[ "${ROLE:-}" == "forwarder" ]]; then
                printf '%s %s-fwd\n' "$FORWARDER_LISTEN_PORT" "$PROFILE_ID"
            fi
        )
    done | sort -u -k1,1
}

collect_forwarder_nat_rules() {
    local p
    for p in "$PROFILES_DIR"/*.env; do
        [[ -f "$p" ]] || continue
        (
            # shellcheck disable=SC1090
            source "$p"
            [[ "${ROLE:-}" == "forwarder" ]] || exit 0
            printf '%s %s %s %s\n' "$FORWARDER_LISTEN_PORT" "$SERVER_PUBLIC_IP" "$SERVER_WG_PORT" "$PROFILE_ID"
        )
    done
}

render_nft_all() {
    local ports rules line listen sip sport pid
    ports="$(collect_nft_input_ports)"
    rules="$(collect_forwarder_nat_rules)"
    {
        printf 'table inet %s {\n' "$NFT_TABLE"
        if [[ -n "$rules" ]]; then
            printf '    chain prerouting {\n'
            printf '        type nat hook prerouting priority dstnat; policy accept;\n'
            while read -r listen sip sport pid; do
                [[ -n "$listen" ]] || continue
                printf '        udp dport %s counter dnat to %s:%s comment "wm-fwd-%s"\n' "$listen" "$sip" "$sport" "$pid"
            done <<<"$rules"
            printf '    }\n'
            printf '    chain postrouting {\n'
            printf '        type nat hook postrouting priority srcnat; policy accept;\n'
            while read -r listen sip sport pid; do
                [[ -n "$sip" ]] || continue
                printf '        ip daddr %s udp dport %s counter masquerade comment "wm-fwd-%s"\n' "$sip" "$sport" "$pid"
            done <<<"$rules"
            printf '    }\n'
            printf '    chain forward {\n'
            printf '        type filter hook forward priority filter; policy accept;\n'
            while read -r listen sip sport pid; do
                [[ -n "$sip" ]] || continue
                printf '        ip daddr %s udp dport %s accept comment "wm-fwd-%s"\n' "$sip" "$sport" "$pid"
                printf '        ip saddr %s udp sport %s accept comment "wm-fwd-%s-r"\n' "$sip" "$sport" "$pid"
            done <<<"$rules"
            printf '    }\n'
        fi
        printf '    chain input {\n'
        printf '        type filter hook input priority filter; policy accept;\n'
        if [[ -n "$ports" ]]; then
            while read -r port tag; do
                [[ -n "$port" ]] || continue
                printf '        tcp dport %s counter accept comment "wm-%s-tcp"\n' "$port" "$tag"
                printf '        udp dport %s counter accept comment "wm-%s-udp"\n' "$port" "$tag"
            done <<<"$ports"
        fi
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

apply_nft_profile() {
    apply_nft_all
}

# ── systemd ────────────────────────────────────────────────────────────────

install_systemd_units() {
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=wg-mimic-fabric Mimic on %%i for profile %i
After=network-online.target
Wants=network-online.target
Before=wg-mimic-tunnel@%i.service

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
After=wg-mimic-mimic@%i.service network-online.target
Requires=wg-mimic-mimic@%i.service
Wants=network-online.target

[Service]
Type=onshot
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

# Note: mimic systemd uses iface name as %i, tunnel uses profile id as %i
# We need aligned naming — use WAN_IFACE for mimic@ and profile for tunnel@

start_profile() {
    load_profile "$1"
    apply_profile_configs
    apply_nft_all
    [[ "${ROLE:-}" == "forwarder" ]] && ensure_ip_forward
    systemctl enable --now "wg-mimic-mimic@${WAN_IFACE}.service"
    if [[ "${ROLE:-}" != "forwarder" ]]; then
        systemctl enable --now "wg-mimic-tunnel@${PROFILE_ID}.service"
    fi
    ok "已启动线路：${PROFILE_ID} (${ROLE:-})"
}

stop_profile() {
    load_profile "$1"
    if [[ "${ROLE:-}" != "forwarder" ]]; then
        systemctl stop "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null || true
    fi
    systemctl stop "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null || true
    ok "已停止线路：${PROFILE_ID}"
}

# ── create server / import code ────────────────────────────────────────────

prompt() {
    local var="$1" prompt_text="$2" default="${3:-}"
    local val
    if [[ -n "$default" ]]; then
        read -r -p "${prompt_text} [${default}]: " val </dev/tty
        val="${val:-$default}"
    else
        read -r -p "${prompt_text}: " val </dev/tty
    fi
    printf -v "$var" '%s' "$(trim "$val")"
}

create_server_interactive() {
    require_root
    ensure_wg_tools
    ensure_dirs

    local profile_id public_ip wan_iface wg_port wg_mtu ip_version
    prompt profile_id "线路 ID（字母数字）" "my-tunnel"
    profile_id="$(sanitize_id "$profile_id")"
    [[ ! -f "$(profile_env_path "$profile_id")" ]] || die "线路已存在：$profile_id"

    prompt public_ip "服务端公网 IP（IPv4 或 IPv6）"
    [[ -n "$public_ip" ]] || die "公网 IP 不能为空"

    prompt ip_version "IP 版本 (4/6/dual)" "4"
    case "$ip_version" in 4|6|dual) ;; *) die "IP 版本必须是 4、6 或 dual" ;; esac

    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${wan_iface:-eth0}"

    prompt wg_port "WireGuard UDP 端口" "51820"
    prompt_mtu wg_mtu "$ip_version"

    local priv pub client_priv client_pub
    priv="$(wg_genkey)"
    pub="$(printf '%s' "$priv" | wg_pubkey)"
    client_priv="$(wg_genkey)"
    client_pub="$(printf '%s' "$client_priv" | wg_pubkey)"

    install -d -m 700 "${KEYS_DIR}/${profile_id}"
    printf '%s' "$priv" >"${KEYS_DIR}/${profile_id}/server.key"
    printf '%s' "$client_priv" >"${KEYS_DIR}/${profile_id}/client.key"
    chmod 600 "${KEYS_DIR}/${profile_id}"/*.key

    local kv=(
        "PROFILE_ID=${profile_id}"
        "PROFILE_NAME=${profile_id}"
        "ROLE=server"
        "ENABLED=true"
        "IP_VERSION=${ip_version}"
        "WAN_IFACE=${wan_iface}"
        "PUBLIC_IP=${public_ip}"
        "WG_PORT=${wg_port}"
        "WG_MTU=${wg_mtu}"
        "WG_IPV4_SUBNET=10.66.66.0/24"
        "WG_SERVER_IPV4=10.66.66.1/32"
        "WG_CLIENT_IPV4=10.66.66.2/32"
        "WG_PRIVATE_KEY=${priv}"
        "WG_PUBLIC_KEY=${pub}"
        "WG_PEER_PUBLIC_KEY=${client_pub}"
        "MIMIC_KEEPALIVE=300:::"
        "MIMIC_XDP_MODE="
        "FW_OPEN_PORT=true"
    )
    if [[ "$ip_version" == "6" || "$ip_version" == "dual" ]]; then
        kv+=(
            "WG_IPV6_SUBNET=fd42:4242:4242::/64"
            "WG_SERVER_IPV6=fd42:4242:4242::1/128"
            "WG_CLIENT_IPV6=fd42:4242:4242::2/128"
        )
    fi
    write_profile_kv "$(profile_env_path "$profile_id")" "${kv[@]}"

    load_profile "$profile_id"
    apply_profile_configs
    apply_nft_all

    local code; code="$(generate_pairing_code)"
    printf '%s\n' "$code" >"${CODES_DIR}/${profile_id}.code"
    chmod 600 "${CODES_DIR}/${profile_id}.code"

    printf '\n═══ 配对码（WMGF1，含预生成客户端密钥）═══\n'
    printf '%s\n' "$code"
    printf '════════════════════════════════════════════\n'
    printf '\n下一步：wm start %s\n' "$profile_id"
}

create_forwarder_interactive() {
    require_root
    ensure_dirs
    command_exists mimic || die "需要 mimic，请先 wm install-deps"

    local profile_id wan_iface listen_port server_ip server_port
    prompt profile_id "Forwarder 线路 ID" "my-forwarder"
    profile_id="$(sanitize_id "$profile_id")"
    [[ ! -f "$(profile_env_path "$profile_id")" ]] || die "线路已存在：$profile_id"

    wan_iface="$(detect_default_iface)"
    prompt wan_iface "Mimic 绑定网卡" "${wan_iface:-eth0}"
    prompt listen_port "本机 UDP 监听端口（客户端 WG Endpoint 指向此端口）" "1234"
    prompt server_ip "远端 WG 服务端公网 IP"
    [[ -n "$server_ip" ]] || die "服务端 IP 不能为空"
    prompt server_port "远端 WG 服务端端口" "51820"

    write_profile_kv "$(profile_env_path "$profile_id")" \
        "PROFILE_ID=${profile_id}" \
        "PROFILE_NAME=${profile_id}" \
        "ROLE=forwarder" \
        "ENABLED=true" \
        "WAN_IFACE=${wan_iface}" \
        "FORWARDER_LISTEN_PORT=${listen_port}" \
        "SERVER_PUBLIC_IP=${server_ip}" \
        "SERVER_WG_PORT=${server_port}" \
        "MIMIC_KEEPALIVE=300:::" \
        "MIMIC_XDP_MODE=native" \
        "FW_OPEN_PORT=true"

    load_profile "$profile_id"
    apply_profile_configs
    apply_nft_all
    ensure_ip_forward

    printf '\n═══ Forwarder 部署说明 ═══\n'
    printf '1. 客户端（RouterOS 等）WG Endpoint → 本机公网 IP:%s\n' "$listen_port"
    printf '2. 服务端 mimic filter → local=%s:%s\n' "$server_ip" "$server_port"
    printf '3. 本机执行：wm start %s\n' "$profile_id"
    printf '4. Intel 网卡丢包可改 MIMIC_XDP_MODE=skb\n'
    printf '详见 docs/forwarder.md\n'
}

import_code_interactive() {
    require_root
    ensure_wg_tools
    ensure_dirs

    local code json
    printf '请粘贴 WMGF1: 配对码：' >&2
    read -r code </dev/tty
    code="$(trim "$code")"
    json="$(parse_pairing_code "$code")"

    local schema; schema="$(json_get "$json" code_schema)"
    [[ "$schema" == "1" || "$schema" == "2" ]] || die "不支持的 code_schema：$schema"

    local profile_id server_pub endpoint wg_port wg_mtu subnet client_ip server_ip keepalive wan_hint client_priv_b64
    local ip_version subnet6 client_ip6 server_ip6
    profile_id="$(json_get "$json" profile_id)"
    profile_id="$(sanitize_id "$profile_id")-client"
    server_pub="$(json_get "$json" server_pubkey)"
    endpoint="$(json_get "$json" server_endpoint)"
    wg_port="$(json_get "$json" wg_port)"
    wg_mtu="$(json_get "$json" wg_mtu)"
    ip_version="$(json_get "$json" ip_version)"
    [[ -n "$ip_version" ]] || ip_version="4"
    print_mtu_guide "$ip_version"
    prompt wg_mtu "WG 隧道 MTU（配对码建议 ${wg_mtu}，可改）" "${wg_mtu:-$(suggest_wg_mtu "$ip_version")}"
    validate_mtu "$wg_mtu"
    subnet="$(json_get "$json" wg_ipv4_subnet)"
    client_ip="$(json_get "$json" client_ipv4)"
    server_ip="$(json_get "$json" server_ipv4)"
    subnet6="$(json_get "$json" wg_ipv6_subnet)"
    client_ip6="$(json_get "$json" client_ipv6)"
    server_ip6="$(json_get "$json" server_ipv6)"
    keepalive="$(json_get "$json" mimic_keepalive)"
    wan_hint="$(json_get "$json" wan_iface_hint)"
    client_priv_b64="$(json_get "$json" client_privkey_b64)"

    [[ ! -f "$(profile_env_path "$profile_id")" ]] || die "线路已存在：$profile_id"

    local priv pub
    if [[ -n "$client_priv_b64" ]]; then
        priv="$(printf '%s' "$client_priv_b64" | base64url_decode)"
    else
        priv="$(wg_genkey)"
        warn "配对码未含客户端私钥，已本地生成新密钥；请在服务端执行 wm set-peer"
    fi
    pub="$(printf '%s' "$priv" | wg_pubkey)"

    local wan_iface
    wan_iface="$(detect_default_iface)"
    wan_iface="${wan_iface:-$wan_hint}"
    wan_iface="${wan_iface:-eth0}"

    install -d -m 700 "${KEYS_DIR}/${profile_id}"
    printf '%s' "$priv" >"${KEYS_DIR}/${profile_id}/client.key"
    chmod 600 "${KEYS_DIR}/${profile_id}/client.key"

    local kv=(
        "PROFILE_ID=${profile_id}"
        "PROFILE_NAME=${profile_id}"
        "ROLE=client"
        "ENABLED=true"
        "IP_VERSION=${ip_version}"
        "WAN_IFACE=${wan_iface}"
        "SERVER_ENDPOINT=${endpoint}"
        "WG_PORT=${wg_port}"
        "WG_MTU=${wg_mtu}"
        "WG_IPV4_SUBNET=${subnet}"
        "WG_CLIENT_IPV4=${client_ip}"
        "WG_SERVER_IPV4=${server_ip}"
        "WG_PRIVATE_KEY=${priv}"
        "WG_PUBLIC_KEY=${pub}"
        "WG_PEER_PUBLIC_KEY=${server_pub}"
        "MIMIC_KEEPALIVE=${keepalive:-300:::}"
        "MIMIC_XDP_MODE="
        "FW_OPEN_PORT=false"
    )
    [[ -n "$subnet6" ]] && kv+=(
        "WG_IPV6_SUBNET=${subnet6}"
        "WG_CLIENT_IPV6=${client_ip6}"
        "WG_SERVER_IPV6=${server_ip6}"
    )
    write_profile_kv "$(profile_env_path "$profile_id")" "${kv[@]}"

    load_profile "$profile_id"
    apply_profile_configs

    ok "已导入客户端线路：${profile_id}"
    if [[ -z "$client_priv_b64" ]]; then
        warn "请将客户端公钥告知服务端："
        printf '  公钥: %s\n' "$pub"
        printf '  服务端: wm set-peer <server-id> %s\n' "$pub"
    fi
    printf '\n下一步：wm start %s\n' "$profile_id"
}

set_server_peer() {
    local profile_id="$1" peer_pub="$2"
    require_root
    load_profile "$profile_id"
    [[ "${ROLE:-}" == "server" ]] || die "仅服务端线路可 set-peer"
    WG_PEER_PUBLIC_KEY="$peer_pub"
    sed -i "s/^WG_PEER_PUBLIC_KEY=.*/WG_PEER_PUBLIC_KEY=${peer_pub}/" "$(profile_env_path "$profile_id")"
    apply_profile_configs
    local wg_iface; wg_iface="$(wg_iface_for "$PROFILE_ID")"
    if systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
        local allowed="${WG_CLIENT_IPV4}"
        [[ -n "${WG_CLIENT_IPV6:-}" ]] && allowed="${allowed}, ${WG_CLIENT_IPV6}"
        wg set "$wg_iface" peer "$peer_pub" allowed-ips "$allowed" 2>/dev/null || true
    fi
    ok "已更新服务端 peer 公钥"
}

# ── health / diagnose ──────────────────────────────────────────────────────

health_profile() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    local status="healthy" wg_iface; wg_iface="$(wg_iface_for "$PROFILE_ID")"

    printf '线路: %s (%s)\n' "$PROFILE_ID" "${ROLE:-unknown}"
    if [[ "${ROLE:-}" == "forwarder" ]]; then
        printf '监听: UDP %s → %s:%s\n' "${FORWARDER_LISTEN_PORT:-?}" "${SERVER_PUBLIC_IP:-?}" "${SERVER_WG_PORT:-?}"
    else
        printf 'IP=%s  网卡: %s  端口: %s  MTU: %s\n' "${IP_VERSION:-4}" "$WAN_IFACE" "${WG_PORT:-?}" "${WG_MTU:-?}"
        [[ -n "${WG_SERVER_IPV6:-}${WG_CLIENT_IPV6:-}" ]] && printf 'IPv6: %s\n' "${WG_SERVER_IPV6:-${WG_CLIENT_IPV6}}"
    fi

    if command_exists mimic; then
        if systemctl is-active --quiet "wg-mimic-mimic@${WAN_IFACE}.service" 2>/dev/null; then
            printf 'Mimic: active (%s)\n' "$WAN_IFACE"
        else
            printf 'Mimic: inactive\n'; status="degraded"
        fi
    else
        printf 'Mimic: not installed\n'; status="degraded"
    fi

    if [[ "${ROLE:-}" == "forwarder" ]]; then
        [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && printf 'IP forward: on\n' || { printf 'IP forward: off\n'; status="degraded"; }
        printf 'WireGuard: N/A (forwarder 模式)\n'
    elif systemctl is-active --quiet "wg-mimic-tunnel@${PROFILE_ID}.service" 2>/dev/null; then
        printf 'WireGuard: active (%s)\n' "$wg_iface"
        wg show "$wg_iface" 2>/dev/null | sed 's/^/  /' || true
    else
        printf 'WireGuard: inactive\n'; status="degraded"
    fi

    printf 'HEALTH_STATUS=%s\n' "$status"
}

diagnose_profile() {
    local id; id="$(resolve_profile_id "${1:-}")"
    load_profile "$id"
    printf '=== OS compatibility ===\n'
    compat_os_report | while IFS= read -r line; do printf '  %s\n' "$line"; done
    printf '=== preflight ===\n'
    if [[ "${ROLE:-}" != "forwarder" ]]; then
        command_exists wg && ok "wireguard-tools" || warn "缺少 wireguard-tools"
    fi
    command_exists mimic && ok "mimic CLI" || warn "缺少 mimic"
    lsmod 2>/dev/null | grep -q '^mimic ' && ok "mimic kernel module" || warn "mimic 内核模块未加载"
    if kernel_ge_61; then
        ok "kernel >= 6.1 ($(uname -r))"
    else
        warn "kernel < 6.1 ($(uname -r))"
    fi
    [[ -f /sys/kernel/btf/vmlinux ]] && ok "BTF vmlinux" || warn "无 BTF（OpenWrt/精简内核可能需 kprobe 模式编 mimic）"
    mimic run --check -F "${MIMIC_CONF_DIR}/${WAN_IFACE}.conf" "$WAN_IFACE" 2>&1 | sed 's/^/  /' || warn "mimic --check 失败"
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
    [[ "${ROLE:-}" == "server" ]] || die "仅服务端可 show-code"
    if [[ -f "${CODES_DIR}/${PROFILE_ID}.code" ]]; then
        cat "${CODES_DIR}/${PROFILE_ID}.code"
    else
        generate_pairing_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
        chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    fi
}

refresh_code() {
    local id; id="$(resolve_profile_id "${1:-}")"
    require_root
    load_profile "$id"
    [[ "${ROLE:-}" == "server" ]] || die "仅服务端可 refresh-code"
    local client_priv client_pub
    client_priv="$(wg_genkey)"
    client_pub="$(printf '%s' "$client_priv" | wg_pubkey)"
    printf '%s' "$client_priv" >"${KEYS_DIR}/${PROFILE_ID}/client.key"
    chmod 600 "${KEYS_DIR}/${PROFILE_ID}/client.key"
    sed -i "s/^WG_PEER_PUBLIC_KEY=.*/WG_PEER_PUBLIC_KEY=${client_pub}/" "$(profile_env_path "$PROFILE_ID")"
    load_profile "$id"
    apply_profile_configs
    generate_pairing_code | tee "${CODES_DIR}/${PROFILE_ID}.code"
    chmod 600 "${CODES_DIR}/${PROFILE_ID}.code"
    ok "已刷新配对码（旧客户端需重新导入）"
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
    rm -f "$WM_BIN" "$SYSTEMD_MIMIC_TEMPLATE" "$SYSTEMD_TUNNEL_TEMPLATE"
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
wg-mimic-fabric ${SCRIPT_VERSION} — WireGuard + Mimic 隧道编排

用法:
  wm                              交互菜单
  wm --version
  wm install-wm-cli               安装 wm（默认同时 apt 装 mimic）
  wm install-mimic                安装 mimic + wireguard-tools 等依赖
  wm install-all                  安装 wm + mimic（等同 bootstrap）
  wm install-deps                 仅打印依赖指引（不安装）
  wm compat                       操作系统兼容性报告
  wm create-server                创建服务端线路
  wm create-forwarder             创建 Forwarder 旁路（RouterOS 等）
  wm import-code                  客户端导入配对码
  wm start|stop|restart <ID>      启停线路
  wm list-profiles
  wm show-config <ID>
  wm show-code <ID>               显示配对码
  wm refresh-code <ID>          刷新配对码（轮换客户端密钥）
  wm set-peer <ID> <PUBKEY>     服务端更新客户端公钥
  wm set-mtu <ID> <MTU>         修改 MTU
  wm set-xdp-mode <ID> [skb|native]  设置 Mimic XDP 模式
  wm apply-nft-all              重建 nft 防火墙规则
  wm upgrade-script             升级管理脚本
  wm uninstall                  卸载 CLI/服务（保留配置）
  wm purge                      完全清理（含本地脚本与 mimic 包）
  wm health [ID]
  wm diagnose [ID]

环境变量:
  WMF_TAG=v0.3.1                  安装/升级时指定版本
  WMF_REPO=ike-sh/wg-mimic-fabric   GitHub 仓库
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
║  1) 创建服务端隧道                   ║
║  2) 客户端导入配对码                 ║
║  3) 创建 Forwarder 旁路              ║
║  4) 启动线路                         ║
║  5) 停止线路                         ║
║  6) 健康检查                         ║
║  7) 列出线路                         ║
║  8) 显示配对码                       ║
║  9) 刷新配对码                       ║
║ 10) 依赖安装指引 (install-deps)      ║
║ 11) 系统兼容性 (compat)              ║
║ 12) 升级脚本                         ║
║ 13) 卸载 / 完全清理                  ║
║ 14) 安装 wm CLI                      ║
║  0) 退出                             ║
╚══════════════════════════════════════╝
MENU
        local choice id
        read -r -p "选择: " choice </dev/tty
        case "$(trim "$choice")" in
            1) create_server_interactive ;;
            2) import_code_interactive ;;
            3) create_forwarder_interactive ;;
            4) read -r -p "线路 ID: " id </dev/tty; start_profile "$(sanitize_id "$(trim "$id")")" ;;
            5) read -r -p "线路 ID: " id </dev/tty; stop_profile "$(sanitize_id "$(trim "$id")")" ;;
            6)
                if readarray -t _ids < <(list_profile_ids) && [[ "${#_ids[@]}" -eq 1 ]]; then
                    health_profile "${_ids[0]}"
                else
                    read -r -p "线路 ID（回车=唯一线路）: " id </dev/tty
                    id="$(trim "$id")"
                    health_profile "${id:-$(resolve_profile_id "")}"
                fi
                ;;
            7) list_profile_ids | sed 's/^/  /' || printf '  (无线路)\n' ;;
            8) read -r -p "服务端线路 ID: " id </dev/tty; show_code "$(sanitize_id "$(trim "$id")")" ;;
            9) read -r -p "服务端线路 ID: " id </dev/tty; refresh_code "$(sanitize_id "$(trim "$id")")" ;;
            10) install_deps ;;
            11) compat_os_report ;;
            12) upgrade_script ;;
            13) uninstall_from_menu ;;
            14) install_wm_cli ;;
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
        create-server) create_server_interactive ;;
        create-forwarder) create_forwarder_interactive ;;
        import-code) import_code_interactive ;;
        start) start_profile "$(resolve_profile_id "${2:-}")" ;;
        stop) stop_profile "$(resolve_profile_id "${2:-}")" ;;
        restart) stop_profile "$(resolve_profile_id "${2:-}")"; start_profile "$(resolve_profile_id "${2:-}")" ;;
        list-profiles) list_profile_ids ;;
        show-config) load_profile "$(resolve_profile_id "${2:-}")"; cat "$(profile_env_path "$PROFILE_ID")" ;;
        show-code) show_code "${2:-}" ;;
        refresh-code) refresh_code "${2:-}" ;;
        set-peer) set_server_peer "$(resolve_profile_id "${2:-}")" "${3:-}" ;;
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

main "$@"
