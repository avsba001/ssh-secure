#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CONFIG_PATH:-/etc/fwguard-ipset/config}"
STATE_DIR="${STATE_DIR:-/etc/fwguard-ipset}"
SSH_PORT="${SSH_PORT:-22}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
SSH_CN_WHITELIST_MODE="${SSH_CN_WHITELIST_MODE:-none}"
SSH_CN_PROVINCES="${SSH_CN_PROVINCES:-}"
CLOUDFLARE_ASNS="${CLOUDFLARE_ASNS:-AS13335 AS14789 AS132892 AS133877 AS202623 AS203898 AS209242 AS394536 AS395747 AS400095 AS402542}"

IPSET_CF4="fwguard_cloudflare_ipv4"
IPSET_CF6="fwguard_cloudflare_ipv6"
IPSET_SSH_CN4="fwguard_ssh_cn_ipv4"
IPSET_SSH_CN6="fwguard_ssh_cn_ipv6"
CHAIN_V4="SSH_CF_ASN_GUARD"
CHAIN_V6="SSH_CF_ASN_GUARD_V6"
SAMPLE_LIMIT="${SAMPLE_LIMIT:-10}"
CHECK_IP="${CHECK_IP:-}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "错误：请使用 root 用户运行此脚本。" >&2
  exit 1
fi

if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "错误：缺少命令：$1" >&2
    exit 1
  }
}

set_exists() {
  ipset list "$1" >/dev/null 2>&1
}

set_count() {
  local set_name="$1"
  if set_exists "$set_name"; then
    ipset list "$set_name" | awk -F': ' '/Number of entries/ {print $2}'
  else
    echo "0"
  fi
}

set_sample() {
  local set_name="$1"
  if set_exists "$set_name"; then
    ipset list "$set_name" | awk '/^Members:$/ {show=1; next} show && NF {print}' | head -n "$SAMPLE_LIMIT"
  fi
}

chain_exists() {
  "$1" -S "$2" >/dev/null 2>&1
}

chain_accepts_set() {
  local table_cmd="$1"
  local chain="$2"
  local set_name="$3"

  "$table_cmd" -S "$chain" 2>/dev/null | grep -F -- "--match-set $set_name src -j ACCEPT" >/dev/null 2>&1
}

input_policy() {
  local table_cmd="$1"

  "$table_cmd" -S INPUT 2>/dev/null | awk '/^-P INPUT / {print $3}'
}

input_jumps_to_chain() {
  local table_cmd="$1"
  local chain="$2"

  "$table_cmd" -S INPUT 2>/dev/null | grep -F -- "-j $chain" >/dev/null 2>&1
}

input_jumps_to_chain_for_port() {
  local table_cmd="$1"
  local chain="$2"
  local port="$3"

  "$table_cmd" -S INPUT 2>/dev/null | grep -F -- "-p tcp" | grep -F -- "--dport $port" | grep -F -- "-j $chain" >/dev/null 2>&1
}

print_input_rules_for_port() {
  local table_cmd="$1"
  local port="$2"

  "$table_cmd" -S INPUT 2>/dev/null | awk -v port="$port" '
    BEGIN { n = 0 }
    /^-A INPUT / {
      n++
      if ($0 ~ "-p tcp" && $0 ~ "--dport " port) {
        printf "  #%d %s\n", n, $0
      }
    }
  '
}

warn_early_accept_before_jump() {
  local table_cmd="$1"
  local chain="$2"
  local port="$3"

  "$table_cmd" -S INPUT 2>/dev/null | awk -v chain="$chain" -v port="$port" '
    BEGIN { n = 0; jump = 0; early = 0 }
    /^-A INPUT / {
      n++
      if ($0 ~ "-p tcp" && $0 ~ "--dport " port && $0 ~ "-j " chain) {
        jump = n
      }
      if (jump == 0 && $0 ~ "-p tcp" && $0 ~ "--dport " port && $0 ~ "-j ACCEPT") {
        early = 1
        printf "  [WARN] SSH 白名单跳转前已有 ACCEPT：#%d %s\n", n, $0
      }
    }
    END {
      if (jump == 0) {
        print "  [WARN] 未找到该 SSH 端口跳转到白名单链的规则。"
      } else {
        printf "  SSH 白名单跳转规则位置：#%d\n", jump
      }
      if (early == 0 && jump != 0) {
        print "  未发现位于白名单跳转前的同端口 ACCEPT。"
      }
    }
  '
}

print_listening_ssh_ports() {
  echo
  echo "== SSH 实际监听端口 =="
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk '
      NR == 1 || /sshd|:22 |:2222 |:22222 / {print}
    ' || true
  else
    echo "缺少 ss 命令，无法列出监听端口。"
  fi
  if command -v sshd >/dev/null 2>&1; then
    echo
    echo "sshd -T 中的端口："
    sshd -T 2>/dev/null | awk '/^port / {print "  " $0}' || true
  fi
}

print_firewall_context() {
  echo
  echo "== 防火墙上下文 =="
  echo "iptables INPUT 默认策略：$(input_policy iptables || echo 未知)"
  if command -v iptables >/dev/null 2>&1; then
    iptables -V 2>/dev/null || true
  fi
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>/dev/null || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | grep -E 'dport (22|2222|22222)|SSH_CF_ASN_GUARD|fwguard_cloudflare|fwguard_ssh_cn' | head -n 40 || true
  fi
}

print_path_diagnosis() {
  local family="$1"
  local table_cmd="$2"
  local chain="$3"
  local port="${SSH_PORT:-22}"

  echo
  echo "== $family SSH 放行路径诊断 =="
  if ! chain_exists "$table_cmd" "$chain"; then
    echo "[FAIL] 未发现 SSH 白名单链：$chain"
    echo "可能原因：cloudflare-ssh.sh 尚未成功应用，或规则已被其它防火墙工具覆盖。"
    return
  fi
  if input_jumps_to_chain_for_port "$table_cmd" "$chain" "$port"; then
    echo "[OK] INPUT 已将 tcp/$port 跳转到 $chain"
  else
    echo "[FAIL] INPUT 没有把 tcp/$port 跳转到 $chain"
    echo "如果 SSH 实际端口不是 $port，请重新运行 cloudflare-ssh.sh 并输入真实 SSH 端口。"
  fi
  echo "INPUT 中匹配 tcp/$port 的规则："
  print_input_rules_for_port "$table_cmd" "$port"
  warn_early_accept_before_jump "$table_cmd" "$chain" "$port"
  if [[ "$(input_policy "$table_cmd" || true)" == "ACCEPT" ]] && ! input_jumps_to_chain_for_port "$table_cmd" "$chain" "$port"; then
    echo "[WARN] INPUT 默认策略是 ACCEPT，且没有白名单跳转，未命中规则的 SSH 连接会被允许。"
  fi
}

test_ip_membership() {
  local ip="$1"

  echo
  echo "== 指定 IP 归属测试：$ip =="
  for set_name in "$IPSET_CF4" "$IPSET_CF6" "$IPSET_SSH_CN4" "$IPSET_SSH_CN6"; do
    if set_exists "$set_name"; then
      if ipset test "$set_name" "$ip" >/dev/null 2>&1; then
        echo "命中：$set_name"
      fi
    fi
  done
}

province_name() {
  case "$1" in
    110000) echo "北京(beijing)" ;;
    120000) echo "天津(tianjin)" ;;
    130000) echo "河北(hebei)" ;;
    140000) echo "山西(shanxi)" ;;
    150000) echo "内蒙古(neimenggu)" ;;
    210000) echo "辽宁(liaoning)" ;;
    220000) echo "吉林(jilin)" ;;
    230000) echo "黑龙江(heilongjiang)" ;;
    310000) echo "上海(shanghai)" ;;
    320000) echo "江苏(jiangsu)" ;;
    330000) echo "浙江(zhejiang)" ;;
    340000) echo "安徽(anhui)" ;;
    350000) echo "福建(fujian)" ;;
    360000) echo "江西(jiangxi)" ;;
    370000) echo "山东(shandong)" ;;
    410000) echo "河南(henan)" ;;
    420000) echo "湖北(hubei)" ;;
    430000) echo "湖南(hunan)" ;;
    440000) echo "广东(guangdong)" ;;
    450000) echo "广西(guangxi)" ;;
    460000) echo "海南(hainan)" ;;
    500000) echo "重庆(chongqing)" ;;
    510000) echo "四川(sichuan)" ;;
    520000) echo "贵州(guizhou)" ;;
    530000) echo "云南(yunnan)" ;;
    540000) echo "西藏(xizang)" ;;
    610000) echo "陕西(shaanxi)" ;;
    620000) echo "甘肃(gansu)" ;;
    630000) echo "青海(qinghai)" ;;
    640000) echo "宁夏(ningxia)" ;;
    650000) echo "新疆(xinjiang)" ;;
    710000) echo "台湾(taiwan)" ;;
    810000) echo "香港(hongkong)" ;;
    820000) echo "澳门(macau)" ;;
    *) echo "$1" ;;
  esac
}

format_provinces() {
  local code output=""
  for code in $SSH_CN_PROVINCES; do
    output="${output:+$output, }$(province_name "$code")"
  done
  echo "${output:-未配置}"
}

print_set_report() {
  local family="$1"
  local set_name="$2"
  local source_desc="$3"
  local chain_status="$4"
  local count

  count="$(set_count "$set_name")"
  echo
  echo "[$family] $set_name"
  echo "归属：$source_desc"
  echo "当前 SSH 白名单链：$chain_status"
  echo "ipset 条目数：$count"
  if [[ "$count" != "0" ]]; then
    echo "样例前缀（前 $SAMPLE_LIMIT 条）："
    set_sample "$set_name" | sed 's/^/  /'
  fi
}

need_cmd ipset
need_cmd iptables
if [[ "$ENABLE_IPV6" == "1" ]]; then
  need_cmd ip6tables
fi

case "${1:-}" in
  -n|--sample-limit)
    SAMPLE_LIMIT="${2:-10}"
    ;;
  --ip)
    CHECK_IP="${2:-}"
    ;;
  -h|--help|help)
    cat <<EOF
用法：$0 [--sample-limit N] [--ip 1.2.3.4]

读取当前 fwguard SSH 白名单链和 ipset 集合，输出各 IP 段归属、条目数和样例前缀。
只读检查，不修改任何防火墙规则。
EOF
    exit 0
    ;;
esac

echo "====== SSH 白名单生效检查 ======"
echo "配置文件：$CONFIG_PATH"
echo "SSH 端口：${SSH_PORT:-22}"
echo "IPv6：$ENABLE_IPV6"
echo "Cloudflare ASN：$CLOUDFLARE_ASNS"
echo "中国 SSH 白名单模式：${SSH_CN_WHITELIST_MODE:-none}"
if [[ "${SSH_CN_WHITELIST_MODE:-none}" == "province" ]]; then
  echo "中国 SSH 白名单省份：$(format_provinces)"
fi

print_listening_ssh_ports
print_firewall_context

echo
echo "== IPv4 SSH 链 =="
if chain_exists iptables "$CHAIN_V4"; then
  input_jumps_to_chain iptables "$CHAIN_V4" && echo "INPUT 已挂接：是" || echo "INPUT 已挂接：否"
  iptables -S "$CHAIN_V4"
else
  echo "未发现链：$CHAIN_V4"
fi

print_set_report "IPv4" "$IPSET_CF4" "Cloudflare 全部 ASN 当前宣告前缀" \
  "$(chain_accepts_set iptables "$CHAIN_V4" "$IPSET_CF4" && echo "已放行" || echo "未放行")"

case "${SSH_CN_WHITELIST_MODE:-none}" in
  all)
    cn_desc="中国全量 IP 段"
    ;;
  province)
    cn_desc="中国省份 IP 段：$(format_provinces)"
    ;;
  *)
    cn_desc="中国 SSH 白名单未启用"
    ;;
esac
print_set_report "IPv4" "$IPSET_SSH_CN4" "$cn_desc" \
  "$(chain_accepts_set iptables "$CHAIN_V4" "$IPSET_SSH_CN4" && echo "已放行" || echo "未放行")"

print_path_diagnosis "IPv4" iptables "$CHAIN_V4"

if [[ "$ENABLE_IPV6" == "1" ]]; then
  echo
  echo "== IPv6 SSH 链 =="
  if chain_exists ip6tables "$CHAIN_V6"; then
    input_jumps_to_chain ip6tables "$CHAIN_V6" && echo "INPUT 已挂接：是" || echo "INPUT 已挂接：否"
    ip6tables -S "$CHAIN_V6"
  else
    echo "未发现链：$CHAIN_V6"
  fi

  print_set_report "IPv6" "$IPSET_CF6" "Cloudflare 全部 ASN 当前宣告 IPv6 前缀" \
    "$(chain_accepts_set ip6tables "$CHAIN_V6" "$IPSET_CF6" && echo "已放行" || echo "未放行")"

  if [[ "${SSH_CN_WHITELIST_MODE:-none}" == "all" ]]; then
    cn6_desc="中国全量 IPv6 段"
  else
    cn6_desc="中国省份 IPv6 白名单未启用"
  fi
  print_set_report "IPv6" "$IPSET_SSH_CN6" "$cn6_desc" \
    "$(chain_accepts_set ip6tables "$CHAIN_V6" "$IPSET_SSH_CN6" && echo "已放行" || echo "未放行")"

  print_path_diagnosis "IPv6" ip6tables "$CHAIN_V6"
fi

if [[ -n "$CHECK_IP" ]]; then
  test_ip_membership "$CHECK_IP"
fi

echo
echo "检查完成。"
