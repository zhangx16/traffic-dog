#!/bin/sh
# One-click installer for zhangx16/dog-alpine.

set -eu

REPO="${REPO:-zhangx16/dog-alpine}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
SCRIPT_URL="${SCRIPT_URL:-$RAW_BASE/port-traffic-stat.sh}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/port-traffic-stat}"
INSTALL_DEPS=1
INSTALL_SERVICE=1
PORTS=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
dog-alpine one-click installer

Usage:
  sh install.sh [options] [ports...]

Examples:
  sh install.sh
  sh install.sh 80 443
  sh install.sh 80,443,10000-10100
  sh install.sh --no-service 80 443

Options:
  --no-deps       Do not install nftables/curl packages
  --no-service    Do not install OpenRC/systemd startup service
  --branch NAME   Download from another Git branch
  --url URL       Download port-traffic-stat.sh from a custom URL
  -h, --help      Show this help

Environment:
  REPO=owner/repo
  BRANCH=main
  SCRIPT_URL=https://...
  INSTALL_PATH=/usr/local/bin/port-traffic-stat
EOF
}

need_root() {
    [ "$(id -u)" = "0" ] || die "please run as root"
}

has() {
    command -v "$1" >/dev/null 2>&1
}

install_deps() {
    if has apk; then
        apk add --no-cache nftables ca-certificates curl
        return 0
    fi

    if has apt-get; then
        apt-get update
        apt-get install -y nftables ca-certificates curl
        return 0
    fi

    if has dnf; then
        dnf install -y nftables ca-certificates curl
        return 0
    fi

    if has yum; then
        yum install -y nftables ca-certificates curl
        return 0
    fi

    echo "未识别包管理器，请手动安装 nftables 和 curl/wget。" >&2
}

download_file() {
    url=$1
    dest=$2

    if has curl; then
        curl -fsSL "$url" -o "$dest"
        return 0
    fi

    if has wget; then
        wget -qO "$dest" "$url"
        return 0
    fi

    die "curl/wget not found"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-deps)
                INSTALL_DEPS=0
                shift
                ;;
            --no-service)
                INSTALL_SERVICE=0
                shift
                ;;
            --branch)
                shift
                [ "$#" -gt 0 ] || die "--branch requires a value"
                BRANCH=$1
                RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
                SCRIPT_URL="$RAW_BASE/port-traffic-stat.sh"
                shift
                ;;
            --url)
                shift
                [ "$#" -gt 0 ] || die "--url requires a value"
                SCRIPT_URL=$1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do
                    PORTS="$PORTS $1"
                    shift
                done
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                PORTS="$PORTS $1"
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    need_root

    if [ "$INSTALL_DEPS" = "1" ]; then
        install_deps
    fi

    tmp="${TMPDIR:-/tmp}/port-traffic-stat.$$"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM

    echo "Downloading: $SCRIPT_URL"
    download_file "$SCRIPT_URL" "$tmp"

    mkdir -p "$(dirname "$INSTALL_PATH")"
    cp "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    echo "Installed: $INSTALL_PATH"

    if [ "$INSTALL_SERVICE" = "1" ]; then
        "$INSTALL_PATH" install-service || echo "启动服务安装失败或当前系统不支持，已跳过。"
    fi

    if [ -n "$PORTS" ]; then
        # Intentionally split user supplied port list by spaces.
        # shellcheck disable=SC2086
        "$INSTALL_PATH" add $PORTS
    else
        "$INSTALL_PATH" restore || true
    fi

    cat <<EOF

安装完成。

常用命令：
  port-traffic-stat add 80 443
  port-traffic-stat status
  port-traffic-stat watch 2
  port-traffic-stat reset all

EOF
}

main "$@"
