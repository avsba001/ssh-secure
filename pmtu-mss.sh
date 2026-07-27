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

iptables_backend() {
    local version
    version="$(iptables -V 2>/dev/null || true)"
    if grep -qi 'nf_tables' <<< "$version"; then
        echo "nft"
    elif [ -n "$version" ]; then
        echo "iptables"
    else
        echo "unknown"
    fi
}

switch_to_iptables_legacy() {
    local alt legacy

    if ! command -v update-alternatives >/dev/null 2>&1; then
        echo "[ERROR] 缺少 update-alternatives，无法自动切换到 iptables-legacy"
        exit 1
    fi

    for alt in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
        legacy="/usr/sbin/${alt}-legacy"
        if [ -x "$legacy" ]; then
            update-alternatives --set "$alt" "$legacy"
        fi
    done

    systemctl disable --now nftables >/dev/null 2>&1 || true
}

ensure_iptables_firewall_backend() {
    local backend choice

    backend="$(iptables_backend)"
    echo "[INFO] 当前 iptables 后端: $backend ($(iptables -V 2>/dev/null || echo unknown))"
    case "$backend" in
        iptables)
            ;;
        nft)
            read -rp "检测到当前使用 nft 后端。是否切换到 iptables-legacy 并禁用 nftables 服务？(y=是 / n=停止) [默认: y]: " choice
            case "${choice:-y}" in
                [Yy])
                    switch_to_iptables_legacy
                    if [ "$(iptables_backend)" != "iptables" ]; then
                        echo "[ERROR] 切换后仍未使用 iptables-legacy，请手动检查 update-alternatives"
                        exit 1
                    fi
                    echo "[INFO] 已切换到 iptables-legacy，并已尝试禁用 nftables 服务。"
                    ;;
                *)
                    echo "[ERROR] 已停止。请先切换到 iptables-legacy。"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "[ERROR] 无法识别当前 iptables 后端"
            exit 1
            ;;
    esac
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
ensure_iptables_firewall_backend

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
