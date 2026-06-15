#!/usr/bin/env bash
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
KEYS_DIR="$CONFIG_DIR/keys"
STATE_DIR="$CONFIG_DIR/state"
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
        "IP_VERSION=4" "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=b.example" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=BPUB" "WG_PEER_PUBLIC_KEY=APUB" \
        "INGRESS_PRIVKEY_B64=YQ" "MIMIC_KEEPALIVE=300:::" \
        "OBFS_MODE=swgp+mimic" "SWGP_MODE=zero-overhead-2026" "SWGP_PSK=PSKB64" "SWGP_PORT=18443" \
        "EXIT_MODE=global" "FW_OPEN_PORT=true"
}

test_code6() {
    seed_exit
    load_profile ex
    local code; code="$(generate_exit_code)"
    [[ "$code" == WMGF1:* ]] || fail "exit code prefix"
    parse_code "$code"
    [[ "$CODE_KIND" == "exit" ]] || fail "code kind=$CODE_KIND"
    [[ "$CODE_OBFS_MODE" == "swgp+mimic" ]] || fail "obfs=$CODE_OBFS_MODE"
    [[ "$CODE_SWGP_MODE" == "zero-overhead-2026" ]] || fail "swgp mode"
    [[ "$CODE_SWGP_PSK" == "PSKB64" ]] || fail "swgp psk"
    [[ "$CODE_SWGP_PORT" == "18443" ]] || fail "swgp port=$CODE_SWGP_PORT"
    [[ "$CODE_EXIT_MODE" == "global" ]] || fail "exit mode"
    [[ "$CODE_IX_WG_PUBKEY" == "BPUB" ]] || fail "ix pubkey"
    # 旧 schema-5 transit 码仍可解析（向后兼容）
    seed_transit; load_profile ix-nat
    parse_code "$(generate_code)"
    [[ "$CODE_KIND" == "transit" ]] || fail "transit kind regressed"
    echo "CODE6 OK"
}

test_swgp() {
    local s c
    s="$(render_swgp_conf server 18443 127.0.0.1:51820 zero-overhead-2026 PSKBASE64)"
    grep -q '"proxyListen": ":18443"' <<<"$s" || fail "swgp server proxyListen"
    grep -q '"proxyMode": "zero-overhead-2026"' <<<"$s" || fail "swgp server mode"
    grep -q '"wgEndpoint": "127.0.0.1:51820"' <<<"$s" || fail "swgp server wgEndpoint"
    grep -q '"proxyPSK": "PSKBASE64"' <<<"$s" || fail "swgp server psk"
    c="$(render_swgp_conf client 18444 1.2.3.4:18443 zero-overhead-2026 PSKBASE64)"
    grep -q '"wgListen": ":18444"' <<<"$c" || fail "swgp client wgListen"
    grep -q '"proxyEndpoint": "1.2.3.4:18443"' <<<"$c" || fail "swgp client proxyEndpoint"
    echo "SWGP OK"
}

test_obfs() {
    seed_exit; load_profile ex
    # exit + swgp+mimic → mimic filter 对准 SWGP_PORT(18443)
    local m; m="$(render_mimic_conf_for_profile)"
    grep -q 'local=' <<<"$m" || fail "exit mimic local: $m"
    grep -q ':18443' <<<"$m" || fail "exit mimic wire port: $m"
    # relay：swgp 时 WG endpoint 拨本机 swgp，mimic remote 对准 B:SWGP_PORT
    write_profile_kv "$(profile_env_path rl)" \
        "PROFILE_ID=rl" "ROLE=relay" "ENABLED=true" "WAN_IFACE=eth0" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=1.2.3.4" \
        "WG_PRIVATE_KEY=k" "WG_PUBLIC_KEY=p" "WG_PEER_PUBLIC_KEY=BPUB" \
        "OBFS_MODE=swgp+mimic" "SWGP_MODE=zero-overhead-2026" "SWGP_PSK=x" "SWGP_PORT=18443"
    load_profile rl
    local w; w="$(render_wg_conf)"
    grep -q 'Endpoint = 127.0.0.1:18443' <<<"$w" || fail "relay swgp endpoint: $w"
    grep -qF 'relay rl' <<<"$w" || fail "relay header"
    local mr; mr="$(render_mimic_conf_for_profile)"
    grep -q 'remote=1.2.3.4:18443' <<<"$mr" || fail "relay mimic remote: $mr"
    echo "OBFS OK"
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
    swgp) test_swgp ;;
    code6) test_code6 ;;
    obfs) test_obfs ;;
    nopy) test_rule; test_wgconf; test_nft; test_ipv6; test_group; test_pool; test_mimic; test_iface; test_obfs; echo "NOPY OK" ;;
    all) test_rule; test_code; test_code6; test_swgp; test_obfs; test_wgconf; test_nft; test_ipv6; test_group; test_pool; test_mimic; test_iface; echo "ALL OK" ;;
    *) echo "usage: smoke.sh [rule|code|code6|swgp|obfs|wgconf|nft|ipv6|group|pool|mimic|iface|nopy|all]"; exit 1 ;;
esac
