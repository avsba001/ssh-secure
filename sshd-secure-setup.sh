#!/usr/bin/env bash
set -e

[[ $EUID -ne 0 ]] && echo "必须使用 root 运行" && exit 1

# ===== 确保 SSH Host Keys 存在 =====
echo "检查 SSH Host Keys..."

generate_key () {
  local type=$1
  local file=$2

  if [[ ! -f "$file" ]]; then
    echo "⚠ 缺少 $type HostKey，正在生成..."
    ssh-keygen -t "$type" -f "$file" -N "" -q
    chmod 600 "$file"
    chmod 644 "${file}.pub"
    echo "✔ 已生成 $file"
  else
    echo "✔ $type HostKey 已存在"
  fi
}

generate_key ed25519 /etc/ssh/ssh_host_ed25519_key
generate_key ecdsa   /etc/ssh/ssh_host_ecdsa_key
generate_key rsa     /etc/ssh/ssh_host_rsa_key


[[ $EUID -ne 0 ]] && echo "必须使用 root 运行" && exit 1

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%T)"

echo "====== SSHD 一键交互式安全配置 ======"
echo

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

# ===== SSH 转发 / 网关 =====
echo
read -rp "是否启用 SSH 转发 / 网关功能（-L/-D/-R）？[no]: " ENABLE_FORWARD
ENABLE_FORWARD=${ENABLE_FORWARD:-no}

if [[ "$ENABLE_FORWARD" == "yes" ]]; then
  ALLOW_TCP_FORWARD="yes"

  read -rp "是否允许远程端口转发（-R / GatewayPorts）？[no]: " ENABLE_GATEWAY
  ENABLE_GATEWAY=${ENABLE_GATEWAY:-no}

  if [[ "$ENABLE_GATEWAY" == "yes" ]]; then
    GATEWAY_PORTS="clientspecified"
  else
    GATEWAY_PORTS="no"
  fi
else
  ALLOW_TCP_FORWARD="no"
  GATEWAY_PORTS="no"
fi

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
AllowTcpForwarding $ALLOW_TCP_FORWARD
GatewayPorts $GATEWAY_PORTS
X11Forwarding $X11
PermitTunnel no

Compression $COMPRESS

# ===== 加密算法 =====
KexAlgorithms sntrup761x25519-sha512,curve25519-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com

HostKey /etc/ssh/ssh_host_ed25519_key
HostKeyAlgorithms ssh-ed25519
PubkeyAcceptedAlgorithms ssh-ed25519

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
echo "SSH 转发: $ALLOW_TCP_FORWARD"
echo "GatewayPorts: $GATEWAY_PORTS"
echo
echo "⚠️ 请新开终端测试后再断开当前连接"
