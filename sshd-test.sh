#!/usr/bin/env bash
set -e

[[ $EUID -ne 0 ]] && echo "必须使用 root 运行" && exit 1

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%F_%H-%M-%S)"

echo "====== SSHD 安全配置 ======"

# ==================================================
# 生成 Host Key
# ==================================================

echo "检查 SSH Host Keys..."

generate_key() {
    local type=$1
    local file=$2

    if [[ ! -f "$file" ]]; then
        echo "生成 $type HostKey..."
        ssh-keygen -t "$type" -f "$file" -N "" -q
        chmod 600 "$file"
        chmod 644 "${file}.pub"
    else
        echo "$type HostKey 已存在"
    fi
}


generate_key ed25519 /etc/ssh/ssh_host_ed25519_key
generate_key rsa     /etc/ssh/ssh_host_rsa_key


# ==================================================
# 交互配置
# ==================================================

read -rp "SSH监听端口 [22222]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22222}


echo
echo "Root 登录策略:"
echo "1) 禁止 root 登录"
echo "2) root 仅密钥登录"
echo "3) root 密码+密钥"

read -rp "选择 [2]: " ROOT_MODE
ROOT_MODE=${ROOT_MODE:-2}


case "$ROOT_MODE" in
1)
    PERMIT_ROOT="no"
    ;;
2)
    PERMIT_ROOT="prohibit-password"
    ;;
3)
    PERMIT_ROOT="yes"
    ;;
*)
    echo "错误选择"
    exit 1
    ;;
esac


read -rp "允许普通用户密码登录？[no]: " USER_PASS
USER_PASS=${USER_PASS:-no}


read -rp "启用 GSSAPI Kerberos？[no]: " GSSAPI
GSSAPI=${GSSAPI:-no}


read -rp "启用 X11 Forwarding？[no]: " X11
X11=${X11:-no}


echo
read -rp "启用 SSH 转发(-L/-D/-R)？[no]: " ENABLE_FORWARD
ENABLE_FORWARD=${ENABLE_FORWARD:-no}


if [[ "$ENABLE_FORWARD" == "yes" ]]; then

    ALLOW_TCP_FORWARD="yes"

    read -rp "允许 GatewayPorts？[no]: " ENABLE_GATEWAY
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


read -rp "启用 SSH 压缩？[no]: " COMPRESS
COMPRESS=${COMPRESS:-no}


read -rp "最大认证次数 [3]: " MAX_TRIES
MAX_TRIES=${MAX_TRIES:-3}


read -rp "启用 KeepAlive？[yes]: " KEEPALIVE
KEEPALIVE=${KEEPALIVE:-yes}



# ==================================================
# 备份
# ==================================================

cp "$SSHD_CONFIG" "$BACKUP"

echo "备份:"
echo "$BACKUP"



# ==================================================
# 写入配置
# ==================================================

cat > "$SSHD_CONFIG" <<EOF

Include /etc/ssh/sshd_config.d/*.conf


# =========================
# 基础配置
# =========================

Port $SSH_PORT

Protocol 2


# =========================
# 登录认证
# =========================

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



# =========================
# KeepAlive
# =========================

ClientAliveInterval $( [[ "$KEEPALIVE" == "yes" ]] && echo 300 || echo 0 )

ClientAliveCountMax 2



# =========================
# Forward
# =========================

AllowAgentForwarding no

AllowTcpForwarding $ALLOW_TCP_FORWARD

GatewayPorts $GATEWAY_PORTS

PermitTunnel no


# =========================
# X11
# =========================

X11Forwarding $X11


# =========================
# Compression
# =========================

Compression $COMPRESS



# =========================
# Host Key
# =========================

HostKey /etc/ssh/ssh_host_ed25519_key

HostKey /etc/ssh/ssh_host_rsa_key



# =========================
# Key Exchange
# =========================

KexAlgorithms curve25519-sha256



# =========================
# Encryption
# =========================

Ciphers aes256-gcm@openssh.com,aes256-ctr



# =========================
# MAC
# =========================

MACs hmac-sha2-512@openssh.com



# =========================
# Server HostKey Algorithm
# =========================

HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256



# =========================
# User PublicKey Algorithm
# =========================

PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256



# =========================
# GSSAPI
# =========================

GSSAPIAuthentication $GSSAPI

GSSAPIKeyExchange no



# =========================
# Logging
# =========================

SyslogFacility AUTH

LogLevel VERBOSE



# =========================
# SFTP
# =========================

Subsystem sftp /usr/lib/openssh/sftp-server


AcceptEnv LANG LC_*

EOF



# ==================================================
# 检查
# ==================================================

echo
echo "检查 SSH 配置..."

if ! sshd -t; then

    echo "配置错误，恢复备份"

    cp "$BACKUP" "$SSHD_CONFIG"

    exit 1

fi



systemctl restart ssh 2>/dev/null || systemctl restart sshd


echo
echo "================================"
echo " SSHD 配置完成"
echo "================================"

echo "端口: $SSH_PORT"
echo "Root: $PERMIT_ROOT"
echo "Forward: $ALLOW_TCP_FORWARD"
echo "Cipher: aes256-gcm@openssh.com,aes256-ctr"
echo "KEX: curve25519-sha256"
echo "MAC: hmac-sha2-512@openssh.com"

echo
echo "请保持当前连接，新开终端测试。"
