#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行"
  exit 1
fi

install_dep() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[INFO] 安装依赖: $pkg"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$pkg"
  fi
}

ensure_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] 缺少命令: $cmd"
    exit 1
  fi
}

ensure_rule() {
  local chain="$1"
  if iptables -t mangle -C "$chain" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    echo "[INFO] 规则已存在: mangle/$chain TCPMSS clamp-mss-to-pmtu"
  else
    iptables -t mangle -A "$chain" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    echo "[OK] 已添加规则: mangle/$chain TCPMSS clamp-mss-to-pmtu"
  fi
}

install_dep iptables-persistent
install_dep netfilter-persistent

ensure_cmd iptables
ensure_cmd netfilter-persistent

ensure_rule POSTROUTING
ensure_rule FORWARD

netfilter-persistent save

iptables -t mangle -S POSTROUTING | grep -q -- '--clamp-mss-to-pmtu' || { echo "[ERROR] POSTROUTING 校验失败"; exit 1; }
iptables -t mangle -S FORWARD | grep -q -- '--clamp-mss-to-pmtu' || { echo "[ERROR] FORWARD 校验失败"; exit 1; }

echo "✅ PMTU MSS 规则配置完成并已持久化"
