#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/avsba001/ssh-secure/main"
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

while true; do
  echo
  echo "=============================="
  echo " SSH Secure Toolkit"
  echo "=============================="
  echo "1) SSH 安全配置"
  echo "2) CAKE 队列配置"
  echo "3) Fail2Ban 防爆破"
  echo "4) 全部执行"
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
      run_script "sshd-secure-setup.sh"
      run_script "cake.sh"
      run_script "fail2ban.sh"
      ;;
    0)
      echo "退出"
      exit 0
      ;;
    *)
      echo "[WARN] 无效选择，请重新输入
