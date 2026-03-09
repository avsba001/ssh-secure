#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "请用 root 运行：sudo bash fail2ban.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

BACKUP_ROOT="/var/backups/fail2ban-installer"
TS="$(date +%F_%H-%M-%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"
UNINSTALL_SCRIPT="${BACKUP_DIR}/uninstall-fail2ban-enhanced.sh"

backup_file_if_exists() {
  local src="$1"
  if [ -f "${src}" ]; then
    mkdir -p "${BACKUP_DIR}$(dirname "${src}")"
    cp -a "${src}" "${BACKUP_DIR}${src}"
  fi
}

backup_existing_configs() {
  echo "===> 备份当前配置（用于卸载/回滚）"
  mkdir -p "${BACKUP_DIR}"

  backup_file_if_exists /etc/fail2ban/jail.local
  backup_file_if_exists /etc/fail2ban/filter.d/sshd-disconnect.conf
  backup_file_if_exists /etc/fail2ban/filter.d/sshd-ddos.conf
  backup_file_if_exists /etc/fail2ban/filter.d/sshd-aggressive.conf
  backup_file_if_exists /etc/fail2ban/action.d/ufw-ipset.conf
  backup_file_if_exists /etc/fail2ban/action.d/ufw-ipset-persistent.conf
  backup_file_if_exists /etc/systemd/system/f2b-ipset-restore.service
  backup_file_if_exists /usr/local/bin/f2b-ipset-ensure.sh
  backup_file_if_exists /etc/ipset/f2b-ipset.rules

  if [ -d /etc/fail2ban/jail.d ]; then
    mkdir -p "${BACKUP_DIR}/etc/fail2ban"
    cp -a /etc/fail2ban/jail.d "${BACKUP_DIR}/etc/fail2ban/"
  fi

  ipset save > "${BACKUP_DIR}/ipset-all.rules" 2>/dev/null || true
  ufw status verbose > "${BACKUP_DIR}/ufw-status.txt" 2>/dev/null || true

  cat > "${UNINSTALL_SCRIPT}" <<EOS
#!/bin/bash
set -euo pipefail

if [ "\${EUID}" -ne 0 ]; then
  echo "请使用 root 运行卸载脚本"
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR}"

echo "===> 使用备份恢复 fail2ban 配置: \${BACKUP_DIR}"

systemctl stop fail2ban >/dev/null 2>&1 || true
systemctl stop f2b-ipset-restore.service >/dev/null 2>&1 || true
systemctl disable f2b-ipset-restore.service >/dev/null 2>&1 || true

rm -f /etc/fail2ban/filter.d/sshd-aggressive.conf
rm -f /etc/fail2ban/action.d/ufw-ipset-persistent.conf
rm -f /etc/systemd/system/f2b-ipset-restore.service
rm -f /usr/local/bin/f2b-ipset-ensure.sh

if [ -f "\${BACKUP_DIR}/etc/fail2ban/jail.local" ]; then
  cp -a "\${BACKUP_DIR}/etc/fail2ban/jail.local" /etc/fail2ban/jail.local
fi
if [ -f "\${BACKUP_DIR}/etc/fail2ban/filter.d/sshd-disconnect.conf" ]; then
  cp -a "\${BACKUP_DIR}/etc/fail2ban/filter.d/sshd-disconnect.conf" /etc/fail2ban/filter.d/sshd-disconnect.conf
fi
if [ -f "\${BACKUP_DIR}/etc/fail2ban/filter.d/sshd-ddos.conf" ]; then
  cp -a "\${BACKUP_DIR}/etc/fail2ban/filter.d/sshd-ddos.conf" /etc/fail2ban/filter.d/sshd-ddos.conf
fi
if [ -f "\${BACKUP_DIR}/etc/fail2ban/action.d/ufw-ipset.conf" ]; then
  cp -a "\${BACKUP_DIR}/etc/fail2ban/action.d/ufw-ipset.conf" /etc/fail2ban/action.d/ufw-ipset.conf
fi
if [ -d "\${BACKUP_DIR}/etc/fail2ban/jail.d" ]; then
  rm -rf /etc/fail2ban/jail.d
  cp -a "\${BACKUP_DIR}/etc/fail2ban/jail.d" /etc/fail2ban/
fi
if [ -f "\${BACKUP_DIR}/etc/systemd/system/f2b-ipset-restore.service" ]; then
  cp -a "\${BACKUP_DIR}/etc/systemd/system/f2b-ipset-restore.service" /etc/systemd/system/f2b-ipset-restore.service
fi
if [ -f "\${BACKUP_DIR}/usr/local/bin/f2b-ipset-ensure.sh" ]; then
  cp -a "\${BACKUP_DIR}/usr/local/bin/f2b-ipset-ensure.sh" /usr/local/bin/f2b-ipset-ensure.sh
fi
if [ -f "\${BACKUP_DIR}/etc/ipset/f2b-ipset.rules" ]; then
  mkdir -p /etc/ipset
  cp -a "\${BACKUP_DIR}/etc/ipset/f2b-ipset.rules" /etc/ipset/f2b-ipset.rules
fi

systemctl daemon-reload
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban >/dev/null 2>&1 || true

echo "✅ 已恢复到安装前备份（如有）"
EOS

  chmod +x "${UNINSTALL_SCRIPT}"
  echo "备份目录: ${BACKUP_DIR}"
  echo "卸载脚本: ${UNINSTALL_SCRIPT}"
}

restore_from_backup() {
  echo "===> 网络检查失败，恢复安装前配置"
  if [ -x "${UNINSTALL_SCRIPT}" ]; then
    "${UNINSTALL_SCRIPT}" || true
  fi
}

verify_network_or_restore() {
  local ok=0
  echo "===> 网络连通性检查：ping 1.1.1.1（5秒）"

  for _ in 1 2 3 4 5; do
    if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
      ok=1
      break
    fi
  done

  if [ "${ok}" -ne 1 ]; then
    restore_from_backup
    echo "❌ 5秒内无法 ping 通 1.1.1.1，已尝试恢复之前配置"
    exit 1
  fi

  echo "✅ 网络检查通过"
}


ensure_generated_files() {
  local required_files=(
    /usr/local/bin/f2b-ipset-ensure.sh
    /etc/systemd/system/f2b-ipset-restore.service
    /etc/fail2ban/action.d/ufw-ipset-persistent.conf
    /etc/fail2ban/filter.d/sshd-aggressive.conf
  )

  for f in "${required_files[@]}"; do
    if [ ! -s "${f}" ]; then
      echo "❌ 关键文件未成功生成: ${f}"
      restore_from_backup
      exit 1
    fi
  done
}

wait_for_fail2ban_ready() {
  echo "===> 等待 fail2ban 启动就绪"
  local i
  for i in $(seq 1 15); do
    if fail2ban-client ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "❌ fail2ban 未能在预期时间内启动"
  systemctl status fail2ban --no-pager || true
  journalctl -u fail2ban -n 50 --no-pager || true
  restore_from_backup
  exit 1
}

cleanup_legacy_fail2ban_configs() {
  echo "===> 清理旧版 fail2ban.sh 残留配置"

  local legacy_files=(
    /etc/fail2ban/filter.d/sshd-disconnect.conf
    /etc/fail2ban/filter.d/sshd-ddos.conf
    /etc/fail2ban/action.d/ufw-ipset.conf
  )

  for f in "${legacy_files[@]}"; do
    if [ -f "${f}" ]; then
      rm -f "${f}"
      echo "已删除旧配置: ${f}"
    fi
  done

  if [ -d /etc/fail2ban/jail.d ]; then
    find /etc/fail2ban/jail.d -maxdepth 1 -type f \
      \( -name '*sshd-disconnect*.conf' -o -name '*fail2ban-custom*.conf' -o -name 'legacy-sshd.conf' \) \
      -print -delete || true
  fi
}

echo "===> 安装依赖（fail2ban/ufw/ipset/rsyslog）"
apt update
apt install -y rsyslog ufw fail2ban ipset

mkdir -p /etc/ipset
backup_existing_configs
cleanup_legacy_fail2ban_configs

cat > /usr/local/bin/f2b-ipset-ensure.sh << 'EOS'
#!/bin/bash
set -euo pipefail

IPSET_FILE="/etc/ipset/f2b-ipset.rules"
IPSET_SINGLE="f2b-blacklist"
IPSET_NET="f2b-blacklist24"

ensure_sets() {
  ipset create "${IPSET_SINGLE}" hash:ip family inet timeout 0 -exist
  ipset create "${IPSET_NET}" hash:net family inet timeout 0 -exist
}

ensure_ufw_rules() {
  local chain="ufw-before-input"
  iptables -C "${chain}" -m set --match-set "${IPSET_SINGLE}" src -j DROP >/dev/null 2>&1 \
    || iptables -I "${chain}" 1 -m set --match-set "${IPSET_SINGLE}" src -j DROP

  iptables -C "${chain}" -m set --match-set "${IPSET_NET}" src -j DROP >/dev/null 2>&1 \
    || iptables -I "${chain}" 1 -m set --match-set "${IPSET_NET}" src -j DROP
}

save_sets() {
  ipset save "${IPSET_SINGLE}" > "${IPSET_FILE}".tmp
  ipset save "${IPSET_NET}" >> "${IPSET_FILE}".tmp
  mv "${IPSET_FILE}".tmp "${IPSET_FILE}"
}

restore_sets() {
  ensure_sets
  if [ -s "${IPSET_FILE}" ]; then
    ipset restore -exist < "${IPSET_FILE}"
  fi
}

add_ip() {
  local ip="$1"
  local slash24
  slash24="$(echo "${ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"

  ensure_sets
  ipset add "${IPSET_SINGLE}" "${ip}" -exist
  ipset add "${IPSET_NET}" "${slash24}" -exist
  ensure_ufw_rules
  save_sets
}

remove_ip() {
  local ip="$1"
  ensure_sets
  ipset del "${IPSET_SINGLE}" "${ip}" 2>/dev/null || true
  save_sets
}

case "${1:-}" in
  init)
    ensure_sets
    ensure_ufw_rules
    save_sets
    ;;
  restore)
    restore_sets
    ensure_ufw_rules
    ;;
  add)
    add_ip "$2"
    ;;
  remove)
    remove_ip "$2"
    ;;
  save)
    ensure_sets
    save_sets
    ;;
  *)
    echo "用法: $0 {init|restore|add <IP>|remove <IP>|save}"
    exit 1
    ;;
esac
EOS
chmod +x /usr/local/bin/f2b-ipset-ensure.sh

cat > /etc/systemd/system/f2b-ipset-restore.service << 'EOF2'
[Unit]
Description=Restore Fail2Ban ipset blocks and UFW chain hooks
DefaultDependencies=no
After=network-pre.target ufw.service
Before=fail2ban.service
Wants=ufw.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/f2b-ipset-ensure.sh restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/fail2ban/action.d/ufw-ipset-persistent.conf << 'EOF3'
[Definition]
actionstart = /usr/local/bin/f2b-ipset-ensure.sh init
actionstop  = /usr/local/bin/f2b-ipset-ensure.sh save
actioncheck = /usr/local/bin/f2b-ipset-ensure.sh init
actionban   = /usr/local/bin/f2b-ipset-ensure.sh add <ip>
actionunban = /usr/local/bin/f2b-ipset-ensure.sh remove <ip>
EOF3

cat > /etc/fail2ban/filter.d/sshd-aggressive.conf << 'EOF4'
[Definition]
failregex =
  ^.*sshd(?:\[\d+\])?: Invalid user .* from <HOST>(?: port \d+)?(?: ssh\d+)?\s*$
  ^.*sshd(?:\[\d+\])?: Failed password for (?:invalid user )?.* from <HOST> port \d+(?: ssh\d+)?\s*$
  ^.*sshd(?:\[\d+\])?: Did not receive identification string from <HOST>\s*$
  ^.*sshd(?:\[\d+\])?: Connection closed by (?:invalid user )?.* <HOST> port \d+ \[preauth\]\s*$
  ^.*sshd(?:\[\d+\])?: kex_exchange_identification: .* <HOST> port \d+\s*$
  ^.*sshd(?:\[\d+\])?: banner exchange: Connection from <HOST> port \d+:.*\s*$
ignoreregex =
EOF4

JAIL_LOCAL="/etc/fail2ban/jail.local"
if [ -f "${JAIL_LOCAL}" ]; then
  cp "${JAIL_LOCAL}" "${JAIL_LOCAL}.$(date +%F_%H-%M-%S).bak"
fi

cat > "${JAIL_LOCAL}" << 'EOF5'
[DEFAULT]
bantime  = 7d
findtime = 10m
maxretry = 6
ignoreip = 127.0.0.1/8
banaction = ufw-ipset-persistent

[sshd]
enabled  = true
port     = 22222
logpath  = /var/log/auth.log
backend  = auto
maxretry = 3
findtime = 5m
bantime  = 7d

[sshd-aggressive]
enabled  = true
filter   = sshd-aggressive
port     = 22222
logpath  = /var/log/auth.log
backend  = auto
maxretry = 1
findtime = 10m
bantime  = 30d
EOF5

ensure_generated_files

ufw --force enable >/dev/null 2>&1 || true
/usr/local/bin/f2b-ipset-ensure.sh init

systemctl daemon-reload
systemctl enable f2b-ipset-restore.service >/dev/null
systemctl restart f2b-ipset-restore.service
systemctl enable fail2ban --now
systemctl restart fail2ban

echo "===> fail2ban-client 验证"
wait_for_fail2ban_ready
fail2ban-client status sshd
fail2ban-client status sshd-aggressive

verify_network_or_restore

echo "===> 已完成："
echo "  1) 自动封禁单 IP + /24 段"
echo "  2) 增强识别 masscan/zmap 类扫描"
echo "  3) UFW 链中使用 ipset 规则（高性能）"
echo "  4) 重启后自动恢复 ipset 封禁"
echo "  5) 安装前配置已备份，可用卸载脚本恢复"
