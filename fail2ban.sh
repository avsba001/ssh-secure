#!/bin/bash
set -e

echo "===> 检查 root 权限"
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行：sudo bash setup-fail2ban.sh"
  exit 1
fi

echo "===> 更新系统并安装依赖"
apt update
apt install -y rsyslog ufw fail2ban ipset

echo "===> 创建 Fail2Ban 自定义过滤器 sshd-disconnect"
cat > /etc/fail2ban/filter.d/sshd-disconnect.conf << 'EOF'
[Definition]
failregex =
    ^.*sshd\[\d+\]: Invalid user .* from <HOST> port \d+.*$
    ^.*sshd\[\d+\]: Failed password for .* from <HOST> port \d+.*$
    ^.*sshd\[\d+\]: pam_unix\(sshd:auth\): authentication failure.*rhost=<HOST>.*$
    ^.*sshd\[\d+\]: Disconnected from (invalid user|authenticating user).* <HOST> port \d+.*$
    ^.*sshd\[\d+\]: Received disconnect from <HOST> port \d+:.*$
    ^.*sshd\[\d+\]: error: kex_exchange_identification: Connection closed by remote host.*$
    ^.*sshd\[\d+\]: Unable to negotiate with <HOST> port \d+:.*$
    ^.*sshd\[\d+\]: pam_unix\(sshd:auth\): authentication failure.*rhost=<HOST>.*$
    
ignoreregex = ^.+sshd\[\d+\]:\s+Accepted .+ from <HOST> port \d+ .*$
EOF

JAIL_LOCAL="/etc/fail2ban/jail.local"

echo "===> 处理 jail.local（备份 + 替换）"
if [ -f "$JAIL_LOCAL" ]; then
  BACKUP="${JAIL_LOCAL}.$(date +%F_%H-%M-%S).bak"
  cp "$JAIL_LOCAL" "$BACKUP"
  echo "已备份原 jail.local -> $BACKUP"
else
  echo "未发现 jail.local，将新建"
fi

cat > "$JAIL_LOCAL" << 'EOF'
#DEFAULT-START
[DEFAULT]
bantime  = 12h
findtime = 10m
maxretry = 5
banaction = iptables-ipset-proto4
action    = %(action_mwl)s
ignoreip  = 127.0.0.1/8
#DEFAULT-END

[sshd]
enabled  = true
filter   = sshd
port     = 22222
maxretry = 2
findtime = 10m
bantime  = 1d
logpath  = /var/log/auth.log

[sshd-disconnect]
enabled  = true
filter   = sshd-disconnect
logpath  = /var/log/auth.log
findtime = 10m
maxretry = 1
bantime  = 1d
EOF

echo "===> 启动并设置 Fail2Ban 开机自启"
systemctl enable fail2ban --now

echo "===> Fail2Ban 当前状态"
systemctl status fail2ban --no-pager

echo "===> 完成 ✅（配置已安全替换）"
