#!/usr/bin/env bash

set -u

WG_IF="${WG_IF:-wg0}"
PEER_IP="${2:-}"
DO_TEST="${WG_TEST:-ask}"

usage() {
    echo "Usage:"
    echo "  sudo $0 server 10.66.66.2"
    echo "  sudo $0 client 10.66.66.1"
    echo
    echo "Options:"
    echo "  WG_TEST=yes sudo $0 server 10.66.66.2"
    echo "  WG_TEST=no  sudo $0 server 10.66.66.2"
    echo
    echo "Defaults:"
    echo "  server VPN IP: 10.66.66.1"
    echo "  client VPN IP: 10.66.66.2"
}

fail() {
    echo "[FAIL] $1"
    exit 1
}

ok() {
    echo "[OK] $1"
}

ask_test() {
    if [ -z "$PEER_IP" ]; then
        return 1
    fi

    case "$DO_TEST" in
        yes|YES|y|Y|1|true|TRUE) return 0 ;;
        no|NO|n|N|0|false|FALSE) return 1 ;;
    esac

    local answer
    read -r -p "Ping peer $PEER_IP now? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

userspace_impl() {
    if command -v wireguard-go >/dev/null 2>&1; then
        command -v wireguard-go
        return 0
    fi
    if command -v wireguard >/dev/null 2>&1; then
        command -v wireguard
        return 0
    fi
    return 1
}

kernel_wg_available() {
    [ -e /sys/module/wireguard ] || modprobe wireguard >/dev/null 2>&1
}

wg_quick_up_auto() {
    if ip link show "$WG_IF" >/dev/null 2>&1; then
        ok "$WG_IF is already up"
        return 0
    fi

    if kernel_wg_available; then
        wg-quick up "$WG_IF" && return 0
    fi

    local impl
    impl="$(userspace_impl || true)"
    if [ -z "$impl" ]; then
        echo "[FAIL] WireGuard kernel module is unavailable and no userspace implementation was found."
        return 1
    fi

    echo "WireGuard kernel module is unavailable; using userspace implementation: $impl"
    WG_QUICK_USERSPACE_IMPLEMENTATION="$impl" wg-quick up "$WG_IF"
}

if [ "$(id -u)" -ne 0 ]; then
    fail "run this script with sudo"
fi

ROLE="${1:-}"
case "$ROLE" in
    server|client) ;;
    *) usage; exit 1 ;;
esac

command -v wg >/dev/null 2>&1 || fail "wg is not installed"
command -v wg-quick >/dev/null 2>&1 || fail "wg-quick is not installed"
ok "WireGuard tools are installed"

CONF="/etc/wireguard/$WG_IF.conf"
[ -f "$CONF" ] || fail "WireGuard config not found: $CONF"
ok "Config exists: $CONF"

echo "Starting $ROLE interface $WG_IF..."
wg_quick_up_auto || fail "failed to start $WG_IF"
ok "$WG_IF is up"

echo
wg show "$WG_IF"

if ask_test; then
    echo
    echo "Pinging peer: $PEER_IP"
    ping -c 3 -W 1 "$PEER_IP" || fail "ping $PEER_IP failed"
    ok "ping $PEER_IP passed"
else
    echo
    echo "Ping test skipped."
    if [ -n "$PEER_IP" ]; then
        echo "Run this to test later:"
        echo "  sudo $0 $ROLE $PEER_IP"
    fi
fi
