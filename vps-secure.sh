#!/bin/bash
set -e

### ===== 基本信息 =====
SCRIPT_NAME="vps-secure.sh"
REPO_RAW="https://raw.githubusercontent.com/avsba001/vps-secure/main"
LOCAL_VERSION="1.0.5"

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
mkdir -p "$WORKDIR"

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] 请使用 root 运行"
  exit 1
fi

run_script() {
  local script="$1"

  echo
  echo ">>> 准备执行: $script"
  wget -q -O "$WORKDIR/$script" "$REPO_RAW/$script"
  chmod +x "$WORKDIR/$script"

  "$WORKDIR/$script"
  echo ">>> $script 执行完成"
}

VERSION="1.0.5"

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
  echo "5) 全部执行"
  echo "0) 退出"
  echo
  read -rp "请选择要执行的操作 [0-4]: " choice

  case "$choice" in
    1)
      run_script "sshd-secure-setup.sh"
      ;;
    2)
      run_script "cake.sh"
      ;;
    3)
      run_script "fail2ban.sh"
      ;;
    4)
      run_script "xanmod.sh"
      ;;
    5)
      run_script "sshd-secure-setup.sh"
      run_script "cake.sh"
      run_script "fail2ban.sh"
      run_script "xanmod.sh"
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
