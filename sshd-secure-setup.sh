#!/usr/bin/env bash
set -e

[[ $EUID -ne 0 ]] && echo "必须使用 root 运行" && exit 1

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%T)"

echo "====== SSHD 一键交互式安全配置 ======"
echo

# ===== SSH 端口 =====
read -rp "SSH 监听端口 [22222]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22222}

# ===== Root 登录模式 =====
echo
echo "Root 登录策略："
echo "  1) 禁止 root 登录"
echo "  2) root 仅允许密钥登录（推荐）"
echo "  3) root 允许 密码 + 密钥（兼容默认 VPS）"
read -rp "请选择 [2]: " ROOT_MODE
ROOT_MODE=${ROOT_MODE:-2}

case "$ROOT_MODE" in
  1)
    PERMIT_ROOT="no"
    ROOT_PASSWORD="no"
    ;;
  2)
    PERMIT_ROOT="prohibit-password"
    ROOT_PASSWORD="no"
    ;;
  3)
    PERMIT_ROOT="yes"
    ROOT_PASSWORD="yes"
    ;;
  *)
    echo "无效选择"; exit 1 ;;
esac

# ===== 普通用户密码登录 =====
read -rp "是否允许普通用户密码登录？[no]: " USER_PASS
USER_PASS=${USER_PASS:-no}

# ===== GSSAPI =====
read -rp "是否启用 GSSAPI（Kerberos）？[no]: " GSSAPI
GSSAPI=${GSSAPI:-no}

# ===== X11 =====
read -rp "是否启用 X11Forwarding？[no]: " X11
X11=${X11:-no}

# ===== TCP 转发 =====
read -rp "是否允许 TCP 转发？[no]: " TCP_FORWARD
TCP_FORWARD=${TCP_FORWARD:-no}

# ===== 压缩 =====
read -rp "是否启用 SSH 压缩？[no]: " COMPRESS
COMPRESS=${COMPRESS:-no}

# ===== 最大尝试 =====
read -rp "最大认证失败次数 [3]: " MAX_TRIES
MAX_TRIES=${MAX_TRIES:-3}

# ===== KeepAlive =====
read -rp "是否启用 KeepAlive 防止掉线？[yes]: " KEEPALIVE
KEEPALIVE=${KEEPALIVE:-yes}

# ===== 备份 =====
cp "$SSHD_CONFIG" "$BACKUP"
echo "✔ 已备份原配置：$BACKUP"

# ===== 写入配置 =====
cat > "$SSHD_CONFIG" <<EOF
Include /etc/ssh/sshd_config.d/*.conf

Port $SSH_PORT
Protocol 2

PermitRootLogin $PERMIT_ROOT
PubkeyAuthentication yes
PasswordAuthentication $USER_PASS
UsePAM yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

LoginGraceTime 30
MaxAuthTries $MAX_TRIES
MaxSessions 10
StrictModes yes
PermitEmptyPasswords no

ClientAliveInterval $( [[ $KEEPALIVE == yes ]] && echo 300 || echo 0 )
ClientAliveCountMax 2

AllowAgentForwarding no
AllowTcpForwarding $TCP_FORWARD
X11Forwarding $X11
PermitTunnel no
GatewayPorts no

Compression $COMPRESS

# ===== 加密算法 =====
KexAlgorithms curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKeyAlgorithms ssh-ed25519
PubkeyAcceptedAlgorithms ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256

# ===== GSSAPI =====
GSSAPIAuthentication $GSSAPI
GSSAPIKeyExchange no

SyslogFacility AUTH
LogLevel VERBOSE

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# ===== root 密码兼容 =====
if [[ "$ROOT_PASSWORD" == "yes" ]]; then
  sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
fi

# ===== 校验 =====
echo
echo "校验 sshd 配置..."
if ! sshd -t; then
  echo "❌ 校验失败，已恢复原配置"
  cp "$BACKUP" "$SSHD_CONFIG"
  exit 1
fi

systemctl restart ssh || systemctl restart sshd

echo
echo "✅ SSHD 配置完成"
echo "端口: $SSH_PORT"
echo "Root 登录: $PERMIT_ROOT"
echo "普通用户密码登录: $USER_PASS"
echo
echo "⚠️ 请新开终端测试后再断开当前连接"
