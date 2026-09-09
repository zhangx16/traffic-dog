#!/bin/sh
# Isolated regression tests: never invoke the host firewall or require root.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sed '$d' "$ROOT/port-traffic-stat.sh" > "$TEST_DIR/functions.sh"
PTS_CONFIG_DIR="$TEST_DIR/config"
export PTS_CONFIG_DIR
. "$TEST_DIR/functions.sh"
need_root() { :; }
need_nft() { :; }
with_lock() { :; }
nft() { return 0; }
counter_bytes() {
    if [ -f "$TEST_DIR/rebuilt" ]; then echo 0; else echo 10; fi
}
quota_used_bytes() { echo 120; }
rebuild_nft_rules() { touch "$TEST_DIR/rebuilt"; }
fixture() {
    ensure_files
    printf '80\n443\n' > "$PORTS_FILE"
    printf '80 100 200 original\n443 300 400 original\n' > "$STATE_FILE"
    printf '80 1000\n443 2000\n' > "$LIMITS_FILE"
    printf '80 300\n443 700\n' > "$USED_FILE"
    rm -f "$TEST_DIR/rebuilt"
}
assert_line() {
    grep -qxF "$2" "$1" || { echo "FAIL: missing '$2' in $1" >&2; exit 1; }
}
for operation in reset resume; do
    fixture
    "cmd_$operation" 80
    assert_line "$STATE_FILE" '443 310 410 original'
    [ "$(port_saved_total 80)" = 0 ]
    assert_line "$USED_FILE" '443 720'
    echo "PASS: $operation preserves other ports"

    fixture
    cp "$STATE_FILE" "$TEST_DIR/before"
    if ( "cmd_$operation" 80 9999 ) 2>/dev/null; then exit 1; fi
    cmp "$STATE_FILE" "$TEST_DIR/before"
    [ ! -f "$TEST_DIR/rebuilt" ]
    echo "PASS: $operation validates every target before modifying state"
done
fixture
cmd_restore
assert_line "$STATE_FILE" '80 110 210 original'
cmd_restore
assert_line "$STATE_FILE" '80 110 210 original'
echo 'PASS: repeated restore preserves counts without double counting'

fixture
cmd_del 80
[ "$(cat "$PORTS_FILE")" = 443 ]
assert_line "$LIMITS_FILE" '443 2000'
assert_line "$STATE_FILE" '443 310 410 original'
assert_line "$USED_FILE" '443 720'
! grep -q '^80 ' "$STATE_FILE"
echo 'PASS: deleting a port preserves the remaining configuration'

for operation in 'cmd_add' 'cmd_del' 'cmd_unlimit'; do
    fixture
    cp "$STATE_FILE" "$TEST_DIR/before"
    if ( "$operation" invalid 80 ) 2>/dev/null; then exit 1; fi
    cmp "$STATE_FILE" "$TEST_DIR/before"
    [ ! -f "$TEST_DIR/rebuilt" ]
    echo "PASS: $operation rejects invalid arguments before saving"
done
if (cmd_watch 0) 2>/dev/null; then exit 1; fi
echo 'PASS: watch rejects zero interval'
echo 'All regression tests passed.'
