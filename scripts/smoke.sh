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

case "${1:-all}" in
    rule) test_rule ;;
    code) test_code ;;
    wgconf) test_wgconf ;;
    nft) test_nft ;;
    ipv6) test_ipv6 ;;
    group) test_group ;;
    nopy) test_rule; test_wgconf; test_nft; test_ipv6; test_group; echo "NOPY OK" ;;
    all) test_rule; test_code; test_wgconf; test_nft; test_ipv6; test_group; echo "ALL OK" ;;
    *) echo "usage: smoke.sh [rule|code|wgconf|nft|ipv6|group|nopy|all]"; exit 1 ;;
esac
