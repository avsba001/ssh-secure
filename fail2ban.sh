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
rm -rf /etc/ipset/f2b-counters

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
        echo "❌ 5秒内无法 ping 通 1.1.1.1，已自动恢复之前配置"
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
    echo "===> 清理旧版 fail2ban 残留配置"

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
        find /etc/fail2ban/jail.d -maxdepth 1 -type f \( -name 'sshd-disconnect.conf' -o -name 'fail2ban-custom.conf' -o -name 'legacy-sshd.conf' \) -print -delete || true
    fi
}

echo "===> 安装依赖（fail2ban/ufw/ipset/rsyslog）"
apt update
apt install -y rsyslog ufw fail2ban ipset

mkdir -p /etc/ipset
backup_existing_configs
cleanup_legacy_fail2ban_configs

# ==================== 核心逻辑：双层动态智能 IPset 挂载引擎 ====================
cat > /usr/local/bin/f2b-ipset-ensure.sh << 'EOS'
#!/bin/bash
set -euo pipefail

# 单 IP 追踪已被彻底取消，全部采用 hash:net 架构
IPSET_FILE="/etc/ipset/f2b-ipset.rules"
# 常规封禁：/24 C段网段
IPSET_NET24="f2b-blacklist24"
# 晋升封禁：/16 B段网段
IPSET_NET16="f2b-blacklist16"
# 计数缓存目录
COUNTER_DIR="/etc/ipset/f2b-counters"

ensure_sets() {
    ipset create "${IPSET_NET24}" hash:net family inet timeout 0 -exist
    ipset create "${IPSET_NET16}" hash:net family inet timeout 0 -exist
}

ensure_ufw_rules() {
    local chain="ufw-before-input"
    # /16 优先级最高，挂载在最顶部
    iptables -C "${chain}" -m set --match-set "${IPSET_NET16}" src -j DROP >/dev/null 2>&1 || \
    iptables -I "${chain}" 1 -m set --match-set "${IPSET_NET16}" src -j DROP

    # /24 紧随其后
    iptables -C "${chain}" -m set --match-set "${IPSET_NET24}" src -j DROP >/dev/null 2>&1 || \
    iptables -I "${chain}" 2 -m set --match-set "${IPSET_NET24}" src -j DROP
}

save_sets() {
    ipset save "${IPSET_NET16}" > "${IPSET_FILE}.16.tmp"
    ipset save "${IPSET_NET24}" > "${IPSET_FILE}.24.tmp"
    cat "${IPSET_FILE}.16.tmp" "${IPSET_FILE}.24.tmp" > "${IPSET_FILE}.tmp"
    mv "${IPSET_FILE}.tmp" "${IPSET_FILE}"
    rm -f "${IPSET_FILE}.16.tmp" "${IPSET_FILE}.24.tmp"
}

restore_sets() {
    ensure_sets
    if [ -s "${IPSET_FILE}" ]; then
        ipset restore -exist < "${IPSET_FILE}"
    fi
}

add_ip() {
    local ip="$2"
    local slash24
    local slash16
    slash24="$(echo "${ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
    slash16="$(echo "${ip}" | awk -F. '{print $1"."$2".0.0/16"}')"

    ensure_sets
    mkdir -p "${COUNTER_DIR}"
    local safe_slash16="${slash16/\//_}"
    local counter_file="${COUNTER_DIR}/${safe_slash16}"

    # 记录当前恶意 IP，去重写入以精准统计该 /16 内不同的恶意触发源
    if [ -f "${counter_file}" ]; then
        if ! grep -q "^${ip}$" "${counter_file}"; then
            echo "${ip}" >> "${counter_file}"
        fi
    else
        echo "${ip}" >> "${counter_file}"
    fi

    local hits
    hits=$(wc -l < "${counter_file}")

    # 💡 核心阈值判断：如果同个 /16 网段触发次数大于等于 5 次
    if [ "${hits}" -ge 5 ]; then
        # 1. 晋升：封禁整个 /16 网段
        ipset add "${IPSET_NET16}" "${slash16}" -exist

        # 2. 极致优化：既然已经封禁了 /16，就把该网段内原先单独存在的 /24 规则全部从内存擦除，释放资源
        while read -r active_ip || [ -n "${active_ip}" ]; do
            local active_s24
            active_s24="$(echo "${active_ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
            ipset del "${IPSET_NET24}" "${active_s24}" 2>/dev/null || true
        done < "${counter_file}"
    else
        # 否则：保持封禁其所属的 /24 网段
        ipset add "${IPSET_NET24}" "${slash24}" -exist
    fi

    ensure_ufw_rules
    save_sets
}

remove_ip() {
    local ip="$2"
    local slash24
    local slash16
    slash24="$(echo "${ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
    slash16="$(echo "${ip}" | awk -F. '{print $1"."$2".0.0/16"}')"

    ensure_sets
    mkdir -p "${COUNTER_DIR}"
    local safe_slash16="${slash16/\//_}"
    local counter_file="${COUNTER_DIR}/${safe_slash16}"

    if [ -f "${counter_file}" ]; then
        # 从缓存计数器中移除此解封 IP
        sed -i "/^${ip}$/d" "${counter_file}"
        
        local hits
        hits=$(wc -l < "${counter_file}")

        if [ "${hits}" -ge 5 ]; then
            # 即使解封一个，剩余攻击源依然超过阈值，保持 /16 封禁
            ipset add "${IPSET_NET16}" "${slash16}" -exist
        elif [ "${hits}" -gt 0 ]; then
            # 降级自愈：活跃攻击源降到 5 次以下，解除 /16 大网段封禁，将剩下还在租约内的 IP 退回到各自的 /24 封禁
            ipset del "${IPSET_NET16}" "${slash16}" 2>/dev/null || true
            while read -r active_ip || [ -n "${active_ip}" ]; do
                local active_s24
                active_s24="$(echo "${active_ip}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
                ipset add "${IPSET_NET24}" "${active_s24}" -exist
            done < "${counter_file}"
        else
            # 该 /16 干净了，彻底全部解封
            ipset del "${IPSET_NET16}" "${slash16}" 2>/dev/null || true
            ipset del "${IPSET_NET24}" "${slash24}" 2>/dev/null || true
            rm -f "${counter_file}"
        fi
    else
        ipset del "${IPSET_NET16}" "${slash16}" 2>/dev/null || true
        ipset del "${IPSET_NET24}" "${slash24}" 2>/dev/null || true
    fi

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
        add_ip "$@"
        ;;
    remove)
        remove_ip "$@"
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
failregex =^.sshd(?:\[\d+\])?: Invalid user .* from <HOST>(?: port \d+)?(?: ssh\d+)?\s*$
^.sshd(?:\[\d+\])?: Failed password for (?Valid user )?.* from <HOST> port \d+(?: ssh\d+)?\s*$
^.sshd(?:\[\d+\])?: Did not receive identification string from <HOST>\s*$
^.sshd(?:\[\d+\])?: Connection closed by (?Valid user )?.* <HOST> port \d+ \[preauth\]\s*$
^.sshd(?:\[\d+\])?: kex_exchange_identification: .* <HOST> port \d+\s*$
^.sshd(?:\[\d+\])?: banner exchange: Connection from <HOST> port \d+:.*\s*$
ignoreregex =
EOF4

JAIL_LOCAL="/etc/fail2ban/jail.local"
if [ -f "${JAIL_LOCAL}" ]; then
    cp "${JAIL_LOCAL}" "${JAIL_LOCAL}.$(date +%F_%H-%M-%S).bak"
fi

# ==================== 恢复标准 Fail2Ban 监测参数 ====================
cat > "${JAIL_LOCAL}" << 'EOF5'
[DEFAULT]
bantime  = 7d
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8
banaction = ufw-ipset-persistent

[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/auth.log
backend  = auto
maxretry = 3
findtime = 15m
bantime  = 30d

[sshd-aggressive]
enabled  = true
filter   = sshd-aggressive
port     = ssh
logpath  = /var/log/auth.log
backend  = auto
maxretry = 2
findtime = 20m
bantime  = 365d
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
fail2ban-client status ssh
fail2ban-client status sshd-aggressive

verify_network_or_restore

echo "=========================================================="
echo "✅ 渐进式双层封禁系统部署成功！"
echo "  1) 默认封禁结构：依然对恶意源执行精密、安全的 /24 窄网段阻断。"
echo "  2) B段升级机制：当同网段 /16 内累积触发满 3 次时，立即升级为 /16 大网段全封禁。"
echo "  3) 极致优化：升级到 /16 后，内存中对应的 /24 零散规则将被自动擦除清理。"
echo "  4) 降级解封：租约到期后自动减数，若脱离危险期自动退回 /24 级封禁，智能优雅。"
echo "=========================================================="
