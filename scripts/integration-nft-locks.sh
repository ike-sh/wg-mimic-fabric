#!/usr/bin/env bash
# Real systemd + nft integration; root required. All units/configs are temporary,
# all nft commands run in a private network namespace, wg-quick is a stub.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "$(id -u)" == 0 ]] || { echo 'Requires root' >&2; exit 77; }
for cmd in nft systemctl systemd-analyze unshare nsenter flock timeout; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 77; }
done
systemctl show --property=Version --value >/dev/null \
    || { echo 'Requires a running systemd manager' >&2; exit 77; }

sandbox="$(mktemp -d /run/wmf-issue1.XXXXXX)"
prefix="wmf-issue1-${BASHPID}"
namespace_pid=""
nft_unit="${prefix}-nft.service"
tunnel_one="${prefix}-tunnel@one.service"
tunnel_two="${prefix}-tunnel@two.service"
resume_unit="${prefix}-resume.service"
nft_bin="$(command -v nft)"

cleanup() {
    local rc=$?
    trap - EXIT
    systemctl disable --now "$resume_unit" "$tunnel_one" "$tunnel_two" "$nft_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$resume_unit" "$tunnel_one" "$tunnel_two" "$nft_unit" >/dev/null 2>&1 || true
    rm -rf /run/systemd/system/"${prefix}"-*
    systemctl daemon-reload
    if [[ -n "$namespace_pid" ]]; then
        kill "$namespace_pid" 2>/dev/null || true
        wait "$namespace_pid" 2>/dev/null || true
    fi
    rm -rf "$sandbox"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_active() {
    local unit
    for unit in "$@"; do
        systemctl is-active --quiet "$unit" || { echo "Inactive unit: $unit" >&2; return 1; }
    done
}

# Holding this process keeps its network namespace available to systemd units.
unshare --net sleep infinity &
namespace_pid=$!
for ((i=0; i<100; i++)); do
    if [[ -e "/proc/$namespace_pid/ns/net" ]] \
        && [[ "$(readlink "/proc/$namespace_pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]]; then break; fi
    sleep 0.02
done
netns="/proc/$namespace_pid/ns/net"
[[ -e "$netns" && "$(readlink "$netns")" != "$(readlink /proc/self/ns/net)" ]] \
    || { echo 'Could not create a private network namespace' >&2; exit 77; }

install -d "$sandbox/bin" "$sandbox/etc/profiles" "$sandbox/etc/state" "$sandbox/etc/codes" \
    "$sandbox/nft" "$sandbox/mimic" "$sandbox/wireguard" "$sandbox/tmp"

# Only unit names are substituted. The real dispatcher, locks, transactions,
# generated units, drop-ins and lifecycle functions are executed unchanged.
sed -e "s/wg-mimic-nft/${prefix}-nft/g" \
    -e "s/wg-mimic-tunnel@/${prefix}-tunnel@/g" \
    -e "s/wg-mimic-mimic@/${prefix}-mimic@/g" \
    -e "s/wg-mimic-offload@/${prefix}-offload@/g" \
    -e "s/wg-mimic-resume/${prefix}-resume/g" "$HERE/../install.sh" >"$sandbox/install.sh"

{
    printf 'SANDBOX=%q\nPREFIX=%q\nNETNS=%q\nNFT_BIN=%q\n' "$sandbox" "$prefix" "$netns" "$nft_bin"
    cat <<'SETUP'
export SANDBOX NETNS NFT_BIN
export PATH="$SANDBOX/bin:$PATH" TMPDIR="$SANDBOX/tmp"
CONFIG_DIR="$SANDBOX/etc"
PROFILES_DIR="$CONFIG_DIR/profiles"
STATE_DIR="$CONFIG_DIR/state"
CODES_DIR="$CONFIG_DIR/codes"
RESUME_MARKER="$STATE_DIR/resume.cmd"
NFT_DIR="$SANDBOX/nft"
NFT_FILE="$NFT_DIR/wg-mimic-fabric.nft"
STATE_LOCK_FILE="$SANDBOX/state.lock"
NFT_LOCK_FILE="$SANDBOX/nft.lock"
MIMIC_CONF_DIR="$SANDBOX/mimic"
WG_CONF_DIR="$SANDBOX/wireguard"
WM_BIN="$SANDBOX/wm"
SYSTEMD_MIMIC_TEMPLATE="/run/systemd/system/$PREFIX-mimic@.service"
SYSTEMD_TUNNEL_TEMPLATE="/run/systemd/system/$PREFIX-tunnel@.service"
SYSTEMD_OFFLOAD_TEMPLATE="/run/systemd/system/$PREFIX-offload@.service"
SYSTEMD_NFT_SERVICE="/run/systemd/system/$PREFIX-nft.service"
SYSTEMD_RESUME_SERVICE="/run/systemd/system/$PREFIX-resume.service"
SYSTEMD_DROPIN_ROOT=/run/systemd/system
# These tests exercise startup ordering without changing host sysctls, modules
# or interfaces. The kernel nft implementation itself remains real.
ensure_ip_forward() { :; }
modprobe() { :; }
SETUP
} >"$sandbox/setup.sh"
{
    printf '#!/usr/bin/env bash\nexport WMF_SOURCED=1\n'
    printf 'source %q\nsource %q\n' "$sandbox/install.sh" "$sandbox/setup.sh"
    printf 'main "$@"\n'
} >"$sandbox/wm"
cat >"$sandbox/bin/nft" <<'NFT'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == -f && -e "$SANDBOX/fail-load" ]]; then
    invalid="$(mktemp)"
    trap 'rm -f "$invalid"' EXIT
    cat "$2" >"$invalid"
    printf 'add rule inet wmf_nonexistent_table nonexistent_chain counter\n' >>"$invalid"
    nsenter --net="$NETNS" "$NFT_BIN" -f "$invalid"
else
    exec nsenter --net="$NETNS" "$NFT_BIN" "$@"
fi
NFT
cat >"$sandbox/bin/wg-quick" <<'WG'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == up ]]; then
    test -s "$2"
    nft list table inet wg_mimic_fabric >/dev/null
fi
WG
# The service stub also needs the namespace variables outside the wm process.
{
    printf '#!/usr/bin/env bash\n'
    printf 'source %q\n' "$sandbox/setup.sh"
    tail -n +2 "$sandbox/bin/wg-quick"
} >"$sandbox/bin/wg-quick.ready"
mv "$sandbox/bin/wg-quick.ready" "$sandbox/bin/wg-quick"
chmod 755 "$sandbox/wm" "$sandbox/bin/nft" "$sandbox/bin/wg-quick"

export WMF_SOURCED=1
unset WMF_LOCK_HELD
# shellcheck disable=SC1091
source "$sandbox/install.sh"
# shellcheck disable=SC1091
source "$sandbox/setup.sh"

for profile in one two; do
    write_profile_kv "$(profile_env_path "$profile")" \
        "PROFILE_ID=$profile" "ROLE=exit" "ENABLED=false" "OBFS_MODE=direct" "WAN_IFACE=lo" \
        "WG_MESH_SUBNET=10.88.0.0/24" "WG_IX_IP=10.88.0.2" "WG_INGRESS_IP=10.88.0.1" \
        "WG_PORT=51820" "WG_MTU=1420" "IX_ENDPOINT_HOST=203.0.113.1" \
        "WG_PRIVATE_KEY=TEST_ONLY" "WG_PEER_PUBLIC_KEY=TEST_ONLY"
done
install_systemd_units
systemd-analyze verify "$SYSTEMD_NFT_SERVICE" "$SYSTEMD_TUNNEL_TEMPLATE"

# Regression: systemd is a genuinely independent manager, with no state-lock
# descriptor or WMF_LOCK_HELD marker inherited from the wm command.
(
    exec 9>"$STATE_LOCK_FILE"
    flock -x 9
    timeout 10 systemctl start "$nft_unit"
)
systemctl is-active --quiet "$nft_unit"
systemctl stop "$nft_unit"
timeout 20 "$WM_BIN" start one
timeout 20 "$WM_BIN" restart one
timeout 20 "$WM_BIN" start two
assert_active "$nft_unit" "$tunnel_one" "$tunnel_two"
echo 'REAL SYSTEMD FIRST START/RESTART/MULTI-PROFILE OK'

# Exercise a real failed dependency, ENABLED rollback, then retry without
# reset-failed after removing only our temporary fault injection.
systemctl stop "$nft_unit"
set_profile_enabled_value "$(profile_env_path one)" false
install -d "/run/systemd/system/$nft_unit.d"
printf '[Service]\nExecStart=\nExecStart=/bin/false\n' >"/run/systemd/system/$nft_unit.d/90-test.conf"
systemctl daemon-reload
if timeout 20 "$WM_BIN" start one; then echo 'Failed dependency unexpectedly started tunnel' >&2; exit 1; fi
systemctl is-failed --quiet "$nft_unit"
! systemctl is-active --quiet "$tunnel_one"
grep -qx 'ENABLED=false' "$(profile_env_path one)"
rm "/run/systemd/system/$nft_unit.d/90-test.conf"
systemctl daemon-reload
timeout 20 "$WM_BIN" start one
assert_active "$nft_unit" "$tunnel_one"
echo 'REAL SYSTEMD FAILED DEPENDENCY/ROLLBACK/RETRY OK'

systemctl stop "$nft_unit"
install_resume_unit 'start two'
timeout 20 systemctl start "$resume_unit"
test ! -e "$RESUME_MARKER"
test ! -e "$SYSTEMD_RESUME_SERVICE"
assert_active "$nft_unit" "$tunnel_two"
echo 'REAL SYSTEMD RESUME OK (NO REBOOT)'

cp "$NFT_FILE" "$sandbox/old.nft"
nft list table inet "$NFT_TABLE" >"$sandbox/old-live.nft"
set_or_append_kv "$(profile_env_path one)" WG_PORT not_a_valid_service
if timeout 10 "$WM_BIN" apply-nft-all --internal; then echo 'Invalid nft precheck succeeded' >&2; exit 1; fi
cmp "$NFT_FILE" "$sandbox/old.nft"
nft list table inet "$NFT_TABLE" >"$sandbox/live.nft"
cmp "$sandbox/live.nft" "$sandbox/old-live.nft"
set_or_append_kv "$(profile_env_path one)" WG_PORT 51999
: >"$sandbox/fail-load"
if timeout 10 "$WM_BIN" apply-nft-all --internal; then echo 'Invalid nft transaction committed' >&2; exit 1; fi
cmp "$NFT_FILE" "$sandbox/old.nft"
nft list table inet "$NFT_TABLE" >"$sandbox/live.nft"
cmp "$sandbox/live.nft" "$sandbox/old-live.nft"
rm "$sandbox/fail-load"
timeout 10 "$WM_BIN" apply-nft-all --internal &
first=$!
timeout 10 "$WM_BIN" apply-nft-all --internal &
second=$!
wait "$first"
wait "$second"
! compgen -G "$NFT_DIR/.wg-mimic-fabric.*" >/dev/null
echo 'REAL NFT PRECHECK/TRANSACTION ROLLBACK/CONCURRENCY OK'
echo 'SYSTEMD/NFT INTEGRATION OK'
