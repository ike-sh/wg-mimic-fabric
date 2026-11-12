#!/usr/bin/env bash
# shellcheck disable=SC2329
# Smoke tests for wg-mimic-fabric pure functions (no root / systemd / kernel).
# Exercises rule IO, access-code round-trip, wg.conf and nft rendering.
# Usage: bash scripts/smoke.sh [rule|code|wgconf|nft|all]
set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export WMF_SOURCED=1
# shellcheck disable=SC1091
source "$HERE/../install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONFIG_DIR="$TMP/etc"
PROFILES_DIR="$CONFIG_DIR/profiles"
CODES_DIR="$CONFIG_DIR/codes"
# shellcheck disable=SC2034
STATE_DIR="$CONFIG_DIR/state"
NFT_DIR="$TMP/nftables.d"
NFT_FILE="$NFT_DIR/wg-mimic-fabric.nft"
# shellcheck disable=SC2034
STATE_LOCK_FILE="$TMP/state.lock"
NFT_LOCK_FILE="$TMP/nft.lock"
install -d -m 700 "$PROFILES_DIR" "$CODES_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Python is a runtime dependency; minimal distro images may omit diffutils/cmp.
files_equal() {
    python3 - "$1" "$2" <<'PY'
import pathlib, sys
raise SystemExit(0 if pathlib.Path(sys.argv[1]).read_bytes() == pathlib.Path(sys.argv[2]).read_bytes() else 1)
PY
}

seed_transit() {
    write_profile_kv "$(profile_env_path ix-nat)" \
        "PROFILE_ID=ix-nat" "PROFILE_NAME=ix-nat" "ROLE=nat-transit" "ENABLED=true" \
        "WAN_IFACE=eth0" "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" \
        "WG_INGRESS_IP=10.88.0.1" "WG_PORT=51820" "WG_MTU=1420" \
        "IX_ENDPOINT_HOST=nat.example" "IX_PUBLIC_IP=203.0.113.9" \
        "WG_PRIVATE_KEY=PRIVKEYAAA" "WG_PUBLIC_KEY=IXPUBKEYAAA" \
        "WG_PEER_PUBLIC_KEY=INGPUBKEYAAA" "INGRESS_PRIVKEY_B64=aW5ncHJpdg" \
        "FORWARD_PROTO=both" "MIMIC_KEEPALIVE=300:::" "MIMIC_XDP_MODE=" "FW_OPEN_PORT=true"
    write_rule ix-nat rule-main "RULE_ID=rule-main" "RULE_NOTE=main" "RULE_ENABLED=true" \
        "TRANSIT_PORT=40000" "LANDING_HOST=1.2.3.4" "LANDING_PORT=50000" "FORWARD_PROTO=both"
    write_rule ix-nat rule-game "RULE_ID=rule-game" "RULE_NOTE=game" "RULE_ENABLED=true" \
        "TRANSIT_PORT=40001" "LANDING_HOST=5.6.7.8" "LANDING_PORT=50001" "FORWARD_PROTO=tcp"
}

test_rule() {
    seed_transit
    local ids; ids="$(list_rule_ids ix-nat | sort | tr '\n' ' ')"
    [[ "$ids" == "rule-game rule-main " ]] || fail "list_rule_ids: $ids"
    load_rule ix-nat rule-main
    [[ "$TRANSIT_PORT" == "40000" && "$LANDING_HOST" == "1.2.3.4" ]] || fail "load_rule fields"
    echo "RULE OK"
}

test_code() {
    seed_transit
    load_profile ix-nat
    local code
    code="$(generate_code)"
    [[ "$code" == WMGF1:* ]] || fail "code prefix"
    parse_code "$code"
    [[ "$CODE_IX_WG_IP" == "10.88.0.2" ]] || fail "ix_wg_ip=$CODE_IX_WG_IP"
    [[ "$CODE_INGRESS_WG_IP" == "10.88.0.1" ]] || fail "ingress_wg_ip"
    [[ "$CODE_WG_PORT" == "51820" ]] || fail "wg_port=$CODE_WG_PORT"
    [[ "$CODE_WG_MTU" == "1420" ]] || fail "wg_mtu=$CODE_WG_MTU"
    [[ "$CODE_IX_WG_PUBKEY" == "IXPUBKEYAAA" ]] || fail "ix_pub"
    [[ "$CODE_INGRESS_PRIVKEY_B64" == "aW5ncHJpdg" ]] || fail "ingress_priv_b64"
    [[ "$CODE_IX_ENDPOINT_HOST" == "nat.example" ]] || fail "endpoint"
    printf '%s\n' "$CODE_RULES_TSV" | grep -qP 'rule-main\tmain\t40000\t1.2.3.4\t50000\tboth' || fail "rules tsv main"
    printf '%s\n' "$CODE_RULES_TSV" | grep -q 'rule-game' || fail "rules tsv game"
    echo "CODE ROUNDTRIP OK"
}

test_wgconf() {
    seed_transit
    load_profile ix-nat
    local out; out="$(render_wg_conf)"
    grep -q 'Address = 10.88.0.2/32' <<<"$out" || fail "transit addr"
    grep -q 'ListenPort = 51820' <<<"$out" || fail "listenport"
    grep -q 'AllowedIPs = 10.88.0.1/32' <<<"$out" || fail "allowedips"
    echo "WGCONF OK"
}

test_nft() {
    seed_transit
    local out; out="$(render_nft_all)"
    grep -q 'ip daddr 10.88.0.2 tcp dport 40000 counter dnat to 1.2.3.4:50000' <<<"$out" || fail "dnat main tcp"
    grep -q 'ip daddr 10.88.0.2 udp dport 40000 counter dnat to 1.2.3.4:50000' <<<"$out" || fail "dnat main udp"
    grep -q 'tcp dport 40001 counter dnat to 5.6.7.8:50001' <<<"$out" || fail "dnat game tcp"
    grep -q 'tcp dport 51820 counter accept' <<<"$out" || fail "input wg port"
    echo "NFT OK"
}

seed_transit6() {
    write_profile_kv "$(profile_env_path ix6)" \
        "PROFILE_ID=ix6" "ROLE=nat-transit" "ENABLED=true" "WAN_IFACE=eth0" \
        "IP_VERSION=dual" "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_MESH_SUBNET6=fd88::/64" "WG_IX_IP6=fd88::2" "WG_INGRESS_IP6=fd88::1" \
        "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=nat.example" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=p" "WG_PEER_PUBLIC_KEY=q" "INGRESS_PRIVKEY_B64=x" \
        "FORWARD_PROTO=both" "FW_OPEN_PORT=true"
    write_rule ix6 r6 "RULE_ID=r6" "RULE_ENABLED=true" "TRANSIT_PORT=40010" \
        "LANDING_HOST=2606:4700:4700::1111" "LANDING_PORT=443" "FORWARD_PROTO=tcp"
}

test_ipv6() {
    seed_transit6
    load_profile ix6
    local wg; wg="$(render_wg_conf)"
    grep -q 'Address = fd88::2/128' <<<"$wg" || fail "wg ipv6 addr"
    grep -q 'AllowedIPs = 10.88.0.1/32, fd88::1/128' <<<"$wg" || fail "wg ipv6 allowed"
    local out; out="$(render_nft_all)"
    grep -q 'ip6 daddr fd88::2 tcp dport 40010' <<<"$out" || fail "ipv6 dnat match"
    grep -qF 'dnat to [2606:4700:4700::1111]:443' <<<"$out" || fail "ipv6 dnat target"
    echo "IPV6 OK"
}

test_group() {
    seed_transit
    set_or_append_kv "$(profile_env_path ix-nat)" LINE_GROUP grpA
    set_or_append_kv "$(profile_env_path ix-nat)" LINE_ROLE primary
    grep -q 'grpA' <<<"$(list_groups)" || fail "group listing"
    [[ "$(group_members grpA | tr -d '[:space:]')" == "ix-nat" ]] || fail "group members"
    echo "GROUP OK"
}

test_pool() {
    seed_transit   # rule-main=40000, rule-game=40001
    set_or_append_kv "$(profile_env_path ix-nat)" TRANSIT_PORT_POOL "40000-40002,40005"
    local exp; exp="$(expand_port_pool "40000-40002,40005" | tr '\n' ' ')"
    [[ "$exp" == "40000 40001 40002 40005 " ]] || fail "expand_port_pool: $exp"
    validate_port_pool "40000-40002" || fail "validate good pool"
    ! validate_port_pool "nope" || fail "validate bad pool accepted"
    # 40000 & 40001 used by seed → next free in pool = 40002
    local got; got="$(pool_alloc_port ix-nat "40000-40002,40005")"
    [[ "$got" == "40002" ]] || fail "pool_alloc next free: $got"
    # reserve 40002 (e.g. WG port) → next free skips it = 40005
    [[ "$(pool_alloc_port ix-nat "40000-40002,40005" 40002)" == "40005" ]] || fail "pool_alloc reserve"
    pool_contains "40000-40002,40005" 40005 || fail "pool_contains 40005"
    ! pool_contains "40000-40002,40005" 40009 || fail "pool_contains 40009 should be false"
    pool_contains "18301-18399" 18301 || fail "pool_contains first port of pure range"
    pool_contains "18301-18399" 18399 || fail "pool_contains last port of pure range"
    ! pool_contains "18301-18399" 18300 || fail "pool_contains below range"
    transit_port_in_use ix-nat 40000 || fail "40000 should be in use"
    ! transit_port_in_use ix-nat 40000 rule-main || fail "exclude self failed"
    ! transit_port_in_use ix-nat 49999 || fail "49999 should be free"
    ! pool_alloc_port ix-nat "40000-40001" || fail "exhausted pool should fail"
    [[ "$(pool_stats ix-nat "40000-40002,40005")" == "4 2 2" ]] || fail "pool_stats: $(pool_stats ix-nat "40000-40002,40005")"
    echo "POOL OK"
}

test_mimic() {
    seed_transit   # nat-transit, WG_PORT=51820, IX_ENDPOINT_HOST=nat.example
    load_profile ix-nat
    local out
    out="$(export MIMIC_LOCAL_IP=203.0.113.9; render_mimic_conf_for_profile)"
    grep -qxF 'filter = local=203.0.113.9:51820' <<<"$out" || fail "transit mimic filter: $out"
    write_profile_kv "$(profile_env_path ing)" \
        "PROFILE_ID=ing" "ROLE=nat-ingress" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_PORT=51820" "IX_ENDPOINT_HOST=203.0.113.5" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1"
    load_profile ing
    out="$(render_mimic_conf_for_profile)"
    grep -qxF 'filter = remote=203.0.113.5:51820' <<<"$out" || fail "ingress mimic filter: $out"
    echo "MIMIC OK"
}

test_iface() {
    [[ "$(wg_iface_for ix-nat)" == "wm-ix-nat" ]] || fail "short iface: $(wg_iface_for ix-nat)"
    local long; long="$(wg_iface_for ix-nat-ingress)"   # wm-ix-nat-ingress = 17 chars
    [[ "${#long}" -le 15 ]] || fail "iface not capped (${#long}): $long"
    [[ "$long" == wm-* ]] || fail "iface prefix: $long"
    echo "IFACE OK"
}

seed_exit() {
    write_profile_kv "$(profile_env_path ex)" \
        "PROFILE_ID=ex" "PROFILE_NAME=ex" "ROLE=exit" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "IP_VERSION=dual" "WG_MESH_SUBNET6=fd88::/64" "WG_IX_IP6=fd88::2" "WG_INGRESS_IP6=fd88::1" \
        "WG_PORT=51820" "WG_MTU=1408" "IX_ENDPOINT_HOST=203.0.113.8" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=BPUB" "WG_PEER_PUBLIC_KEY=APUB" \
        "INGRESS_PRIVKEY_B64=YQ" "MIMIC_KEEPALIVE=300:::" \
        "OBFS_MODE=mimic" "EXIT_MODE=global" "FW_OPEN_PORT=true"
}

test_code6() {
    seed_exit
    load_profile ex
    local code; code="$(generate_exit_code)"
    [[ "$code" == WMGF1:* ]] || fail "exit code prefix"
    parse_code "$code"
    [[ "$CODE_KIND" == "exit" ]] || fail "code kind=$CODE_KIND"
    [[ "$CODE_OBFS_MODE" == "mimic" ]] || fail "obfs=$CODE_OBFS_MODE"
    [[ "$CODE_EXIT_MODE" == "global" ]] || fail "exit mode"
    [[ "$CODE_IX_WG_PUBKEY" == "BPUB" ]] || fail "ix pubkey"
    [[ "$CODE_IX_WG_IP6" == "fd88::2" ]] || fail "exit ipv6"
    # 旧 schema-5 transit 码仍可解析（向后兼容）
    seed_transit; load_profile ix-nat
    parse_code "$(generate_code)"
    [[ "$CODE_KIND" == "transit" ]] || fail "transit kind regressed"
    echo "CODE6 OK"
}

test_obfs() {
    seed_exit; load_profile ex
    # exit mimic 直接处理 WireGuard 对外端口。
    local m; m="$(render_mimic_conf_for_profile)"
    grep -q 'local=' <<<"$m" || fail "exit mimic local: $m"
    grep -q ':51820' <<<"$m" || fail "exit mimic wire port: $m"
    grep -q $'ex-wire\t51820\tboth' <<<"$(collect_input_ports)" || fail "mimic input must allow tcp+udp"
    set_or_append_kv "$(profile_env_path ex)" OBFS_MODE direct
    load_profile ex
    grep -q $'ex-wire\t51820\tudp' <<<"$(collect_input_ports)" || fail "direct input must be udp-only"
    ! grep -q $'ex-wire\t51820\tboth' <<<"$(collect_input_ports)" || fail "direct input opened tcp"
    set_or_append_kv "$(profile_env_path ex)" OBFS_MODE mimic
    # relay 直接拨 B，Mimic remote 也对准同一 WG 端口。
    write_profile_kv "$(profile_env_path rl)" \
        "PROFILE_ID=rl" "ROLE=relay" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=1.2.3.4" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=p" "WG_PEER_PUBLIC_KEY=BPUB" \
        "OBFS_MODE=mimic"
    load_profile rl
    local w; w="$(render_wg_conf)"
    grep -q 'Endpoint = 1.2.3.4:51820' <<<"$w" || fail "relay endpoint: $w"
    grep -qF 'relay rl' <<<"$w" || fail "relay header"
    local mr; mr="$(render_mimic_conf_for_profile)"
    grep -q 'remote=1.2.3.4:51820' <<<"$mr" || fail "relay mimic remote: $mr"
    set_or_append_kv "$(profile_env_path rl)" OBFS_MODE direct
    load_profile rl
    [[ -z "$(render_mimic_conf_for_profile)" ]] || fail "direct mode emitted mimic filter"
    ! obfs_has_mimic || fail "direct mode requires mimic"
    echo "OBFS OK"
}

test_mss() {
    # MSS 钳制必须无条件出现在 forward 链——即便「仅全局出口(mode2)、无任何中转 DNAT 规则」也要
    # 自动生成，否则 Mimic 全局出口可能出现大包黑洞。用独立 profiles 目录隔离。
    local save="$PROFILES_DIR"
    PROFILES_DIR="$TMP/mss-only"; install -d -m 700 "$PROFILES_DIR"
    write_profile_kv "$(profile_env_path exonly)" \
        "PROFILE_ID=exonly" "ROLE=exit" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.90.0.0/24" "WG_IX_IP=10.90.0.2" "WG_INGRESS_IP=10.90.0.1" \
        "WG_PORT=51820" "WG_MTU=1400" "OBFS_MODE=mimic" "EXIT_MODE=global"
    local out; out="$(render_nft_all)"
    PROFILES_DIR="$save"
    grep -q 'iifname "wm-\*" tcp flags syn tcp option maxseg size set rt mtu' <<<"$out" || fail "scoped input mss clamp missing"
    grep -q 'oifname "wm-\*" tcp flags syn tcp option maxseg size set rt mtu' <<<"$out" || fail "scoped output mss clamp missing"
    grep -q 'ip saddr 10.90.0.0/24 oifname "eth0" counter masquerade' <<<"$out" || fail "exit masq missing: $out"
    echo "MSS OK"
}

test_client() {
    write_profile_kv "$(profile_env_path gw)" \
        "PROFILE_ID=gw" "ROLE=relay" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_PORT=51820" "WG_MTU=1400" "IX_ENDPOINT_HOST=1.2.3.4" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=GWPUB" "WG_PEER_PUBLIC_KEY=BPUB" \
        "OBFS_MODE=mimic" \
        "EXIT_MODE=global" "A_PUBLIC_HOST=8.8.8.8" "CLIENT_WG_PORT=51820" \
        "CLIENT_SUBNET=10.89.0.0/24" "CLIENT_DNS=1.1.1.1" "CLIENT_MTU=1280" \
        "ROUTE_TABLE=12345" "FW_OPEN_PORT=true"
    install -d -m 700 "$(clients_dir_for gw)"
    printf '%s\n' "CLIENT_ID=ph" "CLIENT_NAME=ph" "CLIENT_PRIVKEY=cpriv" "CLIENT_PUBKEY=CPUB" "CLIENT_IP=10.89.0.2" \
        >"$(client_env_path gw ph)"
    load_profile gw
    local w; w="$(render_wg_conf)"
    grep -q 'ListenPort = 51820' <<<"$w" || fail "relay listenport: $w"
    grep -qF 'Table = off' <<<"$w" || fail "relay table off (avoid main-route hijack)"
    grep -q 'PostUp = ip route replace default dev %i table 12345' <<<"$w" || fail "relay policy route"
    grep -q 'ip rule add from 10.89.0.0/24 lookup' <<<"$w" || fail "relay client rule"
    grep -qF 'AllowedIPs = 0.0.0.0/0' <<<"$w" || fail "relay peerB 0/0"
    grep -qF 'Address = 10.89.0.1/24' <<<"$w" || fail "relay client subnet addr"
    grep -qF 'PublicKey = CPUB' <<<"$w" || fail "client peer pubkey"
    grep -qF 'AllowedIPs = 10.89.0.2/32' <<<"$w" || fail "client peer allowedips"
    local cc; cc="$(render_client_conf cpriv 10.89.0.2 GWPUB 8.8.8.8:51820)"
    grep -qF 'Endpoint = 8.8.8.8:51820' <<<"$cc" || fail "client endpoint"
    grep -qF 'AllowedIPs = 0.0.0.0/0' <<<"$cc" || fail "client allowed"
    grep -qF 'DNS = 1.1.1.1' <<<"$cc" || fail "client dns"
    local nf; nf="$(nft_emit_gw_masq)"
    grep -q 'ip saddr 10.89.0.0/24 oifname' <<<"$nf" || fail "relay gw masq: $nf"
    echo "CLIENT OK"
}

forge_code_field() {
    local code="$1" field="$2" json_value="$3"
    parse_wmgf_code "$code" \
        | python3 -c 'import json,sys; o=json.load(sys.stdin); o[sys.argv[1]]=json.loads(sys.argv[2]); print(json.dumps(o,separators=(",",":")))' \
            "$field" "$json_value" \
        | base64url_encode | sed 's/^/WMGF1:/'
}

test_security() {
    validate_port 65535 || fail "port upper bound rejected"
    ! validate_port 65536 || fail "invalid port accepted"
    ! validate_port 999999999999999999999999 || fail "oversized port accepted"
    if ! code_is_mtu 1280 || ! code_is_mtu 1500; then fail "valid MTU rejected"; fi
    ! code_is_mtu 1501 || fail "invalid MTU accepted"
    seed_exit; load_profile ex
    local code bad
    code="$(generate_exit_code)"
    bad="$(forge_code_field "$code" project '"other-project"')"
    ! (parse_code "$bad" >/dev/null 2>&1) || fail "foreign project accepted"
    bad="$(forge_code_field "$code" wg_port '70000')"
    ! (parse_code "$bad" >/dev/null 2>&1) || fail "out-of-range WG port accepted"
    bad="$(forge_code_field "$code" wg_mesh_subnet6 '"10.0.0.0/24"')"
    ! (parse_code "$bad" >/dev/null 2>&1) || fail "IPv4 accepted in IPv6 field"
    bad="$(forge_code_field "$code" obfs_mode '"invalid"')"
    ! (parse_code "$bad" >/dev/null 2>&1) || fail "invalid obfs mode accepted"
    bad="$(forge_code_field "$code" mimic_keepalive '":"')"
    ! (parse_code "$bad" >/dev/null 2>&1) || fail "invalid Mimic keepalive accepted"
    local shown
    shown="$(show_config ex 2>/dev/null)"
    grep -q '^WG_PRIVATE_KEY=<redacted>$' <<<"$shown" || fail "show-config did not redact private key"
    ! grep -q '^WG_PRIVATE_KEY=k$' <<<"$shown" || fail "show-config leaked private key"
    shown="$(WMF_SHOW_SECRETS=1 show_config ex 2>/dev/null)"
    grep -q '^WG_PRIVATE_KEY=k$' <<<"$shown" || fail "show-config secret opt-in failed"
    write_profile_kv "$(profile_env_path minimal)" \
        "PROFILE_ID=minimal" "ROLE=nat-transit" "WAN_IFACE=eth1" "WG_PORT=12345"
    load_profile ex; load_profile minimal
    [[ -z "${OBFS_MODE:-}" && -z "${WG_MESH_SUBNET6:-}" ]] || fail "profile fields leaked across loads"
    rm -f "$(profile_env_path minimal)"
    echo "SECURITY OK"
}

test_nft_apply() {
    seed_transit
    local log="$TMP/nft.calls"
    NFT_TEST_FAIL_CHECK=0
    NFT_TEST_FAIL_LOAD=0
    nft() {
        printf '%s\n' "$*" >>"$log"
        [[ "${1:-}" == "list" ]] && return 0
        [[ "${1:-}" == "-c" && "$NFT_TEST_FAIL_CHECK" == "1" ]] && return 1
        [[ "${1:-}" == "-f" && "$NFT_TEST_FAIL_LOAD" == "1" ]] && return 1
        return 0
    }
    : >"$log"
    apply_nft_all
    grep -q '^-c -f ' "$log" || fail "nft preflight missing"
    grep -q '^-f ' "$log" || fail "nft atomic apply missing"
    [[ -s "$NFT_FILE" ]] || fail "nft canonical file missing"
    : >"$log"; NFT_TEST_FAIL_CHECK=1
    ! (apply_nft_all >/dev/null 2>&1) || fail "nft preflight failure was ignored"
    ! grep -q '^-f ' "$log" || fail "nft applied after failed preflight"
    : >"$log"; NFT_TEST_FAIL_CHECK=0; NFT_TEST_FAIL_LOAD=1
    write_rule ix-nat rule-main "RULE_ID=rule-main" "RULE_NOTE=main" "RULE_ENABLED=true" \
        "TRANSIT_PORT=40000" "LANDING_HOST=192.0.2.200" "LANDING_PORT=50000" "FORWARD_PROTO=both"
    ! (apply_nft_all >/dev/null 2>&1) || fail "nft live-load failure was ignored"
    ! grep -q '192.0.2.200' "$NFT_FILE" || fail "failed live load left new persistent rules"
    unset -f nft
    echo "NFT APPLY OK"
}

test_network_alloc() {
    local save="$PROFILES_DIR" first second six reserved table1 table2
    PROFILES_DIR="$TMP/network-alloc"; install -d -m 700 "$PROFILES_DIR"
    first="$(next_free_mesh_subnet)" || fail "first IPv4 subnet allocation failed"
    code_is_cidr4 "$first" || fail "invalid allocated IPv4 subnet: $first"
    write_profile_kv "$(profile_env_path one)" \
        "PROFILE_ID=one" "ROLE=exit" "WG_MESH_SUBNET=${first}" "WG_MESH_SUBNET6=fd42:1::/64"
    second="$(next_free_mesh_subnet)" || fail "second IPv4 subnet allocation failed"
    ! networks_overlap "$first" "$second" || fail "allocated IPv4 subnets overlap"
    network_conflicts_existing "$first" || fail "existing IPv4 conflict was missed"
    six="$(next_free_mesh_subnet6)" || fail "IPv6 subnet allocation failed"
    ! networks_overlap "$six" "fd42:1::/64" || fail "allocated IPv6 subnet overlaps"
    reserved="$(next_free_mesh_subnet "" "$second")" || fail "reserved subnet allocation failed"
    ! networks_overlap "$reserved" "$second" || fail "explicit reserved subnet was reused"
    table1="$(next_free_route_table one)" || fail "route table allocation failed"
    set_or_append_kv "$(profile_env_path one)" ROUTE_TABLE "$table1"
    table2="$(next_free_route_table two)" || fail "second route table allocation failed"
    [[ "$table1" != "$table2" ]] || fail "route table allocator returned a collision"
    PROFILES_DIR="$save"
    echo "NETWORK ALLOC OK"
}

test_global_client_ports() {
    local save="$PROFILES_DIR"
    PROFILES_DIR="$TMP/client-ports"; install -d -m 700 "$PROFILES_DIR"
    write_profile_kv "$(profile_env_path in-a)" "PROFILE_ID=in-a" "ROLE=nat-ingress"
    write_profile_kv "$(profile_env_path in-b)" "PROFILE_ID=in-b" "ROLE=nat-ingress"
    write_rule in-a tcp-rule "RULE_ID=tcp-rule" "CLIENT_PORT=30000" "FORWARD_PROTO=tcp"
    client_port_in_use in-b 30000 "" tcp || fail "cross-profile TCP collision was missed"
    ! client_port_in_use in-b 30000 "" udp || fail "non-overlapping UDP port was rejected"
    write_rule in-b udp-rule "RULE_ID=udp-rule" "CLIENT_PORT=30000" "FORWARD_PROTO=udp"
    client_port_in_use in-a 30000 tcp-rule both || fail "both-protocol collision was missed"
    ! client_port_in_use in-a 30000 tcp-rule tcp || fail "self exclusion/protocol check failed"
    write_profile_kv "$(profile_env_path exit)" "PROFILE_ID=exit" "ROLE=exit" "WG_PORT=30001"
    client_port_in_use in-a 30001 "" udp || fail "client DNAT/listener collision was missed"
    public_udp_port_in_use 30000 exit || fail "listener/client DNAT collision was missed"
    PROFILES_DIR="$save"
    echo "GLOBAL CLIENT PORTS OK"
}

test_dns_cache() {
    local save="$PROFILES_DIR" out
    PROFILES_DIR="$TMP/dns-cache"; install -d -m 700 "$PROFILES_DIR"
    write_profile_kv "$(profile_env_path dns)" \
        "PROFILE_ID=dns" "ROLE=nat-transit" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.100.10.0/24" "WG_IX_IP=10.100.10.2" "WG_INGRESS_IP=10.100.10.1" \
        "WG_PORT=51830" "FW_OPEN_PORT=true"
    write_rule dns rule "RULE_ID=rule" "RULE_ENABLED=true" "TRANSIT_PORT=40100" \
        "LANDING_HOST=unavailable.invalid" "LANDING_PORT=443" "FORWARD_PROTO=tcp"
    ! (resolve_host_ip() { :; }; render_nft_all >/dev/null 2>&1) \
        || fail "DNS failure without cache generated incomplete rules"
    ddns_state_set "landing:dns:rule" "192.0.2.55"
    out="$(resolve_host_ip() { :; }; render_nft_all)"
    grep -q 'dnat to 192.0.2.55:443' <<<"$out" || fail "cached DNS address was not used"
    PROFILES_DIR="$save"
    echo "DNS CACHE OK"
}

test_units_and_dropins() {
    (
        local units="$TMP/systemd" long_id="a-very-long-direct-profile" short_iface dropin
        install -d -m 755 "$units"
        # shellcheck disable=SC2034
        SYSTEMD_MIMIC_TEMPLATE="$units/wg-mimic-mimic@.service"
        SYSTEMD_TUNNEL_TEMPLATE="$units/wg-mimic-tunnel@.service"
        # shellcheck disable=SC2034
        SYSTEMD_OFFLOAD_TEMPLATE="$units/wg-mimic-offload@.service"
        SYSTEMD_NFT_SERVICE="$units/wg-mimic-nft.service"
        # shellcheck disable=SC2034
        SYSTEMD_DROPIN_ROOT="$units"
        WG_CONF_DIR="$TMP/wireguard"
        local calls="$units/systemctl.calls"
        systemctl() { printf '%s\n' "$*" >>"$calls"; }
        install_systemd_units
        grep -q '^ExecStart=.*/wm apply-nft-all --internal$' "$SYSTEMD_NFT_SERVICE" || fail "nft internal boot entry missing"
        grep -q '^Requires=wg-mimic-nft.service$' "$SYSTEMD_TUNNEL_TEMPLATE" || fail "tunnel does not require nft service"
        grep -q '^After=.*wg-mimic-nft.service' "$SYSTEMD_TUNNEL_TEMPLATE" || fail "nft ordering missing"
        grep -qx 'daemon-reload' "$calls" || fail "unit installation did not reload systemd"
        write_tunnel_dropin "$long_id" eth0 false
        short_iface="$(wg_iface_for "$long_id")"
        dropin="$units/wg-mimic-tunnel@${long_id}.service.d/10-profile.conf"
        grep -q "${WG_CONF_DIR}/${short_iface}.conf" "$dropin" || fail "direct long-id path override missing"
        ! grep -q 'wg-mimic-mimic@' "$dropin" || fail "direct drop-in incorrectly requires Mimic"
        write_tunnel_dropin mimic-line eth0 true
        grep -q '^Requires=wg-mimic-mimic@eth0.service$' \
            "$units/wg-mimic-tunnel@mimic-line.service.d/10-profile.conf" || fail "Mimic dependency missing"
    )
    echo "UNITS/DROPINS OK"
}

test_keepalive() {
    local save="$PROFILES_DIR" out
    PROFILES_DIR="$TMP/keepalive"; install -d -m 700 "$PROFILES_DIR"
    write_profile_kv "$(profile_env_path keep)" \
        "PROFILE_ID=keep" "ROLE=nat-transit" "ENABLED=true" "WAN_IFACE=eth9" \
        "WG_PORT=51820" "MIMIC_KEEPALIVE=123:45:6"
    out="$(render_mimic_conf_iface eth9)"
    grep -q '^keepalive = 123:45:6$' <<<"$out" || fail "custom Mimic keepalive was ignored"
    PROFILES_DIR="$save"
    echo "KEEPALIVE OK"
}

test_state_rollback() {
    (
        require_root() { :; }
        PROFILES_DIR="$TMP/rollback"; install -d -m 700 "$PROFILES_DIR"
        write_profile_kv "$(profile_env_path rollback)" \
            "PROFILE_ID=rollback" "ROLE=exit" "ENABLED=false" "WAN_IFACE=eth0" \
            "OBFS_MODE=direct" "WG_PORT=51820"
        install_systemd_units() { :; }
        apply_profile_configs() { :; }
        apply_nft_all() { :; }
        ensure_ip_forward() { :; }
        systemctl() {
            [[ "${1:-}" == "restart" && "${2:-}" == "wg-mimic-tunnel@rollback.service" ]] && return 37
            return 0
        }
        journalctl() {
            printf '%s\n' 'nft dependency failed' 'PrivateKey = TOP_SECRET' \
                'token WMGF1:YWJjZGVm' 'peer AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        }
        set +e
        (set -Eeuo pipefail; start_profile rollback) >"$TMP/start-failure.log" 2>&1
        local rc=$?
        set -e
        [[ "$rc" == 37 ]] || fail "start lost systemctl exit code: $rc"
        grep -q '^ENABLED=false$' "$(profile_env_path rollback)" || fail "failed start did not restore ENABLED"
        grep -q 'nft dependency failed' "$TMP/start-failure.log" || fail "failure journal missing"
        ! grep -qE 'TOP_SECRET|WMGF1:YWJjZGVm|AAAAAAAAAAA' "$TMP/start-failure.log" || fail "failure journal leaked secrets"
    )
    (
        require_root() { :; }
        PROFILES_DIR="$TMP/rollback-stop"; install -d -m 700 "$PROFILES_DIR"
        write_profile_kv "$(profile_env_path rollback)" \
            "PROFILE_ID=rollback" "ROLE=exit" "ENABLED=true" "WAN_IFACE=" \
            "OBFS_MODE=direct" "WG_PORT=51820"
        local nft_calls=0
        apply_nft_all() { nft_calls=$((nft_calls + 1)); (( nft_calls > 1 )); }
        systemctl() { [[ "${1:-}" == "is-active" ]] && return 1; return 0; }
        ! (stop_profile rollback >/dev/null 2>&1) || fail "failed stop reported success"
        grep -q '^ENABLED=true$' "$(profile_env_path rollback)" || fail "failed stop did not restore ENABLED"
    )
    echo "STATE ROLLBACK OK"
}

test_lock_errexit() {
    (
        require_root() { :; }
        # shellcheck disable=SC2034
        STATE_LOCK_FILE="$TMP/lock/wmf.lock"
        lock_probe() { false; : >"$TMP/lock-continued"; }
        set +e
        with_state_lock lock_probe >/dev/null 2>&1
        local rc=$?
        set -e
        (( rc != 0 )) || fail "locked failing command reported success"
        [[ ! -e "$TMP/lock-continued" ]] || fail "locked command continued after failure"
        set +e
        with_nft_lock lock_probe >/dev/null 2>&1
        rc=$?
        set -e
        (( rc != 0 )) || fail "nft-locked failing command reported success"
        [[ ! -e "$TMP/lock-continued" ]] || fail "nft-locked command continued after failure"
        flock -n "$NFT_LOCK_FILE" true || fail "nft lock leaked after failure"
        # Reentrant state operations still reuse the outer state lock.
        with_state_lock with_state_lock true
    )
    echo "LOCK ERREXIT OK"
}

# Each invocation below is a fresh Bash process containing the real script and
# main dispatcher. Only OS/service commands and filesystem roots are mocked.
# In particular, the simulated systemd manager does not inherit WMF_LOCK_HELD.
nft_fixture() {
    export WMF_TEST_ROOT="$TMP/$1"
    export WMF_TEST_SETUP="$TMP/mock-env.sh" WMF_TEST_DRIVER="$TMP/mock-wm"
    {
        printf '#!/usr/bin/env bash\nWMF_SOURCED=1\n'
        cat "$HERE/../install.sh"
        cat <<'DRIVER'
# shellcheck disable=SC1090
source "$WMF_TEST_SETUP"
if [[ "${1:-}" == test-write ]]; then
    set_or_append_kv "$(profile_env_path ex)" WG_PORT 51999
else
    main "$@"
fi
DRIVER
    } >"$WMF_TEST_DRIVER"
    chmod 755 "$WMF_TEST_DRIVER"
    cat >"$WMF_TEST_SETUP" <<'MOCKS'
CONFIG_DIR="$WMF_TEST_ROOT/etc"
PROFILES_DIR="$CONFIG_DIR/profiles"
CODES_DIR="$CONFIG_DIR/codes"
STATE_DIR="$CONFIG_DIR/state"
RESUME_MARKER="$STATE_DIR/resume.cmd"
NFT_DIR="$WMF_TEST_ROOT/nft"
NFT_FILE="$NFT_DIR/wg-mimic-fabric.nft"
STATE_LOCK_FILE="$WMF_TEST_ROOT/state.lock"
NFT_LOCK_FILE="$WMF_TEST_ROOT/nft.lock"
LIBEXEC_DIR="$WMF_TEST_ROOT/libexec"
WM_CLI_INSTALL_SH="$LIBEXEC_DIR/install.sh"
WM_BIN="$WMF_TEST_ROOT/bin/wm"
BACKUP_DIR="$WMF_TEST_ROOT/backups"
MIMIC_CONF_DIR="$WMF_TEST_ROOT/mimic"
WG_CONF_DIR="$WMF_TEST_ROOT/wireguard"
SYSTEMD_DROPIN_ROOT="$WMF_TEST_ROOT/systemd"
SYSTEMD_MIMIC_TEMPLATE="$SYSTEMD_DROPIN_ROOT/wg-mimic-mimic@.service"
SYSTEMD_TUNNEL_TEMPLATE="$SYSTEMD_DROPIN_ROOT/wg-mimic-tunnel@.service"
SYSTEMD_OFFLOAD_TEMPLATE="$SYSTEMD_DROPIN_ROOT/wg-mimic-offload@.service"
SYSTEMD_NFT_SERVICE="$SYSTEMD_DROPIN_ROOT/wg-mimic-nft.service"
SYSTEMD_RESUME_SERVICE="$SYSTEMD_DROPIN_ROOT/wg-mimic-resume.service"
export TMPDIR="$WMF_TEST_ROOT/tmp"
install -d "$PROFILES_DIR" "$CODES_DIR" "$STATE_DIR" "$NFT_DIR" "$LIBEXEC_DIR" \
    "$(dirname "$WM_BIN")" "$MIMIC_CONF_DIR" "$WG_CONF_DIR" "$SYSTEMD_DROPIN_ROOT" "$TMPDIR"
if [[ ! -e "$WM_BIN" ]]; then
    printf '#!/usr/bin/env bash\nexec "$WMF_TEST_DRIVER" "$@"\n' >"$WM_BIN"
    chmod 755 "$WM_BIN"
fi
if [[ -n "${WMF_TEST_JOB:-}" ]]; then : >"$WMF_TEST_ROOT/started-$WMF_TEST_JOB"; fi
id() { if [[ "${1:-}" == -u ]]; then printf '%s\n' "${WMF_TEST_UID:-0}"; else command id "$@"; fi; }
test_event() { printf '%s %s\n' "${WMF_TEST_JOB:-wm}" "$*" >>"$WMF_TEST_ROOT/events"; }
eval "$(declare -f render_nft_all | sed '1s/render_nft_all/test_render_nft_all/')"
render_nft_all() {
    test_event render
    [[ "${WMF_TEST_FAIL_RENDER:-0}" == 0 ]] || return 44
    test_render_nft_all
}
nft() {
    case "${1:-}" in
        list) test_event list; [[ -f "$WMF_TEST_ROOT/live.nft" ]]; return ;;
        -c)
            test_event check
            command cp "$3" "$WMF_TEST_ROOT/checked-${WMF_TEST_JOB:-wm}.nft"
            if [[ "${WMF_TEST_PAUSE_CHECK:-0}" == 1 ]]; then
                : >"$WMF_TEST_ROOT/check-entered"
                read -r _ <"$WMF_TEST_ROOT/check-gate"
            fi
            [[ "${WMF_TEST_FAIL_CHECK:-0}" == 0 ]] || return 41
            ;;
        -f)
            test_event load
            [[ "${WMF_TEST_SIGNAL:-0}" == 0 ]] || kill -TERM "$BASHPID"
            [[ "${WMF_TEST_FAIL_LOAD:-0}" == 0 ]] || return 42
            sed '/^delete table inet /d' "$2" >"$WMF_TEST_ROOT/live.nft"
            test_event loaded
            ;;
        *) return 90 ;;
    esac
}
mv() {
    if [[ "${3:-}" == "$NFT_FILE" ]]; then
        if [[ "$2" == *.previous.* ]]; then
            test_event rollback
        else
            test_event publish
            [[ "${WMF_TEST_FAIL_PERSIST:-0}" == 0 ]] || return 43
        fi
    fi
    command mv "$@"
}
rm() {
    command rm "$@" || return $?
    if [[ $# == 3 && "$2" == "$NFT_DIR"/.wg-mimic-fabric.* ]]; then test_event cleanup; fi
    return 0
}
systemctl() {
    printf '%s\n' "$*" >>"$WMF_TEST_ROOT/systemctl.calls"
    local unit="${2:-}" profile
    case "$1" in
        restart|start)
            [[ "$unit" == wg-mimic-tunnel@* ]] || return 0
            # No nft descriptor may survive into a blocking systemctl operation.
            flock -n "$NFT_LOCK_FILE" true || return 91
            if [[ "$(cat "$WMF_TEST_ROOT/nft.state" 2>/dev/null)" != active ]]; then
                # Read and execute exactly the generated nft unit's ExecStart.
                local entry=()
                read -ra entry <<<"$(sed -n 's/^ExecStart=//p' "$SYSTEMD_NFT_SERVICE")"
                local internal_fail="${WMF_TEST_FAIL_CHECK:-0}"
                [[ ! -e "$WMF_TEST_ROOT/fail-internal" ]] || internal_fail=1
                env -u WMF_LOCK_HELD WMF_TEST_FAIL_CHECK="$internal_fail" "${entry[@]}" \
                    || { printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"; return 92; }
                printf 'active\n' >"$WMF_TEST_ROOT/nft.state"
            fi
            [[ ! -e "$WMF_TEST_ROOT/fail-tunnel" ]] || return 37
            profile="${unit#wg-mimic-tunnel@}"; profile="${profile%.service}"
            printf 'active\n' >"$WMF_TEST_ROOT/tunnel-$profile.state"
            ;;
        disable)
            if [[ "${2:-}" == --now && "${3:-}" == wg-mimic-tunnel@* ]]; then
                profile="${3#wg-mimic-tunnel@}"; profile="${profile%.service}"
                printf 'inactive\n' >"$WMF_TEST_ROOT/tunnel-$profile.state"
            fi
            ;;
        is-active)
            unit="${@: -1}"
            profile="${unit#wg-mimic-tunnel@}"; profile="${profile%.service}"
            [[ "$(cat "$WMF_TEST_ROOT/tunnel-$profile.state" 2>/dev/null)" == active ]]
            return
            ;;
    esac
    return 0
}
journalctl() { printf 'mock service dependency diagnostic\n'; }
ensure_ip_forward() { :; }
ensure_supported_platform() { :; }
install_runtime_packages() { :; }
ensure_cli_aliases() { :; }
ensure_mimic() { :; }
ensure_mimic_service_up() { :; }
mimic_needs_reboot() { return 1; }
cloud_kernel_advisory() { return 1; }
modprobe() { :; }
download_with_mirrors() { command cp "$WMF_TEST_DRIVER" "$2"; }
wg() { [[ "${1:-}" != show ]]; }
detect_local_ip() { printf '203.0.113.9'; }
if [[ "${WMF_TEST_DNS:-0}" == 1 ]]; then
    resolve_host_ip() { if [[ "$1" == old.invalid ]]; then printf '203.0.113.8'; else printf '%s' "$1"; fi; }
fi
if [[ "${WMF_TEST_FAST:-0}" == 1 ]]; then
    sleep() { :; }
    measure_tunnel_loss() { if [[ "${IX_ENDPOINT_HOST:-}" == 203.0.113.20 ]]; then printf '0'; else printf '100'; fi; }
fi
MOCKS
    # shellcheck disable=SC1090
    source "$WMF_TEST_SETUP"
    unset WMF_LOCK_HELD
    seed_exit
    set_or_append_kv "$(profile_env_path ex)" OBFS_MODE direct
}

wait_for_file() {
    local i
    for ((i=0; i<150; i++)); do
        [[ ! -e "$1" ]] || return 0
        sleep 0.02
    done
    fail "timed out waiting for $1"
}

test_nft_process_locks() (
    nft_fixture process-locks
    mkfifo "$WMF_TEST_ROOT/state-gate"
    timeout 10 flock "$STATE_LOCK_FILE" bash -c ': >"$1"; read -r _ <"$2"' \
        _ "$WMF_TEST_ROOT/state-held" "$WMF_TEST_ROOT/state-gate" &
    local holder=$! rc
    wait_for_file "$WMF_TEST_ROOT/state-held"
    # A real independent process must complete while the global lock is held.
    timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal >"$WMF_TEST_ROOT/internal.out" 2>&1
    ! grep -q '另一个 wm 操作正在运行' "$WMF_TEST_ROOT/internal.out" || fail "internal nft waited for state lock"
    [[ -s "$NFT_FILE" ]] || fail "internal nft did not apply rules"
    : >"$WMF_TEST_ROOT/events"
    set +e
    WMF_LOCK_TIMEOUT=0.1 timeout 3 "$WMF_TEST_DRIVER" apply-nft-all >"$WMF_TEST_ROOT/cli.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == 1 ]] || fail "normal nft CLI bypassed state lock ($rc)"
    grep -q '另一个 wm 操作正在运行' "$WMF_TEST_ROOT/cli.out" || fail "state timeout diagnostic missing"
    [[ ! -s "$WMF_TEST_ROOT/events" ]] || fail "CLI touched nft while state lock was held"
    local arg
    for arg in --internal extra; do
        # --internal must not become a flag accepted before the subcommand.
        ! timeout 3 "$WMF_TEST_DRIVER" "$arg" apply-nft-all >/dev/null 2>&1 || fail "global internal flag accepted"
    done
    ! timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal extra >/dev/null 2>&1 || fail "trailing internal arguments accepted"
    ! timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal --internal >/dev/null 2>&1 || fail "duplicate internal flag accepted"
    ! timeout 3 "$WMF_TEST_DRIVER" apply-nft-all '' >/dev/null 2>&1 || fail "empty internal argument accepted"
    ! WMF_TEST_UID=1000 timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal >/dev/null 2>&1 || fail "non-root internal call accepted"
    set +e
    WMF_LOCK_TIMEOUT=0.1 timeout 3 "$WMF_TEST_DRIVER" start ex --internal >"$WMF_TEST_ROOT/start.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" == 1 ]] || fail "--internal bypassed another command's state lock"
    grep -q '另一个 wm 操作正在运行' "$WMF_TEST_ROOT/start.out" || fail "other command lost state locking"
    printf 'go\n' >"$WMF_TEST_ROOT/state-gate"
    wait "$holder"
    # Internal and ordinary calls both still contend for the nft lock.
    mkfifo "$WMF_TEST_ROOT/nft-gate"
    timeout 10 flock "$NFT_LOCK_FILE" bash -c ': >"$1"; read -r _ <"$2"' \
        _ "$WMF_TEST_ROOT/nft-held" "$WMF_TEST_ROOT/nft-gate" &
    holder=$!
    wait_for_file "$WMF_TEST_ROOT/nft-held"
    ! WMF_NFT_LOCK_TIMEOUT=0.1 timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal >/dev/null 2>&1 || fail "internal call bypassed nft lock"
    ! WMF_NFT_LOCK_TIMEOUT=0.1 timeout 3 "$WMF_TEST_DRIVER" apply-nft-all >/dev/null 2>&1 || fail "CLI bypassed nft lock"
    printf 'go\n' >"$WMF_TEST_ROOT/nft-gate"
    wait "$holder"
    timeout 3 "$WMF_TEST_DRIVER" apply-nft-all >/dev/null 2>&1
    echo "NFT PROCESS LOCKS OK"
)

test_nft_serial() (
    nft_fixture nft-serial
    mkfifo "$WMF_TEST_ROOT/check-gate"
    : >"$WMF_TEST_ROOT/events"
    WMF_TEST_JOB=A WMF_TEST_PAUSE_CHECK=1 timeout 8 "$WMF_TEST_DRIVER" apply-nft-all --internal &
    local first=$! second
    wait_for_file "$WMF_TEST_ROOT/check-entered"
    WMF_TEST_JOB=B timeout 8 "$WMF_TEST_DRIVER" apply-nft-all --internal &
    second=$!
    wait_for_file "$WMF_TEST_ROOT/started-B"
    sleep 0.1
    ! grep -q '^B ' "$WMF_TEST_ROOT/events" || fail "second transaction rendered while first held nft lock"
    printf 'go\n' >"$WMF_TEST_ROOT/check-gate"
    wait "$first"
    wait "$second"
    [[ "$(cut -d' ' -f1 "$WMF_TEST_ROOT/events" | uniq | tr '\n' ' ')" == 'A B ' ]] || fail "nft transactions interleaved"
    grep -qx 'A cleanup' "$WMF_TEST_ROOT/events" || fail "first transaction did not clean up under lock"
    grep -qx 'B cleanup' "$WMF_TEST_ROOT/events" || fail "second transaction did not clean up under lock"
    files_equal "$NFT_FILE" "$WMF_TEST_ROOT/live.nft" || fail "persistent/live rules differ"
    grep -q '^delete table inet ' "$WMF_TEST_ROOT/checked-B.nft" || fail "second transaction missed newly created table"
    echo "NFT SERIAL OK"
)

test_nft_config_snapshot() (
    nft_fixture config-snapshot
    mkfifo "$WMF_TEST_ROOT/check-gate"
    WMF_TEST_JOB=reader WMF_TEST_PAUSE_CHECK=1 timeout 8 "$WMF_TEST_DRIVER" apply-nft-all --internal &
    local reader=$! writer
    wait_for_file "$WMF_TEST_ROOT/check-entered"
    WMF_TEST_JOB=writer timeout 8 "$WMF_TEST_DRIVER" test-write &
    writer=$!
    wait_for_file "$WMF_TEST_ROOT/started-writer"
    sleep 0.1
    grep -qx 'WG_PORT=51820' "$(profile_env_path ex)" || fail "profile changed during nft transaction"
    printf 'go\n' >"$WMF_TEST_ROOT/check-gate"
    wait "$reader"
    wait "$writer"
    grep -qx 'WG_PORT=51999' "$(profile_env_path ex)" || fail "writer failed after nft lock released"
    grep -q 'udp dport 51820' "$NFT_FILE" || fail "render mixed profile versions"
    timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal
    grep -q 'udp dport 51999' "$NFT_FILE" || fail "subsequent render missed complete profile update"
    [[ "$(stat -c %a "$(profile_env_path ex)")" == 600 ]] || fail "atomic env update changed private file permissions"
    echo "NFT CONFIG SNAPSHOT OK"
)

test_nft_failures() (
    nft_fixture nft-failures
    timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal
    cp "$NFT_FILE" "$WMF_TEST_ROOT/old.nft"
    set_or_append_kv "$(profile_env_path ex)" WG_PORT 51999
    local kind rc expected
    for kind in CHECK LOAD PERSIST RENDER SIGNAL; do
        expected=1
        case "$kind" in CHECK) expected=41 ;; LOAD) expected=42 ;; PERSIST) expected=43 ;; SIGNAL) expected=143 ;; esac
        set +e
        env "WMF_TEST_FAIL_${kind}=1" "WMF_TEST_SIGNAL=$([[ "$kind" == SIGNAL ]] && printf 1 || printf 0)" \
            timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal >"$WMF_TEST_ROOT/failure-$kind.out" 2>&1
        rc=$?
        set -e
        [[ "$rc" == "$expected" ]] || fail "$kind failure returned $rc instead of $expected"
        files_equal "$NFT_FILE" "$WMF_TEST_ROOT/old.nft" || fail "$kind failure changed persistent rules"
        files_equal "$WMF_TEST_ROOT/live.nft" "$WMF_TEST_ROOT/old.nft" || fail "$kind failure changed live rules"
        ! compgen -G "$NFT_DIR/.wg-mimic-fabric.*" >/dev/null || fail "$kind failure left nft temp files"
        [[ -z "$(ls -A "$TMPDIR")" ]] || fail "$kind failure left transaction temp files"
        flock -n "$NFT_LOCK_FILE" true || fail "$kind failure leaked nft lock"
    done
    for kind in CHECK LOAD; do
        rm -f "$NFT_FILE" "$WMF_TEST_ROOT/live.nft"
        ! env "WMF_TEST_FAIL_${kind}=1" timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal >/dev/null 2>&1 || fail "first $kind failure ignored"
        [[ ! -e "$NFT_FILE" && ! -e "$WMF_TEST_ROOT/live.nft" ]] || fail "first $kind failure left persistent/live rules"
    done
    echo "NFT FAILURES OK"
)

test_start_resume() (
    nft_fixture start-resume
    set_profile_enabled_value "$(profile_env_path ex)" false
    write_profile_kv "$(profile_env_path ex2)" \
        "PROFILE_ID=ex2" "ROLE=exit" "ENABLED=true" "WAN_IFACE=eth0" "OBFS_MODE=direct" \
        "WG_MESH_SUBNET=10.99.0.0/24" "WG_IX_IP=10.99.0.2" "WG_INGRESS_IP=10.99.0.1" \
        "WG_PORT=51821" "WG_MTU=1420" "IX_ENDPOINT_HOST=203.0.113.9" \
        "WG_PRIVATE_KEY=k" "WG_PEER_PUBLIC_KEY=p"
    # First activation, existing failed dependency, explicit restart and boot resume.
    timeout 4 "$WMF_TEST_DRIVER" start ex >"$WMF_TEST_ROOT/first.out" 2>&1
    [[ "$(cat "$WMF_TEST_ROOT/nft.state")" == active ]] || fail "first start failed nft dependency"
    [[ "$(cat "$WMF_TEST_ROOT/tunnel-ex.state")" == active ]] || fail "first tunnel did not start"
    ! grep -q 'mock service dependency diagnostic' "$WMF_TEST_ROOT/first.out" || fail "journal printed on success"
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    timeout 4 "$WMF_TEST_DRIVER" start ex >/dev/null 2>&1
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    timeout 4 "$WMF_TEST_DRIVER" restart ex >/dev/null 2>&1
    install_resume_unit 'start ex2'
    grep -q '^ExecStart=.*/wm resume$' "$SYSTEMD_RESUME_SERVICE" || fail "resume entry changed"
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    timeout 4 "$WMF_TEST_DRIVER" resume >/dev/null 2>&1
    [[ ! -e "$RESUME_MARKER" && ! -e "$SYSTEMD_RESUME_SERVICE" ]] || fail "resume marker/unit not consumed"
    [[ "$(cat "$WMF_TEST_ROOT/tunnel-ex2.state")" == active ]] || fail "resume did not start second profile"
    grep -q 'udp dport 51820' "$NFT_FILE" || fail "multi-profile start lost first profile"
    grep -q 'udp dport 51821' "$NFT_FILE" || fail "multi-profile start lost second profile"
    # A failed nft dependency must still prevent tunnel startup and restore ENABLED.
    set_profile_enabled_value "$(profile_env_path ex)" false
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    # Fail only the internal dependency (the CLI pre-apply succeeds).
    : >"$WMF_TEST_ROOT/fail-internal"
    ! timeout 4 "$WMF_TEST_DRIVER" start ex >/dev/null 2>&1 || fail "failed nft dependency allowed tunnel start"
    grep -qx 'ENABLED=false' "$(profile_env_path ex)" || fail "dependency failure lost ENABLED rollback"
    [[ "$(cat "$WMF_TEST_ROOT/tunnel-ex.state")" == inactive ]] || fail "dependency failure left tunnel active"
    echo "START/RESTART/RESUME OK"
)

test_upgrade_nft_unit() (
    nft_fixture upgrade-unit
    cp "$(profile_env_path ex)" "$WMF_TEST_ROOT/profile.before"
    timeout 3 "$WMF_TEST_DRIVER" apply-nft-all --internal
    cp "$NFT_FILE" "$WMF_TEST_ROOT/nft.before"
    install_systemd_units
    sed -i 's/apply-nft-all --internal/apply-nft-all/' "$SYSTEMD_NFT_SERVICE"
    install -m 755 "$WMF_TEST_DRIVER" "$WM_CLI_INSTALL_SH"
    sed -i 's/^SCRIPT_VERSION="1.4.12"/SCRIPT_VERSION="1.4.10"/' "$WM_CLI_INSTALL_SH"
    # Restore the v1.4.10 upgrade body: its install command is the only
    # difference from the new upgrade_script function. Refresh runs new code.
    sed -i 's/write_generated_config "$WM_CLI_INSTALL_SH" 755 cat "$tmp"/install -m 755 "$tmp" "$WM_CLI_INSTALL_SH"/' "$WM_CLI_INSTALL_SH"
    : >"$WMF_TEST_ROOT/systemctl.calls"
    WMF_UPGRADE_YES=1 timeout 4 "$WM_CLI_INSTALL_SH" upgrade-script >/dev/null 2>&1
    grep -qx 'SCRIPT_VERSION="1.4.12"' "$WM_CLI_INSTALL_SH" || fail "old version skipped upgrade"
    grep -q '^ExecStart=.*/wm apply-nft-all --internal$' "$SYSTEMD_NFT_SERVICE" || fail "upgrade kept old nft entry"
    grep -qx 'Requires=wg-mimic-nft.service' "$SYSTEMD_TUNNEL_TEMPLATE" || fail "upgrade weakened nft dependency"
    grep -qx 'daemon-reload' "$WMF_TEST_ROOT/systemctl.calls" || fail "upgrade did not reload systemd"
    compgen -G "$BACKUP_DIR/install.sh.bak.*" >/dev/null || fail "upgrade did not back up old script"
    files_equal "$(profile_env_path ex)" "$WMF_TEST_ROOT/profile.before" || fail "upgrade modified profile/private keys"
    files_equal "$NFT_FILE" "$WMF_TEST_ROOT/nft.before" || fail "upgrade modified persistent rules"
    : >"$WMF_TEST_ROOT/systemctl.calls"
    timeout 3 "$WM_CLI_INSTALL_SH" upgrade-script >/dev/null 2>&1
    [[ ! -s "$WMF_TEST_ROOT/systemctl.calls" ]] || fail "same-version upgrade no longer skips refresh"
    echo "UPGRADE NFT UNIT OK"
)

test_nft_maintenance() (
    nft_fixture maintenance
    seed_transit
    write_profile_kv "$(profile_env_path ing)" \
        "PROFILE_ID=ing" "ROLE=nat-ingress" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=old.invalid" \
        "WG_PRIVATE_KEY=k" "WG_PEER_PUBLIC_KEY=p" "ENDPOINT_CANDIDATES=203.0.113.20"
    write_rule ing rule-main "RULE_ID=rule-main" "RULE_ENABLED=true" "TRANSIT_PORT=40000" \
        "CLIENT_PORT=30000" "LANDING_HOST=1.2.3.4" "LANDING_PORT=50000" "FORWARD_PROTO=both"
    WMF_TEST_DNS=1 timeout 4 "$WMF_TEST_DRIVER" ddns-refresh >"$WMF_TEST_ROOT/ddns.out" 2>&1 \
        || { cat "$WMF_TEST_ROOT/ddns.out" >&2; fail "DDNS refresh failed"; }
    grep -qx 'endpoint:ing=203.0.113.8' "$(ddns_state_file)" || fail "DDNS endpoint cache lost"
    grep -qx 'landing:ix-nat:rule-main=1.2.3.4' "$(ddns_state_file)" || fail "DDNS landing cache lost"
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    WMF_TEST_FAST=1 timeout 4 "$WMF_TEST_DRIVER" autoswitch ing >"$WMF_TEST_ROOT/autoswitch.out" 2>&1 \
        || { cat "$WMF_TEST_ROOT/autoswitch.out" >&2; fail "autoswitch failed"; }
    grep -qx 'IX_ENDPOINT_HOST=203.0.113.20' "$(profile_env_path ing)" || fail "autoswitch did not persist candidate"
    grep -qx 'autoswitch:ing=203.0.113.20' "$(ddns_state_file)" || fail "autoswitch state lost"
    timeout 4 "$WMF_TEST_DRIVER" set-group ex group primary >/dev/null 2>&1
    timeout 4 "$WMF_TEST_DRIVER" set-group ing group backup >/dev/null 2>&1
    printf 'failed\n' >"$WMF_TEST_ROOT/nft.state"
    timeout 4 "$WMF_TEST_DRIVER" switch-line group ing >"$WMF_TEST_ROOT/switch.out" 2>&1 \
        || { cat "$WMF_TEST_ROOT/switch.out" >&2; fail "switch-line failed"; }
    grep -qx 'ENABLED=false' "$(profile_env_path ex)" || fail "switch-line kept previous member enabled"
    grep -qx 'ENABLED=true' "$(profile_env_path ing)" || fail "switch-line did not enable target"
    grep -q 'dnat to 10.88.0.2:40000' "$NFT_FILE" || fail "ingress DNAT lost after maintenance"
    grep -q 'dnat to 1.2.3.4:50000' "$NFT_FILE" || fail "transit DNAT lost after maintenance"
    files_equal "$NFT_FILE" "$WMF_TEST_ROOT/live.nft" || fail "maintenance left live/persistent nft mismatch"
    echo "DDNS/AUTOSWITCH/SWITCH-LINE OK"
)

test_atomic_configs() (
    local output="$TMP/atomic-config" writer
    printf 'complete-old\n' >"$output"
    mkfifo "$TMP/config-gate"
    render_slow_config() {
        printf 'partial-new'
        : >"$TMP/config-rendering"
        read -r _ <"$TMP/config-gate"
        printf '\ncomplete-new\n'
    }
    write_generated_config "$output" 600 render_slow_config &
    writer=$!
    wait_for_file "$TMP/config-rendering"
    [[ "$(cat "$output")" == complete-old ]] || fail "systemd reader observed partial generated config"
    printf 'go\n' >"$TMP/config-gate"
    wait "$writer"
    grep -qx 'complete-new' "$output" || fail "generated config was not published"
    local previous; previous="$(cat "$output")"
    render_bad_config() { printf 'bad'; return 45; }
    ! (write_generated_config "$output" 600 render_bad_config) || fail "failed config render reported success"
    [[ "$(cat "$output")" == "$previous" ]] || fail "failed render replaced generated config"
    echo "ATOMIC CONFIGS OK"
)

case "${1:-all}" in
    rule) test_rule ;;
    code) test_code ;;
    wgconf) test_wgconf ;;
    nft) test_nft ;;
    ipv6) test_ipv6 ;;
    group) test_group ;;
    pool) test_pool ;;
    mimic) test_mimic ;;
    iface) test_iface ;;
    code6) test_code6 ;;
    obfs) test_obfs ;;
    mss) test_mss ;;
    client) test_client ;;
    security) test_security ;;
    nftapply) test_nft_apply ;;
    network) test_network_alloc ;;
    ports) test_global_client_ports ;;
    dns) test_dns_cache ;;
    units) test_units_and_dropins ;;
    keepalive) test_keepalive ;;
    rollback) test_state_rollback ;;
    lock) test_lock_errexit ;;
    nftlocks) test_nft_process_locks; test_nft_serial; test_nft_config_snapshot ;;
    nftfail) test_nft_failures ;;
    lifecycle) test_start_resume ;;
    upgrade) test_upgrade_nft_unit ;;
    maintenance) test_nft_maintenance ;;
    atomic) test_atomic_configs ;;
    nopy) test_rule; test_wgconf; test_nft; test_nft_apply; test_ipv6; test_group; test_pool; test_mimic; test_iface; test_obfs; test_mss; test_client; echo "NOPY OK" ;;
    all) test_rule; test_code; test_code6; test_security; test_obfs; test_mss; test_client; test_wgconf; test_nft; test_nft_apply; test_ipv6; test_group; test_pool; test_mimic; test_iface; test_network_alloc; test_global_client_ports; test_dns_cache; test_units_and_dropins; test_keepalive; test_state_rollback; test_lock_errexit; test_nft_process_locks; test_nft_serial; test_nft_config_snapshot; test_nft_failures; test_start_resume; test_upgrade_nft_unit; test_nft_maintenance; test_atomic_configs; echo "ALL OK" ;;
    *) echo "usage: smoke.sh [rule|code|code6|security|obfs|mss|client|wgconf|nft|nftapply|ipv6|group|pool|mimic|iface|network|ports|dns|units|keepalive|rollback|lock|nftlocks|nftfail|lifecycle|upgrade|maintenance|atomic|nopy|all]"; exit 1 ;;
esac
