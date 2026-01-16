#!/bin/bash
# 一键配置 CAKE 队列 + systemd 服务

SERVICE_FILE="/etc/systemd/system/set-cake.service"
SCRIPT_FILE="/usr/local/bin/set-cake.sh"

echo "=== CAKE 队列一键配置脚本 ==="

# 交互输入网卡接口
read -rp "请输入要配置的网卡接口 (默认 eth0): " IFACE_INPUT
IFACE="${IFACE_INPUT:-eth0}"

# 交互输入 NAT 模式
read -rp "请确认是否为 NAT 机器？(y=是 / n=不是) [默认: n]: " NAT_CHOICE
case "$NAT_CHOICE" in
    [Yy]) NAT_MODE="nat" ;;
    [Nn]|"") NAT_MODE="nonat" ;;
    *) echo "输入无效，默认使用 nonat"; NAT_MODE="nonat" ;;
esac

# 交互输入延迟
read -rp "请输入网络延迟 (仅输入数字，单位为 ms) [默认: 100]: " RTT_INPUT
if [[ "$RTT_INPUT" =~ ^[0-9]+$ ]]; then
    RTT="${RTT_INPUT}ms"
else
    echo "输入无效，使用默认 100ms"
    RTT="100ms"
fi

# 交互输入带宽
echo "带宽单位支持：mbit / gbit"
read -rp "请输入带宽数值 (仅输入数字) [默认: 600]: " BW_INPUT
read -rp "请选择带宽单位 (输入 m 代表 mbit / g 代表 gbit) [默认: m]: " BW_UNIT

# 数值检查
if [[ ! "$BW_INPUT" =~ ^[0-9]+$ ]]; then
    echo "输入无效，使用默认 600mbit"
    BW="600mbit"
else
    case "$BW_UNIT" in
        [Gg]) BW="${BW_INPUT}gbit" ;;
        [Mm]|"") BW="${BW_INPUT}mbit" ;;
        *) echo "单位输入无效，使用默认 mbit"; BW="${BW_INPUT}mbit" ;;
    esac
fi

echo ""
echo "====== 配置信息确认 ======"
echo "  网卡接口 : $IFACE"
echo "  NAT 模式 : $NAT_MODE"
echo "  延迟     : $RTT"
echo "  带宽     : $BW"
echo "=========================="
echo ""

# 最终确认
read -rp "是否确认应用该配置？(y=确认 / n=取消): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 已取消配置，未做任何更改。"
    exit 1
fi

# 生成 /usr/local/bin/set-cake.sh
cat > "$SCRIPT_FILE" <<EOL
#!/bin/bash

IFACE="$IFACE"

# 删除旧的 qdisc（避免重复添加）
tc qdisc del dev "\$IFACE" root 2>/dev/null

# 添加 CAKE 队列规则
tc qdisc add dev "\$IFACE" root cake \\
    bandwidth $BW \\
    rtt $RTT \\
    diffserv3 \\
    $NAT_MODE \\
    triple-isolate \\
    ack-filter \\
    split-gso \\
    ethernet \\
    overhead 0 \\
    mpu 64 \\
    wash
EOL

chmod +x "$SCRIPT_FILE"

# 生成 systemd service 文件
cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Set CAKE Qdisc on $IFACE
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOL

# 应用 systemd
systemctl daemon-reload
systemctl enable set-cake.service
systemctl restart set-cake.service

echo "✅ CAKE 已配置并开机自启"
echo "可用命令："
echo "  systemctl status set-cake.service  # 查看运行状态"
echo "  tc -s qdisc show dev $IFACE        # 查看 CAKE 队列统计"
