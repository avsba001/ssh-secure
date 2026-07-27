#!/bin/bash
set -e

### ===== 基本信息 =====
SCRIPT_NAME="vps-secure.sh"
REPO_RAW="https://raw.githubusercontent.com/avsba001/vps-secure/main"
LOCAL_VERSION="1.0.15"

### ===== 防止无限自更新 =====
if [ "$VPS_SECURE_UPDATED" != "1" ]; then
  export VPS_SECURE_UPDATED=1

  REMOTE_VERSION="$(wget -qO- "$REPO_RAW/VERSION" || true)"
  if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]; then
    echo "发现新版本：$REMOTE_VERSION（当前 $LOCAL_VERSION）"
    echo "正在更新脚本..."

    wget -q -O "/tmp/$SCRIPT_NAME" "$REPO_RAW/$SCRIPT_NAME" || {
      echo "更新失败，继续使用当前版本"
    }

    chmod +x "/tmp/$SCRIPT_NAME"
    echo "更新完成，重新执行新版本"
    exec "/tmp/$SCRIPT_NAME" "$@"
  fi
fi

### ===== 正常逻辑从这里开始 =====

WORKDIR="/tmp/ssh-secure"
BACKUP_ROOT="/var/backups/vps-secure"
mkdir -p "$WORKDIR" "$BACKUP_ROOT"

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行"
  exit 1
fi

backup_paths_for_step() {
  case "$1" in
    1)
      echo "/etc/ssh/sshd_config"
      ;;
    2)
      echo "/usr/local/bin/set-cake.sh /etc/systemd/system/set-cake.service"
      ;;
    3)
      echo "/etc/fail2ban/jail.local /etc/fail2ban/filter.d/sshd-disconnect.conf"
      ;;
    5)
      echo "/usr/local/bin/update-cn-ipset.sh /etc/systemd/system/cn-ipset.service"
      ;;
    6)
      echo ""
      ;;
    7)
      echo "/usr/local/sbin/fwguard-firewall /etc/fwguard-ipset/config /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/iptables/ipsets /etc/iptables/ipsets.rules /etc/systemd/system/fwguard-ipset-restore.service /etc/systemd/system/fwguard-ipset-refresh.service /etc/systemd/system/fwguard-ipset-refresh.timer /etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf"
      ;;
    *)
      echo ""
      ;;
  esac
}

backup_step() {
  local step="$1"
  local ts dir paths
  ts="$(date +%F_%H-%M-%S)"
  dir="$BACKUP_ROOT/step${step}_$ts"
  paths="$(backup_paths_for_step "$step")"

  mkdir -p "$dir"
  if [ -n "$paths" ]; then
    for p in $paths; do
      if [ -e "$p" ]; then
        mkdir -p "$dir$(dirname "$p")"
        cp -a "$p" "$dir$p"
      fi
    done
  fi

  echo "$dir" > "$BACKUP_ROOT/step${step}_latest"
  echo "✔ 步骤 $step 备份完成：$dir"
}

restore_from_backup() {
  local step="$1"
  local marker dir
  marker="$BACKUP_ROOT/step${step}_latest"

  if [ ! -f "$marker" ]; then
    echo "[WARN] 步骤 $step 没有可用备份"
    return 1
  fi

  dir="$(cat "$marker")"
  if [ ! -d "$dir" ]; then
    echo "[WARN] 备份目录不存在：$dir"
    return 1
  fi

  case "$step" in
    1)
      [ -f "$dir/etc/ssh/sshd_config" ] && cp -a "$dir/etc/ssh/sshd_config" /etc/ssh/sshd_config
      sshd -t && (systemctl restart ssh || systemctl restart sshd)
      ;;
    2)
      systemctl stop set-cake.service >/dev/null 2>&1 || true
      systemctl disable set-cake.service >/dev/null 2>&1 || true
      [ -f "$dir/usr/local/bin/set-cake.sh" ] && cp -a "$dir/usr/local/bin/set-cake.sh" /usr/local/bin/set-cake.sh
      [ -f "$dir/etc/systemd/system/set-cake.service" ] && cp -a "$dir/etc/systemd/system/set-cake.service" /etc/systemd/system/set-cake.service
      systemctl daemon-reload
      [ -f /etc/systemd/system/set-cake.service ] && systemctl enable --now set-cake.service >/dev/null 2>&1 || true
      ;;
    3)
      [ -f "$dir/etc/fail2ban/jail.local" ] && cp -a "$dir/etc/fail2ban/jail.local" /etc/fail2ban/jail.local
      [ -f "$dir/etc/fail2ban/filter.d/sshd-disconnect.conf" ] && cp -a "$dir/etc/fail2ban/filter.d/sshd-disconnect.conf" /etc/fail2ban/filter.d/sshd-disconnect.conf
      systemctl restart fail2ban >/dev/null 2>&1 || true
      ;;
    5)
      systemctl stop cn-ipset >/dev/null 2>&1 || true
      systemctl disable cn-ipset >/dev/null 2>&1 || true
      iptables -D INPUT -p icmp -m set --match-set fwguard_cn_ipv4 src -j DROP >/dev/null 2>&1 || true
      ipset flush fwguard_cn_ipv4 >/dev/null 2>&1 || true
      ipset destroy fwguard_cn_ipv4 >/dev/null 2>&1 || true
      [ -f "$dir/usr/local/bin/update-cn-ipset.sh" ] && cp -a "$dir/usr/local/bin/update-cn-ipset.sh" /usr/local/bin/update-cn-ipset.sh
      [ -f "$dir/etc/systemd/system/cn-ipset.service" ] && cp -a "$dir/etc/systemd/system/cn-ipset.service" /etc/systemd/system/cn-ipset.service
      systemctl daemon-reload
      [ -f /etc/systemd/system/cn-ipset.service ] && systemctl enable --now cn-ipset >/dev/null 2>&1 || true
      ;;
    6)
      iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
      iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
      ip6tables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
      ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu >/dev/null 2>&1 || true
      netfilter-persistent save >/dev/null 2>&1 || true
      ;;
    7)
      if [ -x /usr/local/sbin/fwguard-firewall ]; then
        /usr/local/sbin/fwguard-firewall rollback
      else
        systemctl disable --now fwguard-ipset-refresh.timer >/dev/null 2>&1 || true
        systemctl disable --now fwguard-ipset-restore.service >/dev/null 2>&1 || true
        [ -f "$dir/usr/local/sbin/fwguard-firewall" ] && mkdir -p /usr/local/sbin && cp -a "$dir/usr/local/sbin/fwguard-firewall" /usr/local/sbin/fwguard-firewall
        [ -f "$dir/etc/fwguard-ipset/config" ] && mkdir -p /etc/fwguard-ipset && cp -a "$dir/etc/fwguard-ipset/config" /etc/fwguard-ipset/config
        [ -f "$dir/etc/iptables/rules.v4" ] && mkdir -p /etc/iptables && cp -a "$dir/etc/iptables/rules.v4" /etc/iptables/rules.v4
        [ -f "$dir/etc/iptables/rules.v6" ] && mkdir -p /etc/iptables && cp -a "$dir/etc/iptables/rules.v6" /etc/iptables/rules.v6
        [ -f "$dir/etc/iptables/ipsets" ] && mkdir -p /etc/iptables && cp -a "$dir/etc/iptables/ipsets" /etc/iptables/ipsets
        [ -f "$dir/etc/iptables/ipsets.rules" ] && mkdir -p /etc/iptables && cp -a "$dir/etc/iptables/ipsets.rules" /etc/iptables/ipsets.rules
        [ -f "$dir/etc/systemd/system/fwguard-ipset-restore.service" ] && cp -a "$dir/etc/systemd/system/fwguard-ipset-restore.service" /etc/systemd/system/fwguard-ipset-restore.service
        [ -f "$dir/etc/systemd/system/fwguard-ipset-refresh.service" ] && cp -a "$dir/etc/systemd/system/fwguard-ipset-refresh.service" /etc/systemd/system/fwguard-ipset-refresh.service
        [ -f "$dir/etc/systemd/system/fwguard-ipset-refresh.timer" ] && cp -a "$dir/etc/systemd/system/fwguard-ipset-refresh.timer" /etc/systemd/system/fwguard-ipset-refresh.timer
        [ -f "$dir/etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf" ] && mkdir -p /etc/systemd/system/netfilter-persistent.service.d && cp -a "$dir/etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf" /etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf
        systemctl daemon-reload
        [ -f /etc/iptables/ipsets ] && ipset restore -exist < /etc/iptables/ipsets >/dev/null 2>&1 || true
        [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4 >/dev/null 2>&1 || true
        [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6 >/dev/null 2>&1 || true
        [ -f /etc/systemd/system/fwguard-ipset-restore.service ] && systemctl enable --now fwguard-ipset-restore.service >/dev/null 2>&1 || true
        [ -f /etc/systemd/system/fwguard-ipset-refresh.timer ] && systemctl enable --now fwguard-ipset-refresh.timer >/dev/null 2>&1 || true
      fi
      ;;
    *)
      echo "[WARN] 当前仅支持回滚步骤 1/2/3/5/6/7"
      return 1
      ;;
  esac

  echo "✅ 步骤 $step 已从备份恢复"
}

rollback_menu() {
  echo
  echo "====== 撤销修改菜单 ======"
  echo "1) 撤销 SSH 安全配置"
  echo "2) 撤销 CAKE 配置"
  echo "3) 撤销 Fail2Ban 配置"
  echo "5) 撤销 中国 IP ICMP 屏蔽"
  echo "6) 撤销 PMTU MSS 设置"
  echo "7) 撤销 Cloudflare SSH 防火墙规则"
  echo "0) 返回"
  read -rp "请选择要撤销的步骤: " rb
  case "$rb" in
    1|2|3|5|6|7)
      restore_from_backup "$rb"
      ;;
    0)
      ;;
    *)
      echo "[WARN] 无效选择"
      ;;
  esac
}

run_step() {
  local step="$1"
  local script="$2"

  backup_step "$step"
  echo
  echo ">>> 准备执行: $script"
  wget -q -O "$WORKDIR/$script" "$REPO_RAW/$script"
  chmod +x "$WORKDIR/$script"
  "$WORKDIR/$script"
  echo ">>> $script 执行完成"
}

run_script_without_backup() {
  local script="$1"

  echo
  echo ">>> 准备执行: $script"
  wget -q -O "$WORKDIR/$script" "$REPO_RAW/$script"
  chmod +x "$WORKDIR/$script"
  "$WORKDIR/$script"
  echo ">>> $script 执行完成"
}

VERSION="1.0.15"

while true; do
  echo
  echo "=============================="
  echo "版本: $VERSION"
  echo " SSH Secure Toolkit"
  echo "=============================="
  echo "1) SSH 安全配置"
  echo "2) CAKE 队列配置"
  echo "3) Fail2Ban 防爆破（非常严格）"
  echo "4) XanMod Cloud 精简内核安装"
  echo "5) 中国 IP ICMP 屏蔽（ipset + systemd）"
  echo "6) PMTU MSS 自动修正（iptables mangle）"
  echo "7) Cloudflare ASN SSH 白名单 + 中国 ICMP 屏蔽"
  echo "8) 全部执行"
  echo "9) 撤销修改（从最近备份恢复）"
  echo "0) 退出"
  echo
  read -rp "请选择要执行的操作 [0-9]: " choice

  case "$choice" in
    1)
      run_step 1 "sshd-secure-setup.sh"
      ;;
    2)
      run_step 2 "cake.sh"
      ;;
    3)
      run_step 3 "fail2ban.sh"
      ;;
    4)
      echo "[INFO] XanMod 安装不提供自动回滚，继续执行。"
      run_script_without_backup "xanmod.sh"
      ;;
    5)
      run_step 5 "cn-ipset.sh"
      ;;
    6)
      run_step 6 "pmtu-mss.sh"
      ;;
    7)
      run_step 7 "cloudflare-ssh.sh"
      ;;
    8)
      run_step 1 "sshd-secure-setup.sh"
      run_step 2 "cake.sh"
      run_step 3 "fail2ban.sh"
      echo "[INFO] XanMod 安装不提供自动回滚，继续执行。"
      run_script_without_backup "xanmod.sh"
      run_step 5 "cn-ipset.sh"
      run_step 6 "pmtu-mss.sh"
      run_step 7 "cloudflare-ssh.sh"
      ;;
    9)
      rollback_menu
      ;;
    0)
      echo "退出"
      exit 0
      ;;
    *)
      echo "[WARN] 无效选择，请重新输入"
      ;;
  esac
done
