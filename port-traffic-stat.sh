#!/bin/sh
# port-traffic-stat.sh
# 端口流量统计脚本：使用 nftables 统计指定端口的入站/出站字节数。
# 兼容 Alpine Linux / BusyBox ash；不依赖 bash、jq、bc。

set -eu

VERSION="1.0.0"
FAMILY="inet"
TABLE="port_traffic_stat"
CONFIG_DIR="${PTS_CONFIG_DIR:-/etc/port-traffic-stat}"
PORTS_FILE="$CONFIG_DIR/ports"
STATE_FILE="$CONFIG_DIR/state"
LOCK_DIR="/tmp/port-traffic-stat.lock"

umask 022

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 运行"
}

need_nft() {
    command -v nft >/dev/null 2>&1 || die "找不到 nft 命令，请先运行：$0 install-deps"
}

now_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

with_lock() {
    i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "获取锁失败：$LOCK_DIR"
        sleep 1
    done
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
}

ensure_files() {
    mkdir -p "$CONFIG_DIR"
    [ -f "$PORTS_FILE" ] || : > "$PORTS_FILE"
    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

strip_leading_zero() {
    n=$(printf '%s' "$1" | sed 's/^0*//')
    [ -n "$n" ] || n=0
    printf '%s\n' "$n"
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
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
    # 支持：80 443 10000-10100 或 80,443,10000-10100
    for arg in "$@"; do
        printf '%s\n' "$arg" | tr ',' '\n' | while IFS= read -r item; do
            [ -n "$item" ] || continue
            normalize_port_spec "$item" || die "端口格式无效：$item"
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

add_table_and_chains() {
    nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1 || nft add table "$FAMILY" "$TABLE"
    nft list chain "$FAMILY" "$TABLE" input >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" input "{ type filter hook input priority 0; policy accept; }"
    nft list chain "$FAMILY" "$TABLE" output >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" output "{ type filter hook output priority 0; policy accept; }"
    nft list chain "$FAMILY" "$TABLE" forward >/dev/null 2>&1 || \
        nft add chain "$FAMILY" "$TABLE" forward "{ type filter hook forward priority 0; policy accept; }"
}

add_rules_for_port() {
    p=$1
    cin=$(counter_in "$p")
    cout=$(counter_out "$p")

    nft add counter "$FAMILY" "$TABLE" "$cin" >/dev/null 2>&1 || true
    nft add counter "$FAMILY" "$TABLE" "$cout" >/dev/null 2>&1 || true

    for proto in tcp udp; do
        # 入站：发往本机服务端口，或经本机转发到该端口。
        nft add rule "$FAMILY" "$TABLE" input "$proto" dport "$p" counter name "$cin"
        nft add rule "$FAMILY" "$TABLE" forward "$proto" dport "$p" counter name "$cin"
        # 出站：本机服务端口返回给客户端，或经本机转发的返回方向。
        nft add rule "$FAMILY" "$TABLE" output "$proto" sport "$p" counter name "$cout"
        nft add rule "$FAMILY" "$TABLE" forward "$proto" sport "$p" counter name "$cout"
    done
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

port_delta_bytes() {
    p=$1
    cin=$(counter_in "$p")
    cout=$(counter_out "$p")
    in_delta=$(counter_bytes "$cin")
    out_delta=$(counter_bytes "$cout")
    echo "$in_delta $out_delta"
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
}

save_all_snapshots() {
    ensure_files
    if nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            save_port_snapshot "$p"
        done < "$PORTS_FILE"
    fi
}

rebuild_nft_rules() {
    need_root
    need_nft
    ensure_files

    nft delete table "$FAMILY" "$TABLE" >/dev/null 2>&1 || true
    add_table_and_chains

    while IFS= read -r p; do
        [ -n "$p" ] || continue
        add_rules_for_port "$p"
    done < "$PORTS_FILE"
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

print_status() {
    ensure_files
    need_nft

    if ! nft list table "$FAMILY" "$TABLE" >/dev/null 2>&1; then
        echo "nftables 规则未加载。请运行：$0 restore"
        exit 1
    fi

    count=$(awk 'NF { n++ } END { print n+0 }' "$PORTS_FILE")
    [ "$count" -gt 0 ] || {
        echo "暂无统计端口。添加示例：$0 add 80 443"
        return 0
    }

    printf '%-16s %14s %14s %14s  %s\n' "PORT" "IN" "OUT" "TOTAL" "RESET_AT"
    printf '%-16s %14s %14s %14s  %s\n' "----------------" "--------------" "--------------" "--------------" "------------------------"

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

        printf '%-16s %14s %14s %14s  %s\n' \
            "$p" "$(human_bytes "$inb")" "$(human_bytes "$outb")" "$(human_bytes "$total")" "$reset_at"
    done < "$PORTS_FILE"

    grand_total=$((grand_in + grand_out))
    printf '%-16s %14s %14s %14s\n' \
        "TOTAL" "$(human_bytes "$grand_in")" "$(human_bytes "$grand_out")" "$(human_bytes "$grand_total")"
}

cmd_add() {
    [ "$#" -ge 1 ] || die "用法：$0 add 80 443 10000-10100"
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots

    ports_list=$(split_port_args "$@")
    for p in $ports_list; do
        if grep -qxF "$p" "$PORTS_FILE" 2>/dev/null; then
            echo "已存在：$p"
        else
            printf '%s\n' "$p" >> "$PORTS_FILE"
            set_state_line "$p" 0 0 "$(now_iso)"
            echo "已添加：$p"
        fi
    done

    sort_tmp="$PORTS_FILE.sort.$$"
    sort -u "$PORTS_FILE" > "$sort_tmp"
    mv "$sort_tmp" "$PORTS_FILE"
    rebuild_nft_rules
    echo "规则已加载。查看：$0 status"
}

cmd_del() {
    [ "$#" -ge 1 ] || die "用法：$0 del 80 443"
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
            echo "已删除：$p"
        else
            echo "不存在：$p"
        fi
    done

    mv "$tmp" "$PORTS_FILE"
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
        done < "$PORTS_FILE"
        rebuild_nft_rules
        echo "已清零全部端口统计。"
        return 0
    fi

    p=$(normalize_port_spec "$target") || die "端口格式无效：$target"
    grep -qxF "$p" "$PORTS_FILE" 2>/dev/null || die "端口未添加：$p"
    set_state_line "$p" 0 0 "$(now_iso)"
    rebuild_nft_rules
    echo "已清零端口统计：$p"
}

cmd_restore() {
    need_root
    need_nft
    with_lock
    ensure_files
    rebuild_nft_rules
    echo "已恢复 nftables 统计规则。"
}

cmd_save() {
    need_root
    need_nft
    with_lock
    ensure_files
    save_all_snapshots
    rebuild_nft_rules
    echo "已保存当前计数到：$STATE_FILE"
}

cmd_flush() {
    need_root
    need_nft
    with_lock
    save_all_snapshots
    nft delete table "$FAMILY" "$TABLE" >/dev/null 2>&1 || true
    echo "已卸载 nftables 规则，历史统计已保存。"
}

cmd_watch() {
    interval=${1:-2}
    case "$interval" in
        ''|*[!0-9]*) die "刷新间隔必须是秒数" ;;
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
        echo "nftables 已安装：$(command -v nft)"
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache nftables
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y nftables
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nftables
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nftables
    else
        die "未识别包管理器，请手动安装 nftables"
    fi
}

cmd_install() {
    need_root
    dest="/usr/local/bin/port-traffic-stat"
    cp "$0" "$dest"
    chmod +x "$dest"
    ensure_files
    echo "已安装到：$dest"
    echo "下一步：port-traffic-stat install-deps && port-traffic-stat add 80 443"
}

cmd_install_service() {
    need_root
    [ -x /usr/local/bin/port-traffic-stat ] || cmd_install

    if command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        cat > /etc/init.d/port-traffic-stat <<'EOF'
#!/sbin/openrc-run
description="Restore and save port traffic nftables counters"

depend() {
    need localmount
    after firewall
}

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
        echo "已安装 OpenRC 服务：port-traffic-stat"
        echo "启动：rc-service port-traffic-stat start"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/port-traffic-stat.service <<'EOF'
[Unit]
Description=Restore and save port traffic nftables counters
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/port-traffic-stat restore
ExecStop=/usr/local/bin/port-traffic-stat save

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable port-traffic-stat.service
        echo "已安装 systemd 服务：port-traffic-stat.service"
        echo "启动：systemctl start port-traffic-stat"
        return 0
    fi

    die "未识别 OpenRC 或 systemd，无法自动安装启动服务"
}

cmd_uninstall() {
    need_root
    cmd_flush || true
    if command -v rc-update >/dev/null 2>&1 && [ -f /etc/init.d/port-traffic-stat ]; then
        rc-update del port-traffic-stat default >/dev/null 2>&1 || true
        rm -f /etc/init.d/port-traffic-stat
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/port-traffic-stat.service ]; then
        systemctl disable port-traffic-stat.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/port-traffic-stat.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f /usr/local/bin/port-traffic-stat
    echo "已卸载程序和启动服务；统计数据目录仍保留：$CONFIG_DIR"
}

usage() {
    cat <<EOF
port-traffic-stat v$VERSION

用途：
  用 nftables 统计指定 TCP/UDP 端口的入站、出站和总流量。
  兼容 Alpine Linux，脚本使用 /bin/sh，不依赖 bash/jq/bc。

用法：
  $0 install-deps                 安装 nftables，Alpine 下使用 apk
  $0 install                      安装脚本到 /usr/local/bin/port-traffic-stat
  $0 install-service              安装开机恢复服务，Alpine 下为 OpenRC

  $0 add 80 443 10000-10100       添加统计端口/端口段
  $0 del 80                       删除统计端口
  $0 status                       查看统计
  $0 watch [秒]                   循环查看统计，默认 2 秒刷新
  $0 reset [端口|all]             清零统计，默认 all
  $0 save                         保存当前计数并重载规则
  $0 restore                      重新加载 nftables 统计规则
  $0 flush                        卸载 nftables 统计规则但保留历史统计
  $0 uninstall                    卸载脚本和启动服务，保留 $CONFIG_DIR

说明：
  IN    = dport 命中该端口的流量，包含 input/forward 链
  OUT   = sport 命中该端口的流量，包含 output/forward 链
  TOTAL = IN + OUT

Alpine 快速开始：
  chmod +x $0
  doas ./$0 install-deps          # 或 sudo / 直接 root
  doas ./$0 install
  doas port-traffic-stat install-service
  doas port-traffic-stat add 80 443
  port-traffic-stat status
EOF
}

main() {
    cmd=${1:-help}
    shift || true

    case "$cmd" in
        add) cmd_add "$@" ;;
        del|delete|remove) cmd_del "$@" ;;
        status|show|list) print_status ;;
        watch) cmd_watch "$@" ;;
        reset) cmd_reset "$@" ;;
        save) cmd_save ;;
        restore|reload|init) cmd_restore ;;
        flush|stop) cmd_flush ;;
        install-deps) cmd_install_deps ;;
        install) cmd_install ;;
        install-service) cmd_install_service ;;
        uninstall) cmd_uninstall ;;
        version|-v|--version) echo "$VERSION" ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
