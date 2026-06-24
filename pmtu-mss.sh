#!/bin/bash
set -euo pipefail

MTU="${1:-1480}"

IPV4_MSS=$((MTU - 40))
IPV6_MSS=$((MTU - 60))

if [ "${EUID}" -ne 0 ]; then
    echo "[ERROR] 请使用 root 运行"
    exit 1
fi

install_dep() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "$pkg"
    fi
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ERROR] 缺少命令: $1"
        exit 1
    }
}

ensure_rule() {
    local chain="$1"

    while iptables -t mangle -C "$chain" \
        -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$IPV4_MSS" 2>/dev/null; do
        break
    done

    if ! iptables -t mangle -C "$chain" \
        -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$IPV4_MSS" 2>/dev/null; then

        iptables -t mangle -A "$chain" \
            -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --set-mss "$IPV4_MSS"

        echo "[OK] IPv4 $chain MSS=$IPV4_MSS"
    fi
}

ensure_rule_v6() {
    local chain="$1"

    if ! ip6tables -t mangle -C "$chain" \
        -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$IPV6_MSS" 2>/dev/null; then

        ip6tables -t mangle -A "$chain" \
            -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --set-mss "$IPV6_MSS"

        echo "[OK] IPv6 $chain MSS=$IPV6_MSS"
    fi
}

install_dep iptables-persistent
install_dep netfilter-persistent

ensure_cmd iptables
ensure_cmd ip6tables
ensure_cmd netfilter-persistent

ensure_rule POSTROUTING
ensure_rule_v6 POSTROUTING

systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true

netfilter-persistent save

echo
echo "======================================"
echo " MTU  : $MTU"
echo " IPv4 MSS : $IPV4_MSS"
echo " IPv6 MSS : $IPV6_MSS"
echo "======================================"
echo "已永久保存并设置开机自动恢复"
