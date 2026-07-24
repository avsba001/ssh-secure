#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 12 防火墙保护脚本：
# 1. 屏蔽来自中国 IP 段的 ICMP/ICMPv6。
# 2. SSH 仅允许 Cloudflare 全部 ASN 当前宣告的 IP 前缀访问。
# 3. 使用 ipset 提升匹配性能。
# 4. 持久化规则、定时更新 IP 段，并在异常时自动回滚。

SSH_PORT="${SSH_PORT:-}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-180}"
ALLOW_ESTABLISHED="${ALLOW_ESTABLISHED:-1}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
DRY_RUN="${DRY_RUN:-0}"

CN_URL="${CN_URL:-https://www.ipdeny.com/ipblocks/data/countries/cn.zone}"
CN_IPV6_URL="${CN_IPV6_URL:-https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone}"
# Cloudflare 当前已识别的 ASN。可通过同名环境变量显式覆盖。
CLOUDFLARE_ASNS="${CLOUDFLARE_ASNS:-AS13335 AS14789 AS132892 AS133877 AS202623 AS203898 AS209242 AS394536 AS395747 AS400095 AS402542}"
CLOUDFLARE_ASN_AUTO_UPDATE="${CLOUDFLARE_ASN_AUTO_UPDATE:-1}"
RIPESTAT_ASN_SEARCH_URL="${RIPESTAT_ASN_SEARCH_URL:-https://stat.ripe.net/data/searchcomplete/data.json}"
RIPESTAT_ANNOUNCED_PREFIXES_URL="${RIPESTAT_ANNOUNCED_PREFIXES_URL:-https://stat.ripe.net/data/announced-prefixes/data.json}"
CONNECTIVITY_TARGETS="${CONNECTIVITY_TARGETS:-1.1.1.1 8.8.8.8}"

WORKDIR="${WORKDIR:-/var/tmp/firewall-ipset-guard}"
STATE_DIR="${STATE_DIR:-/etc/fwguard-ipset}"
PERSIST_DIR="${PERSIST_DIR:-/etc/iptables}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/fwguard-firewall}"
IPSET_PERSIST_FILE="$PERSIST_DIR/ipsets"
LEGACY_IPSET_PERSIST_FILE="$PERSIST_DIR/ipsets.rules"
CONFIRM_FILE="$WORKDIR/confirm-keep-rules"
BACKUP_DIR="$WORKDIR/backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
LOG_FILE="$BACKUP_DIR/run.log"
CURRENT_STAGE="初始化"

IPSET_CN4="fwguard_cn_ipv4"
IPSET_CN6="fwguard_cn_ipv6"
IPSET_CF4="fwguard_cloudflare_ipv4"
IPSET_CF6="fwguard_cloudflare_ipv6"
CHAIN_V4="SSH_CF_ASN_GUARD"
CHAIN_ICMP_V4="CN_ICMP_DROP"
CHAIN_V6="SSH_CF_ASN_GUARD_V6"
CHAIN_ICMP_V6="CN_ICMP_DROP_V6"
LEGACY_CHAIN_V4="SSH_CF_CN_GUARD"
LEGACY_CHAIN_V6="SSH_CF_CN_GUARD_V6"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "错误：请使用 root 用户运行此脚本。" >&2
    exit 1
  fi
}

validate_script_source() {
  local source_path="${BASH_SOURCE[0]:-}"

  case "$source_path" in
    /dev/fd/*|/proc/*/fd/*|/dev/stdin|"")
      echo "错误：当前脚本通过临时文件描述符运行，无法可靠安装和持久化自身。" >&2
      echo "请先将脚本保存为普通 .sh 文件，再执行：sudo bash 脚本文件 apply" >&2
      exit 1
      ;;
  esac
  if [[ ! -f "$source_path" || ! -s "$source_path" ]]; then
    echo "错误：脚本源文件不存在或为空：$source_path" >&2
    exit 1
  fi
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[演练模式] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

set_stage() {
  CURRENT_STAGE="$1"
  echo "当前阶段：$CURRENT_STAGE"
}

print_diagnose_hint() {
  echo "可运行以下命令查看完整诊断：" >&2
  if [[ -x "$INSTALL_PATH" ]]; then
    printf '  sudo %q diagnose\n' "$INSTALL_PATH" >&2
  elif [[ "${BASH_SOURCE[0]}" != /dev/fd/* && -f "${BASH_SOURCE[0]}" ]]; then
    printf '  sudo bash %q diagnose\n' "${BASH_SOURCE[0]}" >&2
  else
    echo "  当前脚本通过临时 /dev/fd 路径运行，退出后该路径会失效。" >&2
    echo "  请将脚本保存为本地文件后，再使用 diagnose 参数运行。" >&2
  fi
}

handle_apply_error() {
  local exit_code="${1:-1}"
  local line_number="${2:-未知}"
  local failed_command="${3:-未知}"
  local function_name="${4:-main}"

  trap - ERR
  set +e
  {
    echo "错误：应用规则失败。"
    echo "失败阶段：$CURRENT_STAGE"
    echo "失败位置：函数 $function_name，第 $line_number 行"
    echo "失败命令：$failed_command"
    echo "退出码：$exit_code"
    echo "诊断日志：$LOG_FILE"
    if command -v ipset >/dev/null 2>&1; then
      echo "失败时的 fwguard ipset 集合："
      ipset list -name 2>/dev/null | grep '^fwguard_' || echo "  未发现 fwguard ipset 集合"
    fi
    echo "正在回滚……"
  } 2>&1 | tee -a "$LOG_FILE" >&2

  if [[ "$DRY_RUN" != "1" ]]; then
    bash "$ROLLBACK_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
  fi
  print_diagnose_hint
  exit "$exit_code"
}

handle_refresh_error() {
  local exit_code="${1:-1}"
  local line_number="${2:-未知}"
  local failed_command="${3:-未知}"
  local function_name="${4:-main}"
  local refresh_log="$STATE_DIR/last-refresh-error.log"

  trap - ERR
  set +e
  mkdir -p "$STATE_DIR"
  {
    echo "时间：$(date '+%F %T %z')"
    echo "错误：定时更新失败。"
    echo "失败阶段：$CURRENT_STAGE"
    echo "失败位置：函数 $function_name，第 $line_number 行"
    echo "失败命令：$failed_command"
    echo "退出码：$exit_code"
  } 2>&1 | tee "$refresh_log" >&2
  exit "$exit_code"
}

apt_install_missing() {
  local missing=()
  local packages=(iptables ipset ipset-persistent iptables-persistent netfilter-persistent curl jq iputils-ping systemd)
  local pkg

  for cmd in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore ipset ping curl jq systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "错误：缺少命令：${missing[*]}" >&2
    echo "错误：未找到 apt-get；此脚本默认支持 Debian 12。" >&2
    exit 1
  fi

  for pkg in ipset-persistent iptables-persistent netfilter-persistent; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  echo "检测到缺失的依赖或软件包：${missing[*]}"
  echo "正在安装 Debian 12 软件包：${packages[*]}"

  if [[ "$DRY_RUN" == "1" ]]; then
    run env DEBIAN_FRONTEND=noninteractive apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  if command -v debconf-set-selections >/dev/null 2>&1; then
    printf 'iptables-persistent iptables-persistent/autosave_v4 boolean false\n' | debconf-set-selections
    printf 'iptables-persistent iptables-persistent/autosave_v6 boolean false\n' | debconf-set-selections
  fi
  apt-get update
  apt-get install -y "${packages[@]}"
}

validate_deps() {
  local cmd
  for cmd in iptables iptables-save iptables-restore ipset ping curl jq systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "错误：安装后仍缺少依赖命令：$cmd" >&2
      exit 1
    }
  done

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    for cmd in ip6tables ip6tables-save ip6tables-restore; do
      command -v "$cmd" >/dev/null 2>&1 || {
        echo "错误：安装后仍缺少依赖命令：$cmd" >&2
        exit 1
      }
    done
  fi
}

prompt_ssh_port() {
  local input

  if [[ -n "$SSH_PORT" ]]; then
    validate_ssh_port "$SSH_PORT"
    return 0
  fi

  read -r -p "请输入 SSH 端口 [默认 22]：" input
  SSH_PORT="${input:-22}"
  validate_ssh_port "$SSH_PORT"
}

validate_ssh_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "错误：SSH 端口无效：$port" >&2
    exit 1
  fi
}

normalize_cloudflare_asns() {
  local raw="$CLOUDFLARE_ASNS"
  local token normalized=""

  raw="${raw//,/ }"
  for token in $raw; do
    token="${token^^}"
    [[ "$token" == AS* ]] || token="AS$token"
    if ! [[ "$token" =~ ^AS[0-9]+$ ]]; then
      echo "错误：Cloudflare ASN 格式无效：$token" >&2
      exit 1
    fi
    if [[ " $normalized " != *" $token "* ]]; then
      normalized="${normalized:+$normalized }$token"
    fi
  done

  if [[ -z "$normalized" ]]; then
    echo "错误：Cloudflare ASN 列表不能为空。" >&2
    exit 1
  fi
  if [[ "$CLOUDFLARE_ASN_AUTO_UPDATE" != "0" && "$CLOUDFLARE_ASN_AUTO_UPDATE" != "1" ]]; then
    echo "错误：CLOUDFLARE_ASN_AUTO_UPDATE 只能设置为 0 或 1。" >&2
    exit 1
  fi
  CLOUDFLARE_ASNS="$normalized"
}

fetch() {
  local url="$1"
  local out="$2"
  curl -fsSL --connect-timeout 10 --retry 3 "$url" -o "$out"
}

backup_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    cp -a "$path" "$BACKUP_DIR/$(basename "$path").bak"
  fi
}

backup_rules() {
  mkdir -p "$BACKUP_DIR" "$PERSIST_DIR" "$STATE_DIR"
  touch "$LOG_FILE"

  iptables-save > "$BACKUP_DIR/iptables.runtime.rules"
  ipset save > "$BACKUP_DIR/ipset.runtime.rules" || true
  [[ "$ENABLE_IPV6" == "1" ]] && ip6tables-save > "$BACKUP_DIR/ip6tables.runtime.rules" || true

  backup_file "$PERSIST_DIR/rules.v4"
  backup_file "$PERSIST_DIR/rules.v6"
  backup_file "$IPSET_PERSIST_FILE"
  backup_file "$LEGACY_IPSET_PERSIST_FILE"
  backup_file "$STATE_DIR/config"

  cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

restore_file() {
  local backup="\$1"
  local target="\$2"
  if [[ -f "\$backup" ]]; then
    cp -a "\$backup" "\$target"
  else
    rm -f "\$target"
  fi
}

if [[ -f "$BACKUP_DIR/ip6tables.runtime.rules" ]] && command -v ip6tables-restore >/dev/null 2>&1; then
  ip6tables-restore < "$BACKUP_DIR/ip6tables.runtime.rules" || true
fi
iptables-restore < "$BACKUP_DIR/iptables.runtime.rules"
while IFS= read -r set_name; do
  [[ "\$set_name" == fwguard_* ]] || continue
  if grep -Fq "create \$set_name " "$BACKUP_DIR/ipset.runtime.rules" 2>/dev/null; then
    ipset flush "\$set_name" 2>/dev/null || true
  else
    ipset destroy "\$set_name" 2>/dev/null || true
  fi
done < <(ipset list -name 2>/dev/null || true)
if [[ -s "$BACKUP_DIR/ipset.runtime.rules" ]]; then
  ipset restore -exist < "$BACKUP_DIR/ipset.runtime.rules" || true
fi

restore_file "$BACKUP_DIR/rules.v4.bak" "$PERSIST_DIR/rules.v4"
restore_file "$BACKUP_DIR/rules.v6.bak" "$PERSIST_DIR/rules.v6"
restore_file "$BACKUP_DIR/ipsets.bak" "$IPSET_PERSIST_FILE"
restore_file "$BACKUP_DIR/ipsets.rules.bak" "$LEGACY_IPSET_PERSIST_FILE"
restore_file "$BACKUP_DIR/config.bak" "$STATE_DIR/config"
systemctl disable --now fwguard-ipset-refresh.timer >/dev/null 2>&1 || true
systemctl disable --now fwguard-ipset-restore.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf
systemctl daemon-reload >/dev/null 2>&1 || true
echo "已使用 $BACKUP_DIR 中的备份完成回滚。"
EOF
  chmod 700 "$ROLLBACK_SCRIPT"
}

start_rollback_guard() {
  rm -f "$CONFIRM_FILE"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[演练模式] 回滚保护将在 ${ROLLBACK_SECONDS} 秒后触发。"
    return
  fi

  nohup bash -c "
    sleep '$ROLLBACK_SECONDS'
    if [[ ! -f '$CONFIRM_FILE' ]]; then
      echo \"未找到确认文件，正在自动回滚。\" >> '$LOG_FILE'
      bash '$ROLLBACK_SCRIPT' >> '$LOG_FILE' 2>&1
    fi
  " >/dev/null 2>&1 &
  echo "$!" > "$BACKUP_DIR/rollback-guard.pid"
}

migrate_legacy_state() {
  mkdir -p "$PERSIST_DIR"
  if [[ ! -s "$IPSET_PERSIST_FILE" && -s "$LEGACY_IPSET_PERSIST_FILE" ]]; then
    echo "检测到旧版 ipset 持久化文件，正在迁移：$LEGACY_IPSET_PERSIST_FILE"
    run cp -a "$LEGACY_IPSET_PERSIST_FILE" "$IPSET_PERSIST_FILE"
  fi
}

download_cn_lists() {
  echo "正在下载中国 IPv4 地址段（仅用于 ICMP 屏蔽）……"
  fetch "$CN_URL" "$STATE_DIR/cn.zone"
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$STATE_DIR/cn.zone" > "$STATE_DIR/cn-v4.clean" || true
  if [[ ! -s "$STATE_DIR/cn-v4.clean" ]]; then
    echo "错误：下载的中国 IPv4 地址段为空或格式无效。" >&2
    exit 1
  fi

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    echo "正在下载中国 IPv6 地址段（仅用于 ICMP 屏蔽）……"
    fetch "$CN_IPV6_URL" "$STATE_DIR/cn-v6.zone"
    grep -E '^[0-9a-fA-F:]+/[0-9]+$' "$STATE_DIR/cn-v6.zone" > "$STATE_DIR/cn-v6.clean" || true
    if [[ ! -s "$STATE_DIR/cn-v6.clean" ]]; then
      echo "错误：下载的中国 IPv6 地址段为空或格式无效。" >&2
      exit 1
    fi
  fi
}

download_cloudflare_asn_lists() {
  local asn json_file tmp4 tmp6=""
  tmp4="$(mktemp "$STATE_DIR/cf-v4.clean.XXXXXX")"
  [[ "$ENABLE_IPV6" == "1" ]] && tmp6="$(mktemp "$STATE_DIR/cf-v6.clean.XXXXXX")"

  for asn in $CLOUDFLARE_ASNS; do
    echo "正在获取 Cloudflare $asn 当前宣告的 IP 前缀……"
    json_file="$STATE_DIR/cloudflare-${asn}.json"
    fetch "${RIPESTAT_ANNOUNCED_PREFIXES_URL}?resource=${asn}" "$json_file"
    if ! jq -e '.status == "ok" and (.data.prefixes | type == "array")' "$json_file" >/dev/null 2>&1; then
      rm -f "$tmp4"
      [[ -n "$tmp6" ]] && rm -f "$tmp6"
      echo "错误：RIPEstat 返回的 $asn 前缀数据无效。" >&2
      exit 1
    fi
    jq -r '.data.prefixes[]?.prefix // empty' "$json_file" \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' >> "$tmp4" || true
    if [[ "$ENABLE_IPV6" == "1" ]]; then
      jq -r '.data.prefixes[]?.prefix // empty' "$json_file" \
        | grep -E '^[0-9a-fA-F:]+/[0-9]+$' >> "$tmp6" || true
    fi
  done

  sort -u -o "$tmp4" "$tmp4"
  if [[ ! -s "$tmp4" ]]; then
    rm -f "$tmp4"
    [[ -n "$tmp6" ]] && rm -f "$tmp6"
    echo "错误：Cloudflare 全部 ASN 的 IPv4 前缀汇总为空。" >&2
    exit 1
  fi
  install -m 0600 "$tmp4" "$STATE_DIR/cf-v4.clean"
  rm -f "$tmp4"

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    sort -u -o "$tmp6" "$tmp6"
    if [[ ! -s "$tmp6" ]]; then
      rm -f "$tmp6"
      echo "错误：Cloudflare 全部 ASN 的 IPv6 前缀汇总为空。" >&2
      exit 1
    fi
    install -m 0600 "$tmp6" "$STATE_DIR/cf-v6.clean"
    rm -f "$tmp6"
  fi
}

discover_cloudflare_asns() {
  local json_file discovered count

  if [[ "$CLOUDFLARE_ASN_AUTO_UPDATE" != "1" ]]; then
    echo "Cloudflare ASN 自动发现已关闭，使用配置中的 ASN 清单。"
    return 0
  fi

  echo "正在从 RIPEstat 获取最新 Cloudflare ASN 清单……"
  json_file="$STATE_DIR/cloudflare-asns.json"
  fetch "${RIPESTAT_ASN_SEARCH_URL}?resource=Cloudflare" "$json_file"
  if ! jq -e '.status == "ok" and (.data.categories | type == "array")' "$json_file" >/dev/null 2>&1; then
    echo "错误：RIPEstat 返回的 Cloudflare ASN 清单无效，现有防火墙规则未更改。" >&2
    exit 1
  fi

  discovered="$(jq -r '
    .data.categories[]?
    | select(.category == "ASNs")
    | .suggestions[]?
    | select((.description // "") | test("cloudflare"; "i"))
    | .value
  ' "$json_file" | grep -E '^AS[0-9]+$' | sort -u || true)"
  count="$(printf '%s\n' "$discovered" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" -lt 2 ]] || ! grep -qx 'AS13335' <<< "$discovered"; then
    echo "错误：自动发现的 Cloudflare ASN 清单不完整，现有防火墙规则未更改。" >&2
    exit 1
  fi

  CLOUDFLARE_ASNS="$(tr '\n' ' ' <<< "$discovered" | xargs)"
  normalize_cloudflare_asns
  echo "已发现 $count 个 Cloudflare ASN：$CLOUDFLARE_ASNS"
}

download_lists() {
  mkdir -p "$STATE_DIR"
  discover_cloudflare_asns
  download_cn_lists
  download_cloudflare_asn_lists
}

load_one_set() {
  local set_name="$1"
  local family="$2"
  local list_file="$3"
  local tmp_set="${set_name}_tmp"
  local create_line=""

  CURRENT_STAGE="准备 ipset 集合 $set_name"
  echo "正在载入 ipset 集合：$set_name"
  if ipset list "$tmp_set" >/dev/null 2>&1; then
    run ipset destroy "$tmp_set"
  fi
  if ipset list "$set_name" >/dev/null 2>&1; then
    create_line="$(ipset save "$set_name" 2>/dev/null | sed -n '1p')"
    if [[ "$create_line" != "create $set_name hash:net "* ]]; then
      echo "错误：现有集合 $set_name 不是兼容的 hash:net 类型。" >&2
      ipset list "$set_name" 2>/dev/null | sed -n '1,/^Number of entries:/p' >&2 || true
      return 1
    fi
    create_line="${create_line/create $set_name /create $tmp_set }"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[演练模式] $create_line"
    elif ! printf '%s\n' "$create_line" | ipset restore; then
      echo "错误：无法按现有集合参数创建临时集合 $tmp_set。" >&2
      return 1
    fi
  else
    run ipset create "$tmp_set" hash:net family "$family" hashsize 65536 maxelem 1048576
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[演练模式] 将从 $list_file 批量载入集合 $tmp_set。"
  else
    if ! while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && printf 'add %s %s -exist\n' "$tmp_set" "$cidr"
    done < "$list_file" | ipset restore; then
      echo "错误：向临时集合 $tmp_set 批量载入 $list_file 失败。" >&2
      ipset list "$tmp_set" 2>/dev/null | sed -n '1,/^Number of entries:/p' >&2 || true
      return 1
    fi
  fi

  if ! ipset list "$set_name" >/dev/null 2>&1; then
    run ipset create "$set_name" hash:net family "$family" hashsize 65536 maxelem 1048576
  fi
  CURRENT_STAGE="原子替换 ipset 集合 $set_name"
  if ! run ipset swap "$tmp_set" "$set_name"; then
    echo "错误：ipset 集合 $tmp_set 与 $set_name 无法交换，详细参数如下：" >&2
    ipset list "$tmp_set" 2>/dev/null | sed -n '1,/^Number of entries:/p' >&2 || true
    ipset list "$set_name" 2>/dev/null | sed -n '1,/^Number of entries:/p' >&2 || true
    return 1
  fi
  run ipset destroy "$tmp_set"
}

load_ipsets() {
  load_one_set "$IPSET_CN4" inet "$STATE_DIR/cn-v4.clean"
  load_one_set "$IPSET_CF4" inet "$STATE_DIR/cf-v4.clean"

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    load_one_set "$IPSET_CN6" inet6 "$STATE_DIR/cn-v6.clean"
    load_one_set "$IPSET_CF6" inet6 "$STATE_DIR/cf-v6.clean"
  fi
}

ensure_established_rule() {
  local cmd="$1"
  if ! "$cmd" -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1; then
    run "$cmd" -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

ensure_jump() {
  local table_cmd="$1"
  local chain="$2"
  local proto="$3"
  local position="${4:-2}"
  shift 4

  if ! "$table_cmd" -C INPUT -p "$proto" "$@" -j "$chain" >/dev/null 2>&1; then
    run "$table_cmd" -I INPUT "$position" -p "$proto" "$@" -j "$chain"
  fi
}

remove_input_jumps_to_chain() {
  local table_cmd="$1"
  local chain="$2"
  local spec

  while true; do
    spec="$("$table_cmd" -S INPUT 2>/dev/null \
      | grep -- "-j $chain" \
      | head -n 1 \
      | sed 's/^-A INPUT /-D INPUT /' || true)"
    [[ -n "$spec" ]] || break
    # shellcheck disable=SC2086
    run "$table_cmd" $spec
    [[ "$DRY_RUN" == "1" ]] && break
  done
}

apply_ipv4_rules() {
  remove_input_jumps_to_chain iptables "$CHAIN_V4"
  remove_input_jumps_to_chain iptables "$LEGACY_CHAIN_V4"
  remove_input_jumps_to_chain iptables "$CHAIN_ICMP_V4"
  run iptables -F "$LEGACY_CHAIN_V4" 2>/dev/null || true
  run iptables -X "$LEGACY_CHAIN_V4" 2>/dev/null || true

  run iptables -N "$CHAIN_V4" 2>/dev/null || true
  run iptables -F "$CHAIN_V4"
  run iptables -A "$CHAIN_V4" -m set --match-set "$IPSET_CF4" src -j ACCEPT
  run iptables -A "$CHAIN_V4" -j DROP

  run iptables -N "$CHAIN_ICMP_V4" 2>/dev/null || true
  run iptables -F "$CHAIN_ICMP_V4"
  run iptables -A "$CHAIN_ICMP_V4" -m set --match-set "$IPSET_CN4" src -j DROP
  run iptables -A "$CHAIN_ICMP_V4" -j RETURN

  [[ "$ALLOW_ESTABLISHED" == "1" ]] && ensure_established_rule iptables
  ensure_jump iptables "$CHAIN_V4" tcp 2 --dport "$SSH_PORT"
  ensure_jump iptables "$CHAIN_ICMP_V4" icmp 2
}

apply_ipv6_rules() {
  if [[ "$ENABLE_IPV6" != "1" ]]; then
    command -v ip6tables >/dev/null 2>&1 || return 0
    remove_input_jumps_to_chain ip6tables "$CHAIN_V6"
    remove_input_jumps_to_chain ip6tables "$LEGACY_CHAIN_V6"
    remove_input_jumps_to_chain ip6tables "$CHAIN_ICMP_V6"
    run ip6tables -F "$CHAIN_V6" 2>/dev/null || true
    run ip6tables -X "$CHAIN_V6" 2>/dev/null || true
    run ip6tables -F "$CHAIN_ICMP_V6" 2>/dev/null || true
    run ip6tables -X "$CHAIN_ICMP_V6" 2>/dev/null || true
    run ip6tables -F "$LEGACY_CHAIN_V6" 2>/dev/null || true
    run ip6tables -X "$LEGACY_CHAIN_V6" 2>/dev/null || true
    return 0
  fi

  remove_input_jumps_to_chain ip6tables "$CHAIN_V6"
  remove_input_jumps_to_chain ip6tables "$LEGACY_CHAIN_V6"
  remove_input_jumps_to_chain ip6tables "$CHAIN_ICMP_V6"
  run ip6tables -F "$LEGACY_CHAIN_V6" 2>/dev/null || true
  run ip6tables -X "$LEGACY_CHAIN_V6" 2>/dev/null || true

  run ip6tables -N "$CHAIN_V6" 2>/dev/null || true
  run ip6tables -F "$CHAIN_V6"
  run ip6tables -A "$CHAIN_V6" -m set --match-set "$IPSET_CF6" src -j ACCEPT
  run ip6tables -A "$CHAIN_V6" -j DROP

  run ip6tables -N "$CHAIN_ICMP_V6" 2>/dev/null || true
  run ip6tables -F "$CHAIN_ICMP_V6"
  run ip6tables -A "$CHAIN_ICMP_V6" -m set --match-set "$IPSET_CN6" src -j DROP
  run ip6tables -A "$CHAIN_ICMP_V6" -j RETURN

  [[ "$ALLOW_ESTABLISHED" == "1" ]] && ensure_established_rule ip6tables
  ensure_jump ip6tables "$CHAIN_V6" tcp 2 --dport "$SSH_PORT"
  ensure_jump ip6tables "$CHAIN_ICMP_V6" ipv6-icmp 2
}

remove_legacy_country_whitelists() {
  local region set_name

  echo "正在清理旧版国家/地区 SSH 白名单……"
  for region in us jp hk tw; do
    set_name="fwguard_${region}_ipv4"
    run ipset destroy "$set_name" 2>/dev/null || true
    set_name="fwguard_${region}_ipv6"
    run ipset destroy "$set_name" 2>/dev/null || true
    run rm -f "$STATE_DIR/${region}.zone" "$STATE_DIR/${region}-v4.clean"
    run rm -f "$STATE_DIR/${region}-v6.zone" "$STATE_DIR/${region}-v6.clean"
  done
  run rm -f "$STATE_DIR/cloudflare-ips-v4" "$STATE_DIR/cloudflare-ips-v6"

  if [[ "$ENABLE_IPV6" != "1" ]]; then
    run ipset destroy "$IPSET_CN6" 2>/dev/null || true
    run ipset destroy "$IPSET_CF6" 2>/dev/null || true
  fi
}

connectivity_check() {
  local ok=0
  local target

  for target in $CONNECTIVITY_TARGETS; do
    if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
      ok=1
      break
    fi
  done

  if [[ "$ok" != "1" ]]; then
    echo "错误：联网检查失败，正在回滚。" >&2
    [[ "$DRY_RUN" == "1" ]] || bash "$ROLLBACK_SCRIPT"
    exit 1
  fi
}

write_config() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_DIR/config" <<EOF
SSH_PORT="$SSH_PORT"
ROLLBACK_SECONDS="$ROLLBACK_SECONDS"
ALLOW_ESTABLISHED="$ALLOW_ESTABLISHED"
ENABLE_IPV6="$ENABLE_IPV6"
CN_URL="$CN_URL"
CN_IPV6_URL="$CN_IPV6_URL"
CLOUDFLARE_ASNS="$CLOUDFLARE_ASNS"
CLOUDFLARE_ASN_AUTO_UPDATE="$CLOUDFLARE_ASN_AUTO_UPDATE"
RIPESTAT_ASN_SEARCH_URL="$RIPESTAT_ASN_SEARCH_URL"
RIPESTAT_ANNOUNCED_PREFIXES_URL="$RIPESTAT_ANNOUNCED_PREFIXES_URL"
CONNECTIVITY_TARGETS="$CONNECTIVITY_TARGETS"
WORKDIR="$WORKDIR"
STATE_DIR="$STATE_DIR"
PERSIST_DIR="$PERSIST_DIR"
EOF
  chmod 600 "$STATE_DIR/config"
}

persist_rules() {
  local set_name
  local tmp_file
  local set_names=("$IPSET_CN4" "$IPSET_CF4")

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    set_names+=("$IPSET_CN6" "$IPSET_CF6")
  fi

  mkdir -p "$PERSIST_DIR"
  tmp_file="$(mktemp)"
  for set_name in "${set_names[@]}"; do
    ipset save "$set_name" >> "$tmp_file"
  done
  install -m 0600 "$tmp_file" "$IPSET_PERSIST_FILE"
  if [[ -e "$LEGACY_IPSET_PERSIST_FILE" ]]; then
    install -m 0600 "$tmp_file" "$LEGACY_IPSET_PERSIST_FILE"
  fi
  rm -f "$tmp_file"
  iptables-save > "$PERSIST_DIR/rules.v4"
  command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$PERSIST_DIR/rules.v6"
}

install_self() {
  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$INSTALL_PATH" ]]; then
    run install -m 0755 "${BASH_SOURCE[0]}" "$INSTALL_PATH"
  fi
}

install_systemd_units() {
  run mkdir -p /etc/systemd/system/netfilter-persistent.service.d

  run tee /etc/systemd/system/fwguard-ipset-restore.service >/dev/null <<EOF
[Unit]
Description=在持久化 iptables 规则前恢复 fwguard ipset
DefaultDependencies=no
Before=netfilter-persistent.service
After=local-fs.target
ConditionPathExists=!/usr/share/netfilter-persistent/plugins.d/10-ipset

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test ! -s $IPSET_PERSIST_FILE || /usr/sbin/ipset restore -exist < $IPSET_PERSIST_FILE'

[Install]
WantedBy=netfilter-persistent.service
EOF

  run tee /etc/systemd/system/netfilter-persistent.service.d/fwguard-ipset.conf >/dev/null <<EOF
[Unit]
Wants=fwguard-ipset-restore.service
After=fwguard-ipset-restore.service
EOF

  run tee /etc/systemd/system/fwguard-ipset-refresh.service >/dev/null <<EOF
[Unit]
Description=更新 fwguard 的 Cloudflare ASN 和中国 ICMP 地址段
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH refresh
EOF

  run tee /etc/systemd/system/fwguard-ipset-refresh.timer >/dev/null <<EOF
[Unit]
Description=每日更新 fwguard IP 地址段

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run systemctl daemon-reload
  run systemctl enable fwguard-ipset-restore.service
  run systemctl restart fwguard-ipset-restore.service
  run systemctl enable --now fwguard-ipset-refresh.timer
  run systemctl enable netfilter-persistent.service >/dev/null 2>&1 || true
}

load_config_if_present() {
  if [[ -f "$STATE_DIR/config" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/config"
  fi
  CLOUDFLARE_ASNS="${CLOUDFLARE_ASNS:-AS13335 AS14789 AS132892 AS133877 AS202623 AS203898 AS209242 AS394536 AS395747 AS400095 AS402542}"
  CLOUDFLARE_ASN_AUTO_UPDATE="${CLOUDFLARE_ASN_AUTO_UPDATE:-1}"
  RIPESTAT_ASN_SEARCH_URL="${RIPESTAT_ASN_SEARCH_URL:-https://stat.ripe.net/data/searchcomplete/data.json}"
  RIPESTAT_ANNOUNCED_PREFIXES_URL="${RIPESTAT_ANNOUNCED_PREFIXES_URL:-https://stat.ripe.net/data/announced-prefixes/data.json}"
  normalize_cloudflare_asns
  IPSET_PERSIST_FILE="$PERSIST_DIR/ipsets"
  LEGACY_IPSET_PERSIST_FILE="$PERSIST_DIR/ipsets.rules"
  CONFIRM_FILE="$WORKDIR/confirm-keep-rules"
}

refresh_ipsets() {
  need_root
  trap 'handle_refresh_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR
  set_stage "检查并安装依赖"
  apt_install_missing
  validate_deps
  set_stage "读取已保存配置"
  load_config_if_present
  validate_ssh_port "${SSH_PORT:-22}"
  SSH_PORT="${SSH_PORT:-22}"
  set_stage "迁移旧版持久化文件"
  migrate_legacy_state
  set_stage "下载 ASN 和 IP 前缀数据"
  download_lists
  set_stage "载入 ipset 集合"
  load_ipsets
  set_stage "应用 IPv4 防火墙规则"
  apply_ipv4_rules
  set_stage "应用 IPv6 防火墙规则"
  apply_ipv6_rules
  set_stage "清理旧版国家白名单"
  remove_legacy_country_whitelists
  set_stage "写入配置和持久化规则"
  write_config
  persist_rules
  trap - ERR
  rm -f "$STATE_DIR/last-refresh-error.log"
  echo "Cloudflare ASN 前缀和中国 ICMP 地址段已更新，防火墙规则已重新持久化。"
}

confirm_rules() {
  need_root
  load_config_if_present
  mkdir -p "$WORKDIR"
  touch "$CONFIRM_FILE"
  echo "已确认保留规则，回滚保护不会恢复旧配置。"
}

rollback_latest() {
  need_root
  local latest
  load_config_if_present
  latest="$(ls -dt "$WORKDIR"/backup-* 2>/dev/null | head -n 1 || true)"
  [[ -n "${latest:-}" && -x "$latest/rollback.sh" ]] || {
    echo "错误：在 $WORKDIR 下未找到可用的回滚备份。" >&2
    exit 1
  }
  bash "$latest/rollback.sh"
}

diagnose_rules() {
  local set_name latest_backup latest_log data_file
  need_root
  load_config_if_present

  echo "== 系统信息 =="
  uname -a || true
  [[ -f /etc/os-release ]] && sed -n '1,8p' /etc/os-release || true
  echo

  echo "== 软件包状态 =="
  dpkg-query -W ipset ipset-persistent iptables-persistent netfilter-persistent jq 2>/dev/null || true
  echo

  echo "== 已安装文件 =="
  ls -l "$INSTALL_PATH" "$STATE_DIR/config" "$IPSET_PERSIST_FILE" "$LEGACY_IPSET_PERSIST_FILE" "$PERSIST_DIR/rules.v4" "$PERSIST_DIR/rules.v6" 2>/dev/null || true
  echo
  if [[ -s "$LEGACY_IPSET_PERSIST_FILE" ]]; then
    echo "提示：检测到旧版持久化文件 $LEGACY_IPSET_PERSIST_FILE。"
  fi
  echo "SSH 端口：${SSH_PORT:-22}"
  echo "SSH 白名单来源：Cloudflare 全部 ASN 当前宣告前缀"
  echo "Cloudflare ASN：$CLOUDFLARE_ASNS"
  echo "Cloudflare ASN 自动发现：$CLOUDFLARE_ASN_AUTO_UPDATE"
  echo
  echo "== Netfilter 持久化插件 =="
  ls -l /usr/share/netfilter-persistent/plugins.d 2>/dev/null || true
  echo

  echo "== systemd 启用和运行状态 =="
  for unit in fwguard-ipset-restore.service netfilter-persistent.service fwguard-ipset-refresh.timer fwguard-ipset-refresh.service; do
    printf '%s：启用状态=%s，运行状态=%s\n' \
      "$unit" \
      "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
      "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done
  echo

  echo "== systemd 启动顺序 =="
  systemctl cat fwguard-ipset-restore.service 2>/dev/null || true
  systemctl cat netfilter-persistent.service 2>/dev/null || true
  echo

  echo "== 当前 ipset 状态 =="
  echo "说明：fwguard_cn_* 仅用于中国 ICMP 屏蔽，不属于 SSH 白名单。"
  for set_name in "$IPSET_CN4" "$IPSET_CN6" "$IPSET_CF4" "$IPSET_CF6"; do
    if ipset list "$set_name" >/dev/null 2>&1; then
      printf '%s 条目数：' "$set_name"
      ipset list "$set_name" | awk -F': ' '/Number of entries/ {print $2}'
    else
      echo "$set_name：缺失"
    fi
  done
  echo

  echo "== ipset 详细参数 =="
  while IFS= read -r set_name; do
    [[ -n "$set_name" ]] || continue
    echo "-- $set_name --"
    ipset list "$set_name" 2>/dev/null | sed -n '1,/^Number of entries:/p' || true
  done < <(ipset list -name 2>/dev/null | grep '^fwguard_' || true)
  echo

  echo "== 下载数据状态 =="
  for data_file in "$STATE_DIR/cn-v4.clean" "$STATE_DIR/cn-v6.clean" "$STATE_DIR/cf-v4.clean" "$STATE_DIR/cf-v6.clean"; do
    if [[ -s "$data_file" ]]; then
      printf '%s：%s 行\n' "$data_file" "$(wc -l < "$data_file" | tr -d ' ')"
    else
      echo "${data_file}：缺失或为空"
    fi
  done
  if [[ -s "$STATE_DIR/cloudflare-asns.json" ]]; then
    printf 'ASN 搜索接口状态：'
    jq -r '.status // "未知"' "$STATE_DIR/cloudflare-asns.json" 2>/dev/null || echo "JSON 解析失败"
  fi
  echo

  echo "== 当前 iptables 挂接规则 =="
  iptables -S INPUT 2>/dev/null | grep -E "$CHAIN_V4|$CHAIN_ICMP_V4|ESTABLISHED" || true
  ip6tables -S INPUT 2>/dev/null | grep -E "$CHAIN_V6|$CHAIN_ICMP_V6|ESTABLISHED" || true
  echo
  echo "== 当前 SSH 白名单链 =="
  iptables -S "$CHAIN_V4" 2>/dev/null || echo "IPv4 SSH 白名单链缺失"
  if [[ "$ENABLE_IPV6" == "1" ]]; then
    ip6tables -S "$CHAIN_V6" 2>/dev/null || echo "IPv6 SSH 白名单链缺失"
  fi
  echo

  echo "== 持久化规则测试 =="
  if [[ -s "$PERSIST_DIR/rules.v4" ]]; then
    iptables-restore --test < "$PERSIST_DIR/rules.v4" && echo "IPv4 rules.v4 测试：通过" || echo "IPv4 rules.v4 测试：失败"
  else
    echo "IPv4 rules.v4：缺失或为空"
  fi
  if [[ -s "$PERSIST_DIR/rules.v6" ]]; then
    ip6tables-restore --test < "$PERSIST_DIR/rules.v6" && echo "IPv6 rules.v6 测试：通过" || echo "IPv6 rules.v6 测试：失败"
  else
    echo "IPv6 rules.v6：缺失或为空"
  fi
  echo

  echo "== 本次启动日志 =="
  journalctl -b --no-pager -u fwguard-ipset-restore.service -u netfilter-persistent.service -u fwguard-ipset-refresh.timer -u fwguard-ipset-refresh.service || true
  echo

  echo "== 最近一次应用日志 =="
  latest_backup="$(ls -dt "$WORKDIR"/backup-* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest_backup" ]]; then
    echo "最近备份目录：$latest_backup"
    latest_log="$latest_backup/run.log"
    if [[ -s "$latest_log" ]]; then
      tail -n 100 "$latest_log"
    else
      echo "最近一次运行日志为空；该备份可能由旧版脚本创建。"
    fi
  else
    echo "未找到应用备份目录。"
  fi
  echo
  echo "== 最近一次定时更新错误 =="
  if [[ -s "$STATE_DIR/last-refresh-error.log" ]]; then
    cat "$STATE_DIR/last-refresh-error.log"
  else
    echo "未记录定时更新错误。"
  fi
}

print_summary() {
  local cn4 cn6 cf4 cf6
  cn4="$(wc -l < "$STATE_DIR/cn-v4.clean" | tr -d ' ')"
  cf4="$(wc -l < "$STATE_DIR/cf-v4.clean" | tr -d ' ')"
  cn6="0"
  cf6="0"
  [[ -s "$STATE_DIR/cn-v6.clean" ]] && cn6="$(wc -l < "$STATE_DIR/cn-v6.clean" | tr -d ' ')"
  [[ -s "$STATE_DIR/cf-v6.clean" ]] && cf6="$(wc -l < "$STATE_DIR/cf-v6.clean" | tr -d ' ')"

  cat <<EOF
防火墙规则已应用并完成持久化。

备份目录：$BACKUP_DIR
持久化文件：
  $IPSET_PERSIST_FILE
  $PERSIST_DIR/rules.v4
  $PERSIST_DIR/rules.v6
systemd 定时器：
  fwguard-ipset-refresh.timer

中国 IPv4 地址段：$cn4
中国 IPv6 地址段：$cn6
Cloudflare ASN IPv4 前缀：$cf4
Cloudflare ASN IPv6 前缀：$cf6
Cloudflare ASN：$CLOUDFLARE_ASNS
Cloudflare ASN 自动发现：$CLOUDFLARE_ASN_AUTO_UPDATE
SSH 端口：$SSH_PORT
SSH 白名单：仅 Cloudflare 全部 ASN 当前宣告前缀
EOF

  cat <<EOF

重要提示：
  回滚保护将在 ${ROLLBACK_SECONDS} 秒内保持有效。
  确认 SSH 和网络正常后，请运行以下命令保留新规则：

    sudo $INSTALL_PATH confirm

  如需立即手动回滚，请运行：

    sudo $INSTALL_PATH rollback
EOF
}

apply_rules() {
  validate_script_source
  need_root
  set_stage "检查并安装依赖"
  apt_install_missing
  validate_deps
  set_stage "读取 SSH 端口"
  prompt_ssh_port
  normalize_cloudflare_asns
  set_stage "备份当前防火墙规则"
  backup_rules
  start_rollback_guard
  trap 'handle_apply_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR
  set_stage "迁移旧版持久化文件"
  migrate_legacy_state
  set_stage "下载 ASN 和 IP 前缀数据"
  download_lists
  set_stage "载入 ipset 集合"
  load_ipsets
  set_stage "应用 IPv4 防火墙规则"
  apply_ipv4_rules
  set_stage "应用 IPv6 防火墙规则"
  apply_ipv6_rules
  set_stage "清理旧版国家白名单"
  remove_legacy_country_whitelists
  set_stage "检查网络连通性"
  connectivity_check
  set_stage "写入配置和持久化规则"
  write_config
  persist_rules
  set_stage "安装脚本和 systemd 定时任务"
  install_self
  install_systemd_units
  trap - ERR
  set_stage "完成"
  print_summary
}

usage() {
  cat <<EOF
用法：$0 [apply|confirm|rollback|refresh|diagnose]

命令：
  apply       交互式应用并持久化规则（默认命令）
  confirm     确认保留新规则，取消自动回滚
  rollback    使用最近一次备份立即回滚
  refresh     更新 IP 地址段并重新持久化规则
  diagnose    输出重启和持久化诊断信息（也可使用 diag）

环境变量：
  SSH_PORT=2222                    跳过 SSH 端口交互输入
  CLOUDFLARE_ASNS="AS13335 ..."    配合关闭自动发现，覆盖 ASN 清单
  CLOUDFLARE_ASN_AUTO_UPDATE=0      关闭 ASN 自动发现，固定使用配置清单
  ROLLBACK_SECONDS=300             未确认时等待多少秒后回滚
  ENABLE_IPV6=0                    禁用 IPv6 规则
  DRY_RUN=1                        尽可能只显示将执行的命令
EOF
}

main() {
  case "${1:-apply}" in
    apply) apply_rules ;;
    confirm) confirm_rules ;;
    rollback) rollback_latest ;;
    refresh) refresh_ipsets ;;
    diagnose|diag) diagnose_rules ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
