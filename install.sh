#!/bin/sh
# One-click installer for zhangx16/dog-alpine.
# Supports Alpine Linux and Debian/Ubuntu.

set -eu

REPO="${REPO:-zhangx16/dog-alpine}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/$REPO/$BRANCH}"
SCRIPT_URL="${SCRIPT_URL:-$RAW_BASE/port-traffic-stat.sh}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/port-traffic-stat}"
INSTALL_DEPS=1
INSTALL_SERVICE=1
LIMIT_SIZE=""
PORTS=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[dog-alpine] $*"
}

usage() {
    cat <<EOF
dog-alpine one-click installer
Supports Alpine Linux and Debian/Ubuntu.

Usage:
  sh install.sh [options] [ports...]

Examples:
  sh install.sh
  sh install.sh 80 443
  sh install.sh 80,443,10000-10100
  sh install.sh --limit 10G 80 443
  sh install.sh --no-service --limit 500M 10000-10100

Options:
  --limit SIZE    Set total IN+OUT traffic limit for each installed port
  --no-deps       Do not install nftables/curl packages
  --no-service    Do not install OpenRC/systemd/SysV startup service
  --branch NAME   Download from another Git branch
  --url URL       Download port-traffic-stat.sh from a custom URL
  -h, --help      Show this help

Size examples:
  500M, 10G, 1T, 1073741824

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
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables ca-certificates curl
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

    echo "Unknown package manager; please install nftables and curl/wget manually." >&2
}

download_file() {
    url=$1
    dest=$2

    if has curl; then
        curl -fL "$url" -o "$dest"
        return 0
    fi

    if has wget; then
        wget -O "$dest" "$url"
        return 0
    fi

    die "curl/wget not found"
}

validate_downloaded_script() {
    file=$1
    [ -s "$file" ] || die "downloaded script is empty; check network/DNS access to raw.githubusercontent.com"
    grep -q 'port-traffic-stat' "$file" || die "downloaded file does not look like port-traffic-stat.sh"
    /bin/sh -n "$file" || die "downloaded script has syntax errors"
}

for_each_port_arg() {
    for x in $PORTS; do
        printf '%s\n' "$x" | tr ',' '\n' | while IFS= read -r p; do
            [ -n "$p" ] || continue
            printf '%s\n' "$p"
        done
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --limit)
                shift
                [ "$#" -gt 0 ] || die "--limit requires a value"
                LIMIT_SIZE=$1
                shift
                ;;
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
    log "installer started"
    parse_args "$@"
    need_root

    if [ "$INSTALL_DEPS" = "1" ]; then
        log "installing dependencies if needed"
        install_deps
    fi

    tmp="${TMPDIR:-/tmp}/port-traffic-stat.$$"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM

    log "downloading: $SCRIPT_URL"
    download_file "$SCRIPT_URL" "$tmp"
    validate_downloaded_script "$tmp"

    mkdir -p "$(dirname "$INSTALL_PATH")"
    cp "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    log "installed: $INSTALL_PATH"
    log "version: $("$INSTALL_PATH" version 2>/dev/null || echo unknown)"

    if [ "$INSTALL_SERVICE" = "1" ]; then
        log "installing startup service"
        "$INSTALL_PATH" install-service || echo "Startup service installation skipped or unsupported."
    fi

    if [ -n "$PORTS" ]; then
        # Intentionally split user supplied port list by spaces.
        # shellcheck disable=SC2086
        "$INSTALL_PATH" add $PORTS
        if [ -n "$LIMIT_SIZE" ]; then
            for p in $(for_each_port_arg); do
                "$INSTALL_PATH" limit "$p" "$LIMIT_SIZE"
            done
        fi
    else
        "$INSTALL_PATH" restore || true
    fi

    cat <<EOF

Installation completed.

Common commands:
  port-traffic-stat
  port-traffic-stat add 80 443
  port-traffic-stat limit 80 10G
  port-traffic-stat status
  port-traffic-stat watch 2
  port-traffic-stat resume 80

EOF
}

main "$@"
