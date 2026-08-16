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
install -d -m 700 "$PROFILES_DIR" "$CODES_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

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
        systemctl() { :; }
        install_systemd_units
        grep -q '^ExecStart=.*/wm apply-nft-all$' "$SYSTEMD_NFT_SERVICE" || fail "nft boot service missing"
        grep -q '^Requires=wg-mimic-nft.service$' "$SYSTEMD_TUNNEL_TEMPLATE" || fail "tunnel does not require nft service"
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
        PROFILES_DIR="$TMP/rollback"; install -d -m 700 "$PROFILES_DIR"
        write_profile_kv "$(profile_env_path rollback)" \
            "PROFILE_ID=rollback" "ROLE=exit" "ENABLED=false" "WAN_IFACE=eth0" \
            "OBFS_MODE=direct" "WG_PORT=51820"
        install_systemd_units() { :; }
        apply_profile_configs() { :; }
        apply_nft_all() { :; }
        ensure_ip_forward() { :; }
        systemctl() {
            [[ "${1:-}" == "restart" && "${2:-}" == "wg-mimic-tunnel@rollback.service" ]] && return 1
            return 0
        }
        ! (start_profile rollback >/dev/null 2>&1) || fail "failed start reported success"
        grep -q '^ENABLED=false$' "$(profile_env_path rollback)" || fail "failed start did not restore ENABLED"
    )
    (
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
        # shellcheck disable=SC2034
        STATE_LOCK_FILE="$TMP/lock/wmf.lock"
        lock_probe() { false; : >"$TMP/lock-continued"; }
        set +e
        with_state_lock lock_probe >/dev/null 2>&1
        local rc=$?
        set -e
        (( rc != 0 )) || fail "locked failing command reported success"
        [[ ! -e "$TMP/lock-continued" ]] || fail "locked command continued after failure"
    )
    echo "LOCK ERREXIT OK"
}

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
    nopy) test_rule; test_wgconf; test_nft; test_nft_apply; test_ipv6; test_group; test_pool; test_mimic; test_iface; test_obfs; test_mss; test_client; echo "NOPY OK" ;;
    all) test_rule; test_code; test_code6; test_security; test_obfs; test_mss; test_client; test_wgconf; test_nft; test_nft_apply; test_ipv6; test_group; test_pool; test_mimic; test_iface; test_network_alloc; test_global_client_ports; test_dns_cache; test_units_and_dropins; test_keepalive; test_state_rollback; test_lock_errexit; echo "ALL OK" ;;
    *) echo "usage: smoke.sh [rule|code|code6|security|obfs|mss|client|wgconf|nft|nftapply|ipv6|group|pool|mimic|iface|network|ports|dns|units|keepalive|rollback|lock|nopy|all]"; exit 1 ;;
esac
