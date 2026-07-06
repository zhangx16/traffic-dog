#!/bin/sh
# port-traffic-stat.sh
# Alpine/Debian-friendly nftables port traffic statistics with optional per-port quota blocking.

set -eu
set -f

VERSION="1.3.1"
FAMILY="inet"
TABLE="port_traffic_stat"
CONFIG_DIR="${PTS_CONFIG_DIR:-/etc/port-traffic-stat}"
PORTS_FILE="$CONFIG_DIR/ports"
STATE_FILE="$CONFIG_DIR/state"
LIMITS_FILE="$CONFIG_DIR/limits"
USED_FILE="$CONFIG_DIR/used"
LOCK_DIR="/tmp/port-traffic-stat.lock"
UPDATE_URL="${PTS_UPDATE_URL:-https://raw.githubusercontent.com/zhangx16/dog-alpine/main/port-traffic-stat.sh}"

umask 022

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" = "0" ] || die "please run as root"
}

need_nft() {
    command -v nft >/dev/null 2>&1 || die "nft not found, run: $0 install-deps"
}

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

with_lock() {
    i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "failed to acquire lock: $LOCK_DIR"
        sleep 1
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

ensure_files() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$PORTS_FILE" ] || : > "$PORTS_FILE"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    [ -f "$LIMITS_FILE" ] || : > "$LIMITS_FILE"
    [ -f "$USED_FILE" ] || : > "$USED_FILE"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

strip_leading_zero() {
    n=$(printf '%s' "$1" | sed 's/^0*//')
    [ -n "$n" ] || n=0
    printf '%s\n' "$n"
}

validate_port_part() {
    is_uint "$1" || return 1
    n=$(strip_leading_zero "$1")
    [ "$n" -ge 1 ] && [ "$n" -le 65535 ]
}

normalize_port_spec() {
    raw=$(printf '%s' "$1" | tr -d '[:space:]')
    [ -n "$raw" ] || return 1

    case "$raw" in
        *-*)
            start=${raw%-*}
            end=${raw#*-}
            validate_port_part "$start" || return 1
            validate_port_part "$end" || return 1
            start=$(strip_leading_zero "$start")
            end=$(strip_leading_zero "$end")
            [ "$start" -le "$end" ] || return 1
            printf '%s-%s\n' "$start" "$end"
            ;;
        *)
            validate_port_part "$raw" || return 1
            printf '%s\n' "$(strip_leading_zero "$raw")"
            ;;
    esac
}

split_port_args() {
    for arg in "$@"; do
        printf '%s\n' "$arg" | tr ',' '\n' | while IFS= read -r item; do
            [ -n "$item" ] || continue
            normalize_port_spec "$item" || die "invalid port: $item"
        done
    done
}

safe_name() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/_/g'
}

counter_in() {
    printf 'p_%s_in\n' "$(safe_name "$1")"
}

counter_out() {
    printf 'p_%s_out\n' "$(safe_name "$1")"
}

quota_name() {
    printf 'q_%s_total\n' "$(safe_name "$1")"
}

read_kv2() {
    file=$1
    key=$2
    if [ -f "$file" ]; then
        awk -v k="$key" '$1 == k { print $2; found=1; exit } END { if (!found) print "" }' "$file"
    else
        echo ""
    fi
}

set_kv2() {
    file=$1
    key=$2
    val=$3
    [ -n "$key" ] || die "internal error: empty key for $file"
    tmp="$file.$$"
    [ -f "$file" ] || : > "$file"
    awk -v k="$key" 'NF >= 2 && $1 != k { print }' "$file" > "$tmp"
    printf '%s %s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$file"
}

remove_kv2() {
    file=$1
    key=$2
    tmp="$file.$$"
    [ -f "$file" ] || return 0
    awk -v k="$key" 'NF >= 2 && $1 != k { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
}

limit_get_bytes() {
    read_kv2 "$LIMITS_FILE" "$1"
}

limit_set_bytes() {
    set_kv2 "$LIMITS_FILE" "$1" "$2"
}

limit_remove() {
    remove_kv2 "$LIMITS_FILE" "$1"
    remove_kv2 "$USED_FILE" "$1"
}

used_get_bytes() {
    read_kv2 "$USED_FILE" "$1"
}

used_set_bytes() {
    set_kv2 "$USED_FILE" "$1" "$2"
}

used_remove() {
    remove_kv2 "$USED_FILE" "$1"
}

parse_size_to_bytes() {
    val=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    [ -n "$val" ] || return 1
    awk -v s="$val" '
    BEGIN {
        if (s !~ /^[0-9]+([.][0-9]+)?(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB|P|PB|PIB)?$/) exit 1
        num=s
        sub(/[A-Z]+$/, "", num)
        unit=s
        sub(/^[0-9.]+/, "", unit)
        mult=1
        if (unit=="K" || unit=="KB" || unit=="KIB") mult=1024
        else if (unit=="M" || unit=="MB" || unit=="MIB") mult=1024*1024
        else if (unit=="G" || unit=="GB" || unit=="GIB") mult=1024*1024*1024
        else if (unit=="T" || unit=="TB" || unit=="TIB") mult=1024*1024*1024*1024
        else if (unit=="P" || unit=="PB" || unit=="PIB") mult=1024*1024*1024*1024*1024
        bytes=num*mult
        if (bytes < 1) exit 1
        printf "%.0f\n", bytes
    }'
}

human_bytes() {
    awk -v b="${1:-0}" '
    function human(x, unit, i) {
        split("B KB MB GB TB PB EB", unit, " ")
        i=1
        while (x >= 1024 && i < 7) { x = x / 1024; i++ }
        if (i == 1) printf "%.0f%s", x, unit[i]
        else printf "%.2f%s", x, unit[i]
    }
    BEGIN { human(b) }'
}

add_table_and_chains() {
    nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1 || nft add table "$FAMILY" "$TABLE"
    nft list chain "$FAMILY" "$TABLE" input >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" input "{ type filter hook input priority 0; policy accept; }"
    nft list chain "$FAMILY" "$TABLE" output >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" output "{ type filter hook output priority 0; policy accept; }"
    nft list chain "$FAMILY" "$TABLE" forward >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" forward "{ type filter hook forward priority 0; policy accept; }"
}

read_state_line() {
    port=$1
    if [ -f "$STATE_FILE" ]; then
        awk -v p="$port" '$1 == p { print $2, $3, $4; found=1; exit } END { if (!found) print "0 0 -" }' "$STATE_FILE"
    else
        echo "0 0 -"
    fi
}

set_state_line() {
    port=$1
    inb=$2
    outb=$3
    reset_at=$4
    tmp="$STATE_FILE.$$"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
    awk -v p="$port" '$1 != p { print }' "$STATE_FILE" > "$tmp"
    printf '%s %s %s %s\n' "$port" "$inb" "$outb" "$reset_at" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

remove_state_line() {
    port=$1
    tmp="$STATE_FILE.$$"
    [ -f "$STATE_FILE" ] || return 0
    awk -v p="$port" '$1 != p { print }' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

counter_bytes() {
    c=$1
    nft list counter "$FAMILY" "$TABLE" "$c" 2>/dev/null | \
        awk '{ for (i=1; i<=NF; i++) if ($i == "bytes") { print $(i+1); found=1; exit } } END { if (!found) print 0 }'
}

quota_used_bytes() {
    q=$1
    nft list quota "$FAMILY" "$TABLE" "$q" 2>/dev/null | awk '
    function mult(u) {
        if (u == "bytes") return 1
        if (u == "kbytes") return 1024
        if (u == "mbytes") return 1024*1024
        if (u == "gbytes") return 1024*1024*1024
        return 1
    }
    {
        for (i=1; i<=NF; i++) {
            if ($i == "used") {
                printf "%.0f\n", ($(i+1) * mult($(i+2)))
                found=1
                exit
            }
        }
    }
    END { if (!found) print "" }'
}

port_delta_bytes() {
    p=$1
    cin=$(counter_in "$p")
    cout=$(counter_out "$p")
    in_delta=$(counter_bytes "$cin")
    out_delta=$(counter_bytes "$cout")
    echo "$in_delta $out_delta"
}

port_state_total() {
    p=$1
    set -- $(read_state_line "$p")
    base_in=${1:-0}
    base_out=${2:-0}
    set -- $(port_delta_bytes "$p")
    delta_in=${1:-0}
    delta_out=${2:-0}
    echo "$((base_in + delta_in + base_out + delta_out))"
}

port_saved_total() {
    p=$1
    set -- $(read_state_line "$p")
    base_in=${1:-0}
    base_out=${2:-0}
    echo "$((base_in + base_out))"
}

port_quota_used_live_or_saved() {
    p=$1
    q=$(quota_name "$p")
    live=$(quota_used_bytes "$q")
    if [ -n "$live" ]; then
        echo "$live"
        return 0
    fi
    saved=$(used_get_bytes "$p")
    if [ -n "$saved" ]; then
        echo "$saved"
        return 0
    fi
    port_state_total "$p"
}

port_effective_used() {
    p=$1
    total=$(port_state_total "$p")
    used=$(port_quota_used_live_or_saved "$p")
    if [ -n "$used" ] && [ "$used" -gt "$total" ]; then
        echo "$used"
    else
        echo "$total"
    fi
}

add_quota_for_port() {
    p=$1
    limit=$(limit_get_bytes "$p")
    [ -n "$limit" ] || return 0

    q=$(quota_name "$p")
    used=$(used_get_bytes "$p")
    if [ -z "$used" ]; then
        set -- $(read_state_line "$p")
        used=$((${1:-0} + ${2:-0}))
    fi

    nft add quota "$FAMILY" "$TABLE" "$q" "{ over $limit bytes used $used bytes; }"
}

add_limit_drop_rules_for_port() {
    p=$1
    limit=$(limit_get_bytes "$p")
    [ -n "$limit" ] || return 0

    q=$(quota_name "$p")
    for proto in tcp udp; do
        nft add rule "$FAMILY" "$TABLE" input "$proto" dport "$p" quota name "$q" drop
        nft add rule "$FAMILY" "$TABLE" forward "$proto" dport "$p" quota name "$q" drop
        nft add rule "$FAMILY" "$TABLE" output "$proto" sport "$p" quota name "$q" drop
        nft add rule "$FAMILY" "$TABLE" forward "$proto" sport "$p" quota name "$q" drop
    done
}

add_count_rules_for_port() {
    p=$1
    cin=$(counter_in "$p")
    cout=$(counter_out "$p")

    nft add counter "$FAMILY" "$TABLE" "$cin" >/dev/null 2>&1 || true
    nft add counter "$FAMILY" "$TABLE" "$cout" >/dev/null 2>&1 || true

    for proto in tcp udp; do
        nft add rule "$FAMILY" "$TABLE" input "$proto" dport "$p" counter name "$cin"
        nft add rule "$FAMILY" "$TABLE" forward "$proto" dport "$p" counter name "$cin"
        nft add rule "$FAMILY" "$TABLE" output "$proto" sport "$p" counter name "$cout"
        nft add rule "$FAMILY" "$TABLE" forward "$proto" sport "$p" counter name "$cout"
    done
}

add_rules_for_port() {
    p=$1
    add_quota_for_port "$p"
    add_limit_drop_rules_for_port "$p"
    add_count_rules_for_port "$p"
}

save_port_snapshot() {
    p=$1
    set -- $(read_state_line "$p")
    base_in=${1:-0}
    base_out=${2:-0}
    reset_at=${3:--}
    [ "$reset_at" = "-" ] && reset_at=$(now_iso)

    set -- $(port_delta_bytes "$p")
    delta_in=${1:-0}
    delta_out=${2:-0}

    total_in=$((base_in + delta_in))
    total_out=$((base_out + delta_out))
    set_state_line "$p" "$total_in" "$total_out" "$reset_at"

    limit=$(limit_get_bytes "$p")
    if [ -n "$limit" ]; then
        q=$(quota_name "$p")
        q_used=$(quota_used_bytes "$q")
        split_total=$((total_in + total_out))
        if [ -n "$q_used" ] && [ "$q_used" -gt "$split_total" ]; then
            used_set_bytes "$p" "$q_used"
        else
            used_set_bytes "$p" "$split_total"
        fi
    else
        used_remove "$p"
    fi
}

save_all_snapshots() {
    ensure_files
    if nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1; then
        while IFS= read -r snapshot_port_name; do
            [ -n "$snapshot_port_name" ] || continue
            save_port_snapshot "$snapshot_port_name"
        done < "$PORTS_FILE"
    fi
}

rebuild_nft_rules() {
    need_root
    need_nft
    ensure_files

    nft delete table "$FAMILY" "$TABLE" >/dev/null 2>&1 || true
    add_table_and_chains

    while IFS= read -r rebuild_port_name; do
        [ -n "$rebuild_port_name" ] || continue
        add_rules_for_port "$rebuild_port_name"
    done < "$PORTS_FILE"
}

limit_state_for_port() {
    p=$1
    limit=$(limit_get_bytes "$p")
    if [ -z "$limit" ]; then
        echo "OPEN"
        return 0
    fi
    used=$(port_effective_used "$p")
    if [ "$used" -ge "$limit" ]; then
        echo "PAUSED"
    else
        echo "LIMITED"
    fi
}

print_status() {
    ensure_files
    need_nft

    if ! nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1; then
        echo "nftables rules are not loaded. Run: $0 restore"
        exit 1
    fi

    count=$(awk 'NF { n++ } END { print n+0 }' "$PORTS_FILE")
    [ "$count" -gt 0 ] || {
        echo "No ports. Example: $0 add 80 443"
        return 0
    }

    printf '%-16s %14s %14s %14s %14s  %-8s %s\n' "PORT" "IN" "OUT" "TOTAL" "LIMIT" "STATE" "RESET_AT"
    printf '%-16s %14s %14s %14s %14s  %-8s %s\n' "----------------" "--------------" "--------------" "--------------" "--------------" "--------" "------------------------"

    grand_in=0
    grand_out=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        set -- $(read_state_line "$p")
        base_in=${1:-0}
        base_out=${2:-0}
        reset_at=${3:--}

        set -- $(port_delta_bytes "$p")
        delta_in=${1:-0}
        delta_out=${2:-0}

        inb=$((base_in + delta_in))
        outb=$((base_out + delta_out))
        total=$((inb + outb))
        grand_in=$((grand_in + inb))
        grand_out=$((grand_out + outb))

        limit=$(limit_get_bytes "$p")
        if [ -n "$limit" ]; then
            limit_text=$(human_bytes "$limit")
            state=$(limit_state_for_port "$p")
        else
            limit_text="-"
            state="OPEN"
        fi

        printf '%-16s %14s %14s %14s %14s  %-8s %s\n' \
            "$p" "$(human_bytes "$inb")" "$(human_bytes "$outb")" "$(human_bytes "$total")" "$limit_text" "$state" "$reset_at"
    done < "$PORTS_FILE"

    grand_total=$((grand_in + grand_out))
    printf '%-16s %14s %14s %14s\n' \
        "TOTAL" "$(human_bytes "$grand_in")" "$(human_bytes "$grand_out")" "$(human_bytes "$grand_total")"
}

cmd_add() {
    [ "$#" -ge 1 ] || die "usage: $0 add 80 443 10000-10100"
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots

    ports_list=$(split_port_args "$@")
    for p in $ports_list; do
        if grep -qxF "$p" "$PORTS_FILE" 2>/dev/null; then
            echo "exists: $p"
        else
            printf '%s\n' "$p" >> "$PORTS_FILE"
            set_state_line "$p" 0 0 "$(now_iso)"
            echo "added: $p"
        fi
    done

    sort_tmp="$PORTS_FILE.sort.$$"
    sort -u "$PORTS_FILE" > "$sort_tmp"
    mv "$sort_tmp" "$PORTS_FILE"
    rebuild_nft_rules
    echo "rules loaded. View: $0 status"
}

cmd_del() {
    [ "$#" -ge 1 ] || die "usage: $0 del 80 443"
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots

    tmp="$PORTS_FILE.$$"
    cp "$PORTS_FILE" "$tmp"

    ports_list=$(split_port_args "$@")
    for p in $ports_list; do
        if grep -qxF "$p" "$tmp" 2>/dev/null; then
            awk -v x="$p" '$1 != x { print }' "$tmp" > "$tmp.new"
            mv "$tmp.new" "$tmp"
            remove_state_line "$p"
            limit_remove "$p"
            echo "deleted: $p"
        else
            echo "not found: $p"
        fi
    done

    mv "$tmp" "$PORTS_FILE"
    rebuild_nft_rules
}

cmd_limit() {
    sub=${1:-list}

    case "$sub" in
        list|show)
            ensure_files
            if [ ! -s "$LIMITS_FILE" ]; then
                echo "No limits. Example: $0 limit 80 10G"
                return 0
            fi
            printf '%-16s %14s %14s %-8s\n' "PORT" "USED" "LIMIT" "STATE"
            printf '%-16s %14s %14s %-8s\n' "----------------" "--------------" "--------------" "--------"
            while read -r p limit; do
                [ -n "${p:-}" ] || continue
                used=$(port_effective_used "$p" 2>/dev/null || used_get_bytes "$p")
                [ -n "$used" ] || used=0
                state=$(limit_state_for_port "$p" 2>/dev/null || echo "LIMITED")
                printf '%-16s %14s %14s %-8s\n' "$p" "$(human_bytes "$used")" "$(human_bytes "$limit")" "$state"
            done < "$LIMITS_FILE"
            ;;
        set)
            shift
            [ "$#" -eq 2 ] || die "usage: $0 limit set PORT SIZE"
            cmd_limit "$@"
            ;;
        del|delete|remove|off|unset)
            shift
            [ "$#" -ge 1 ] || die "usage: $0 limit del PORT [PORT...]"
            need_root
            need_nft
            with_lock
            ensure_files
            save_all_snapshots
            ports_list=$(split_port_args "$@")
            for p in $ports_list; do
                limit_remove "$p"
                echo "limit removed: $p"
            done
            rebuild_nft_rules
            ;;
        *)
            [ "$#" -eq 2 ] || die "usage: $0 limit PORT SIZE | $0 limit del PORT | $0 limit list"
            limit_port=$(normalize_port_spec "$1") || die "invalid port: $1"
            [ -n "$limit_port" ] || die "invalid port: $1"
            limit_size=$(parse_size_to_bytes "$2") || die "invalid size: $2 (examples: 500M, 10G, 1T)"
            need_root
            need_nft
            with_lock
            ensure_files
            if ! grep -qxF "$limit_port" "$PORTS_FILE" 2>/dev/null; then
                printf '%s\n' "$limit_port" >> "$PORTS_FILE"
                set_state_line "$limit_port" 0 0 "$(now_iso)"
                sort_tmp="$PORTS_FILE.sort.$$"
                sort -u "$PORTS_FILE" > "$sort_tmp"
                mv "$sort_tmp" "$PORTS_FILE"
                echo "added: $limit_port"
            fi
            save_all_snapshots
            limit_used=$(port_saved_total "$limit_port")
            limit_saved_used=$(used_get_bytes "$limit_port")
            if [ -n "$limit_saved_used" ] && [ "$limit_saved_used" -gt "$limit_used" ]; then
                limit_used=$limit_saved_used
            fi
            limit_set_bytes "$limit_port" "$limit_size"
            used_set_bytes "$limit_port" "$limit_used"
            rebuild_nft_rules
            echo "limit set: $limit_port => $(human_bytes "$limit_size")"
            if [ "$limit_used" -ge "$limit_size" ]; then
                echo "current usage is already over limit; port is paused now."
            fi
            ;;
    esac
}

cmd_unlimit() {
    [ "$#" -ge 1 ] || die "usage: $0 unlimit PORT [PORT...]"
    cmd_limit del "$@"
}

cmd_resume() {
    target=${1:-all}
    need_root
    need_nft
    with_lock
    ensure_files

    if [ "$target" = "all" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            set_state_line "$p" 0 0 "$(now_iso)"
            used_set_bytes "$p" 0
        done < "$PORTS_FILE"
        rebuild_nft_rules
        echo "resumed all limited ports; usage has been reset."
        return 0
    fi

    ports_list=$(split_port_args "$@")
    for p in $ports_list; do
        grep -qxF "$p" "$PORTS_FILE" 2>/dev/null || die "port not added: $p"
        set_state_line "$p" 0 0 "$(now_iso)"
        used_set_bytes "$p" 0
        echo "resumed: $p"
    done
    rebuild_nft_rules
}

cmd_reset() {
    target=${1:-all}
    need_root
    need_nft
    with_lock
    ensure_files

    if [ "$target" = "all" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            set_state_line "$p" 0 0 "$(now_iso)"
            used_set_bytes "$p" 0
        done < "$PORTS_FILE"
        rebuild_nft_rules
        echo "reset all stats."
        return 0
    fi

    ports_list=$(split_port_args "$@")
    for p in $ports_list; do
        grep -qxF "$p" "$PORTS_FILE" 2>/dev/null || die "port not added: $p"
        set_state_line "$p" 0 0 "$(now_iso)"
        used_set_bytes "$p" 0
        echo "reset: $p"
    done
    rebuild_nft_rules
}

cmd_restore() {
    need_root
    need_nft
    with_lock
    ensure_files
    rebuild_nft_rules
    echo "restored nftables rules."
}

cmd_save() {
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots
    rebuild_nft_rules
    echo "saved current counters to: $STATE_FILE"
}

cmd_flush() {
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots
    nft delete table "$FAMILY" "$TABLE" >/dev/null 2>&1 || true
    echo "flushed nftables rules; historical stats saved."
}

cmd_watch() {
    interval=${1:-2}
    case "$interval" in
        ''|*[!0-9]*) die "interval must be seconds" ;;
    esac
    while :; do
        clear 2>/dev/null || true
        date
        print_status
        sleep "$interval"
    done
}

cmd_install_deps() {
    need_root
    if command -v nft >/dev/null 2>&1; then
        echo "nftables is installed: $(command -v nft)"
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache nftables ca-certificates curl
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables ca-certificates curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nftables ca-certificates curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nftables ca-certificates curl
    else
        die "unknown package manager, please install nftables manually"
    fi
}

cmd_install() {
    need_root
    dest="/usr/local/bin/port-traffic-stat"
    src=$0
    case "$src" in
        */*) ;;
        *) src=$(command -v "$0" 2>/dev/null || printf '%s\n' "$0") ;;
    esac
    if [ "$src" != "$dest" ]; then
        cp "$src" "$dest"
    fi
    chmod +x "$dest"
    ensure_files
    echo "installed to: $dest"
}

cmd_update() {
    need_root
    url=${1:-$UPDATE_URL}
    dest="/usr/local/bin/port-traffic-stat"
    tmp="${TMPDIR:-/tmp}/port-traffic-stat.update.$$"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url?ts=$(date +%s)" -o "$tmp"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$url?ts=$(date +%s)"
    else
        die "curl/wget not found, run: $0 install-deps"
    fi

    /bin/sh -n "$tmp" || die "downloaded script syntax check failed"
    cp "$tmp" "$dest"
    chmod +x "$dest"
    echo "updated: $dest"
    "$dest" version 2>/dev/null || true
}

cmd_install_service() {
    need_root
    [ -x /usr/local/bin/port-traffic-stat ] || cmd_install

    if command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        cat > /etc/init.d/port-traffic-stat <<'EOF'
#!/sbin/openrc-run
description="Restore and save port traffic nftables counters and quotas"

start() {
    ebegin "Restoring port traffic stat rules"
    /usr/local/bin/port-traffic-stat restore >/dev/null 2>&1
    eend $?
}

stop() {
    ebegin "Saving port traffic stat counters"
    /usr/local/bin/port-traffic-stat save >/dev/null 2>&1
    eend $?
}
EOF
        chmod +x /etc/init.d/port-traffic-stat
        rc-update add port-traffic-stat default
        echo "OpenRC service installed: port-traffic-stat"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/port-traffic-stat.service <<'EOF'
[Unit]
Description=Restore and save port traffic nftables counters and quotas
Wants=network-pre.target
After=nftables.service network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/port-traffic-stat restore
ExecStop=/usr/local/bin/port-traffic-stat save

[Install]
WantedBy=multi-user.target
EOF
        if systemctl daemon-reload >/dev/null 2>&1; then
            systemctl enable port-traffic-stat.service >/dev/null 2>&1 || true
            echo "systemd service installed: port-traffic-stat.service"
            echo "start now: systemctl start port-traffic-stat"
        else
            echo "systemd service file written: /etc/systemd/system/port-traffic-stat.service"
            echo "systemctl is not available in this environment; enable it later with:"
            echo "  systemctl daemon-reload && systemctl enable --now port-traffic-stat"
        fi
        return 0
    fi

    if command -v update-rc.d >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        cat > /etc/init.d/port-traffic-stat <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          port-traffic-stat
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Restore and save port traffic nftables counters and quotas
### END INIT INFO

case "$1" in
    start)
        /usr/local/bin/port-traffic-stat restore >/dev/null 2>&1
        ;;
    stop)
        /usr/local/bin/port-traffic-stat save >/dev/null 2>&1
        ;;
    restart|reload|force-reload)
        /usr/local/bin/port-traffic-stat save >/dev/null 2>&1 || true
        /usr/local/bin/port-traffic-stat restore >/dev/null 2>&1
        ;;
    status)
        /usr/local/bin/port-traffic-stat status
        ;;
    *)
        echo "Usage: /etc/init.d/port-traffic-stat {start|stop|restart|reload|force-reload|status}"
        exit 1
        ;;
esac

exit $?
EOF
        chmod +x /etc/init.d/port-traffic-stat
        update-rc.d port-traffic-stat defaults >/dev/null 2>&1 || true
        echo "SysV init service installed: port-traffic-stat"
        return 0
    fi

    die "OpenRC/systemd/SysV init not found"
}

cmd_uninstall() {
    need_root
    cmd_flush || true
    if command -v rc-update >/dev/null 2>&1 && [ -f /etc/init.d/port-traffic-stat ]; then
        rc-update del port-traffic-stat default >/dev/null 2>&1 || true
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/port-traffic-stat.service ]; then
        systemctl disable port-traffic-stat.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/port-traffic-stat.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v update-rc.d >/dev/null 2>&1 && [ -f /etc/init.d/port-traffic-stat ]; then
        update-rc.d -f port-traffic-stat remove >/dev/null 2>&1 || true
    fi
    rm -f /etc/init.d/port-traffic-stat
    rm -f /usr/local/bin/port-traffic-stat
    echo "uninstalled program and startup service; data kept in: $CONFIG_DIR"
}

menu_pause() {
    printf '\nPress Enter to continue...'
    IFS= read -r menu_pause_input || true
}

menu_prompt() {
    printf '%s' "$1"
    IFS= read -r menu_answer || return 1
    menu_answer=$(printf '%s' "$menu_answer" | tr -d '\r')
    return 0
}

menu_run() {
    (
        "$@"
    )
    menu_rc=$?
    if [ "$menu_rc" -ne 0 ]; then
        echo "Command failed, exit code: $menu_rc"
    fi
}

menu_confirm() {
    menu_prompt "$1 [y/N]: " || return 1
    case "$menu_answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_menu() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        usage
        return 0
    fi

    while :; do
        if [ -t 1 ]; then
            clear 2>/dev/null || true
        fi
        cat <<EOF
port-traffic-stat v$VERSION

1) Add/Set ports              添加统计端口
2) Set port traffic limit     设置端口限额
3) Show status                查看状态
4) Show limits                查看限额
5) Delete ports               删除端口
6) Remove port limit          删除限额
7) Resume paused port         恢复端口流量
8) Reset statistics           清零统计
9) Restore nftables rules     恢复规则
10) Install dependencies      安装依赖
11) Install script            安装脚本
12) Install boot service      安装开机服务
13) Update script             更新脚本
14) Uninstall script/service  卸载脚本/服务
15) Watch status              实时查看状态
0) Exit                       退出

EOF
        menu_prompt "Select an option / 输入数字: " || exit 0
        case "$menu_answer" in
            1)
                menu_prompt "Ports, e.g. 80 443 10000-10100: " || continue
                [ -n "$menu_answer" ] || { echo "No ports entered."; menu_pause; continue; }
                menu_run cmd_add $menu_answer
                menu_pause
                ;;
            2)
                menu_prompt "Port, e.g. 44001: " || continue
                menu_port_input=$menu_answer
                [ -n "$menu_port_input" ] || { echo "No port entered."; menu_pause; continue; }
                menu_prompt "Limit, e.g. 100G / 500M / 1T: " || continue
                menu_limit_input=$menu_answer
                [ -n "$menu_limit_input" ] || { echo "No limit entered."; menu_pause; continue; }
                menu_run cmd_limit "$menu_port_input" "$menu_limit_input"
                menu_pause
                ;;
            3)
                menu_run print_status
                menu_pause
                ;;
            4)
                menu_run cmd_limit list
                menu_pause
                ;;
            5)
                menu_prompt "Ports to delete, e.g. 80 443: " || continue
                [ -n "$menu_answer" ] || { echo "No ports entered."; menu_pause; continue; }
                menu_run cmd_del $menu_answer
                menu_pause
                ;;
            6)
                menu_prompt "Ports to remove limit, e.g. 80 443: " || continue
                [ -n "$menu_answer" ] || { echo "No ports entered."; menu_pause; continue; }
                menu_run cmd_unlimit $menu_answer
                menu_pause
                ;;
            7)
                menu_prompt "Ports to resume, or all [all]: " || continue
                menu_resume_input=${menu_answer:-all}
                menu_run cmd_resume $menu_resume_input
                menu_pause
                ;;
            8)
                menu_prompt "Ports to reset, or all [all]: " || continue
                menu_reset_input=${menu_answer:-all}
                menu_run cmd_reset $menu_reset_input
                menu_pause
                ;;
            9)
                menu_run cmd_restore
                menu_pause
                ;;
            10)
                menu_run cmd_install_deps
                menu_pause
                ;;
            11)
                menu_run cmd_install
                menu_pause
                ;;
            12)
                menu_run cmd_install_service
                menu_pause
                ;;
            13)
                menu_run cmd_update
                menu_pause
                ;;
            14)
                if menu_confirm "Uninstall script and service?"; then
                    menu_run cmd_uninstall
                else
                    echo "Cancelled."
                fi
                menu_pause
                ;;
            15)
                menu_prompt "Refresh interval seconds [2]: " || continue
                menu_watch_interval=${menu_answer:-2}
                echo "Press Ctrl+C to stop watching."
                menu_run cmd_watch "$menu_watch_interval"
                menu_pause
                ;;
            0|q|Q|exit|quit)
                exit 0
                ;;
            h|H|help|-h|--help)
                usage
                menu_pause
                ;;
            *)
                echo "Invalid option: $menu_answer"
                menu_pause
                ;;
        esac
    done
}

usage() {
    cat <<EOF
port-traffic-stat v$VERSION

Supported systems:
  Alpine Linux with OpenRC
  Debian/Ubuntu with systemd or SysV init

Usage:
  $0                             Interactive menu
  $0 menu                        Interactive menu

  $0 install-deps
  $0 install
  $0 install-service
  $0 update

  $0 add 80 443 10000-10100
  $0 del 80
  $0 status
  $0 watch [seconds]
  $0 reset [PORT|all]

Traffic quota / auto pause:
  $0 limit PORT SIZE          Set total IN+OUT limit, auto drop traffic after reached
  $0 limit set PORT SIZE      Same as above
  $0 limit del PORT           Remove limit and resume unrestricted traffic
  $0 limit list               Show limits
  $0 unlimit PORT             Alias of limit del
  $0 resume PORT|all          Reset usage to 0 and resume traffic, keeping limits

Size examples:
  500M, 10G, 1T, 1073741824

Other:
  $0 save
  $0 restore
  $0 flush
  $0 uninstall

Examples:
  $0 add 80 443
  $0 limit 80 10G
  $0 status
  $0 resume 80
EOF
}

main() {
    if [ "$#" -gt 0 ]; then
        cmd=$1
        shift
    else
        if [ -t 0 ] && [ -t 1 ]; then
            cmd=menu
        else
            cmd=help
        fi
    fi

    case "$cmd" in
        menu|interactive|ui) cmd_menu ;;
        add) cmd_add "$@" ;;
        del|delete|remove) cmd_del "$@" ;;
        status|show|list) print_status ;;
        watch) cmd_watch "$@" ;;
        reset) cmd_reset "$@" ;;
        limit|quota) cmd_limit "$@" ;;
        unlimit) cmd_unlimit "$@" ;;
        resume|unpause) cmd_resume "$@" ;;
        save) cmd_save ;;
        restore|reload|init) cmd_restore ;;
        flush|stop) cmd_flush ;;
        install-deps) cmd_install_deps ;;
        install) cmd_install ;;
        install-service) cmd_install_service ;;
        update|self-update) cmd_update "$@" ;;
        uninstall) cmd_uninstall ;;
        version|-v|--version) echo "$VERSION" ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
