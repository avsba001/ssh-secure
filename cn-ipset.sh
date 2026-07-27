#!/bin/bash
set -e

IPSET_NAME="fwguard_cn_ipv4"
LIST_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
TMP_FILE="/tmp/china_ip_list.txt"
SCRIPT_PATH="/usr/local/bin/update-cn-ipset.sh"
SERVICE_PATH="/etc/systemd/system/cn-ipset.service"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_pkg() {
  local pkgs="$*"

  if need_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
  elif need_cmd dnf; then
    dnf install -y $pkgs
  elif need_cmd yum; then
    yum install -y $pkgs
  elif need_cmd apk; then
    apk add --no-cache $pkgs
  else
    echo "[ERROR] 无法自动安装依赖，请手动安装: $pkgs"
    exit 1
  fi
}

ensure_dependency() {
  local cmd="$1"
  local pkg="$2"

  if ! need_cmd "$cmd"; then
    echo "[INFO] 缺少依赖 $cmd，尝试安装 $pkg"
    install_pkg "$pkg"
  fi

  if ! need_cmd "$cmd"; then
    echo "[ERROR] 依赖安装失败: $cmd"
    exit 1
  fi
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

rollback_all() {
  echo "[WARN] 检测到网络异常，开始回滚..."

  systemctl disable cn-ipset >/dev/null 2>&1 || true
  systemctl stop cn-ipset >/dev/null 2>&1 || true

  if [ -f "$SERVICE_PATH" ]; then
    rm -f "$SERVICE_PATH"
  fi

  if [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH"
  fi

  iptables -D INPUT -p icmp -m set --match-set "$IPSET_NAME" src -j DROP >/dev/null 2>&1 || true

  if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
    ipset flush "$IPSET_NAME" || true
    ipset destroy "$IPSET_NAME" || true
  fi

  rm -f "$TMP_FILE"

  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "[INFO] 回滚完成。"
}

# ===== 依赖检查 =====
ensure_dependency wget wget
ensure_dependency ipset ipset
ensure_dependency iptables iptables
ensure_dependency systemctl systemd
ensure_dependency ping iputils-ping
ensure_iptables_firewall_backend

cat > "$SCRIPT_PATH" <<'SCRIPT_EOF'
#!/bin/bash
set -e

IPSET_NAME="fwguard_cn_ipv4"
LIST_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
TMP_FILE="/tmp/china_ip_list.txt"

# 下载IP列表
wget -qO "$TMP_FILE" "$LIST_URL"

# 创建ipset（如果不存在）
ipset list "$IPSET_NAME" >/dev/null 2>&1 || ipset create "$IPSET_NAME" hash:net

# 清空旧规则
ipset flush "$IPSET_NAME"

# 导入IP
while read -r ip; do
  [ -n "$ip" ] && ipset add "$IPSET_NAME" "$ip"
done < "$TMP_FILE"

# 添加iptables规则（如果不存在）
iptables -C INPUT -p icmp -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || \
  iptables -I INPUT 1 -p icmp -m set --match-set "$IPSET_NAME" src -j DROP
SCRIPT_EOF

chmod +x "$SCRIPT_PATH"

echo "已创建: $SCRIPT_PATH"

cat > "$SERVICE_PATH" <<'SERVICE_EOF'
[Unit]
Description=Update China IP ipset
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-cn-ipset.sh

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "已创建: $SERVICE_PATH"

systemctl daemon-reload
systemctl enable cn-ipset
systemctl start cn-ipset

echo "[INFO] 服务已启动，开始连通性检测（5秒）..."
if ping -c 5 -W 1 1.1.1.1 >/tmp/cn-ipset-ping.log 2>&1; then
  echo "[INFO] 连通性检测通过。"
else
  if grep -q "100% packet loss" /tmp/cn-ipset-ping.log; then
    rollback_all
    echo "[ERROR] 检测到 100% 丢包，已回滚所有操作。"
    exit 1
  fi
  echo "[WARN] ping 未通过，但不属于 100% 丢包，保留当前配置。"
fi

echo "已启用并启动 cn-ipset 服务，开机将自动执行。"
