#!/bin/bash
set -e

### ===== 基本信息 =====
SCRIPT_NAME="vps-secure.sh"
REPO_RAW="https://raw.githubusercontent.com/avsba001/vps-secure/main"
LOCAL_VERSION="1.0.13"

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
      iptables -D INPUT -p icmp -m set --match-set cn src -j DROP >/dev/null 2>&1 || true
      ipset flush cn >/dev/null 2>&1 || true
      ipset destroy cn >/dev/null 2>&1 || true
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
    *)
      echo "[WARN] 当前仅支持回滚步骤 1/2/3/5/6"
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
  echo "0) 返回"
  read -rp "请选择要撤销的步骤: " rb
  case "$rb" in
    1|2|3|5|6)
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

VERSION="1.0.13"

while true; do
  echo
  echo "=============================="
  echo "版本: $VERSION"
  echo " SSH Secure Toolkit"
  echo "=============================="
  echo "1) SSH 安全配置"
  echo "2) CAKE 队列配置"
  echo "3) Fail2Ban 防爆破"
  echo "4) XanMod Cloud 精简内核安装"
  echo "5) 中国 IP ICMP 屏蔽（ipset + systemd）"
  echo "6) PMTU MSS 自动修正（iptables mangle）"
  echo "7) 全部执行"
  echo "8) 撤销修改（从最近备份恢复）"
  echo "0) 退出"
  echo
  read -rp "请选择要执行的操作 [0-8]: " choice

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
      echo
      echo ">>> 准备执行: xanmod.sh"
      wget -q -O "$WORKDIR/xanmod.sh" "$REPO_RAW/xanmod.sh"
      chmod +x "$WORKDIR/xanmod.sh"
      "$WORKDIR/xanmod.sh"
      echo ">>> xanmod.sh 执行完成"
      ;;
    5)
      run_step 5 "cn-ipset.sh"
      ;;
    6)
      run_step 6 "pmtu-mss.sh"
      ;;
    7)
      run_step 1 "sshd-secure-setup.sh"
      run_step 2 "cake.sh"
      run_step 3 "fail2ban.sh"
      echo "[INFO] XanMod 安装不提供自动回滚，继续执行。"
      echo
      echo ">>> 准备执行: xanmod.sh"
      wget -q -O "$WORKDIR/xanmod.sh" "$REPO_RAW/xanmod.sh"
      chmod +x "$WORKDIR/xanmod.sh"
      "$WORKDIR/xanmod.sh"
      echo ">>> xanmod.sh 执行完成"
      run_step 5 "cn-ipset.sh"
      run_step 6 "pmtu-mss.sh"
      ;;
    8)
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
