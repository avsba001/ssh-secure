#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 12 firewall guard:
# 1. Drop ICMP/ICMPv6 from China IP ranges.
# 2. Allow SSH only from Cloudflare and China IP ranges.
# 3. Use ipset for fast matching.
# 4. Persist rules, refresh IP ranges by systemd timer, and rollback automatically.

SSH_PORT="${SSH_PORT:-}"
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-180}"
ALLOW_ESTABLISHED="${ALLOW_ESTABLISHED:-1}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
DRY_RUN="${DRY_RUN:-0}"

CN_URL="${CN_URL:-https://www.ipdeny.com/ipblocks/data/countries/cn.zone}"
CN_IPV6_URL="${CN_IPV6_URL:-https://www.ipdeny.com/ipv6/ipaddresses/blocks/cn.zone}"
CF_IPV4_URL="${CF_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CF_IPV6_URL="${CF_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
CONNECTIVITY_TARGETS="${CONNECTIVITY_TARGETS:-1.1.1.1 8.8.8.8}"

WORKDIR="${WORKDIR:-/var/tmp/firewall-ipset-guard}"
STATE_DIR="${STATE_DIR:-/etc/fwguard-ipset}"
PERSIST_DIR="${PERSIST_DIR:-/etc/iptables}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/fwguard-firewall}"
IPSET_PERSIST_FILE="$PERSIST_DIR/ipsets.rules"
CONFIRM_FILE="$WORKDIR/confirm-keep-rules"
BACKUP_DIR="$WORKDIR/backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"
LOG_FILE="$BACKUP_DIR/run.log"

IPSET_CN4="fwguard_cn_ipv4"
IPSET_CN6="fwguard_cn_ipv6"
IPSET_CF4="fwguard_cloudflare_ipv4"
IPSET_CF6="fwguard_cloudflare_ipv6"
CHAIN_V4="SSH_CF_CN_GUARD"
CHAIN_ICMP_V4="CN_ICMP_DROP"
CHAIN_V6="SSH_CF_CN_GUARD_V6"
CHAIN_ICMP_V6="CN_ICMP_DROP_V6"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root." >&2
    exit 1
  fi
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

apt_install_missing() {
  local missing=()
  local packages=(iptables ipset iptables-persistent netfilter-persistent curl iputils-ping systemd)
  local pkg

  for cmd in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore ipset ping curl systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: missing commands: ${missing[*]}" >&2
    echo "ERROR: apt-get not found. This script defaults to Debian 12." >&2
    exit 1
  fi

  for pkg in iptables-persistent netfilter-persistent; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done

  [[ "${#missing[@]}" -eq 0 ]] && return 0

  echo "Missing dependencies/packages: ${missing[*]}"
  echo "Installing Debian 12 packages: ${packages[*]}"

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
  for cmd in iptables iptables-save iptables-restore ipset ping curl systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "ERROR: dependency still missing after install: $cmd" >&2
      exit 1
    }
  done
}

prompt_ssh_port() {
  local input

  if [[ -n "$SSH_PORT" ]]; then
    validate_ssh_port "$SSH_PORT"
    return 0
  fi

  read -r -p "请输入 SSH 端口 [22]: " input
  SSH_PORT="${input:-22}"
  validate_ssh_port "$SSH_PORT"
}

validate_ssh_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    echo "ERROR: invalid SSH port: $port" >&2
    exit 1
  fi
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
ipset destroy "$IPSET_CN4" 2>/dev/null || true
ipset destroy "$IPSET_CN6" 2>/dev/null || true
ipset destroy "$IPSET_CF4" 2>/dev/null || true
ipset destroy "$IPSET_CF6" 2>/dev/null || true
if [[ -s "$BACKUP_DIR/ipset.runtime.rules" ]]; then
  ipset restore -exist < "$BACKUP_DIR/ipset.runtime.rules" || true
fi

restore_file "$BACKUP_DIR/rules.v4.bak" "$PERSIST_DIR/rules.v4"
restore_file "$BACKUP_DIR/rules.v6.bak" "$PERSIST_DIR/rules.v6"
restore_file "$BACKUP_DIR/ipsets.rules.bak" "$IPSET_PERSIST_FILE"
restore_file "$BACKUP_DIR/config.bak" "$STATE_DIR/config"
systemctl disable --now fwguard-ipset-refresh.timer >/dev/null 2>&1 || true
systemctl disable --now fwguard-ipset-restore.service >/dev/null 2>&1 || true
echo "Rollback completed from $BACKUP_DIR"
EOF
  chmod 700 "$ROLLBACK_SCRIPT"
}

start_rollback_guard() {
  rm -f "$CONFIRM_FILE"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] rollback guard would run after ${ROLLBACK_SECONDS}s"
    return
  fi

  nohup bash -c "
    sleep '$ROLLBACK_SECONDS'
    if [[ ! -f '$CONFIRM_FILE' ]]; then
      echo \"No confirmation file found; rolling back.\" >> '$LOG_FILE'
      bash '$ROLLBACK_SCRIPT' >> '$LOG_FILE' 2>&1
    fi
  " >/dev/null 2>&1 &
  echo "$!" > "$BACKUP_DIR/rollback-guard.pid"
}

download_lists() {
  mkdir -p "$STATE_DIR"
  fetch "$CN_URL" "$STATE_DIR/cn.zone"
  fetch "$CF_IPV4_URL" "$STATE_DIR/cloudflare-ips-v4"

  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$STATE_DIR/cn.zone" > "$STATE_DIR/cn-v4.clean" || true
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$STATE_DIR/cloudflare-ips-v4" > "$STATE_DIR/cf-v4.clean" || true

  if [[ ! -s "$STATE_DIR/cn-v4.clean" || ! -s "$STATE_DIR/cf-v4.clean" ]]; then
    echo "ERROR: downloaded IPv4 lists are empty or invalid." >&2
    exit 1
  fi

  if [[ "$ENABLE_IPV6" == "1" ]]; then
    fetch "$CN_IPV6_URL" "$STATE_DIR/cn-v6.zone"
    fetch "$CF_IPV6_URL" "$STATE_DIR/cloudflare-ips-v6"
    grep -E '^[0-9a-fA-F:]+/[0-9]+$' "$STATE_DIR/cn-v6.zone" > "$STATE_DIR/cn-v6.clean" || true
    grep -E '^[0-9a-fA-F:]+/[0-9]+$' "$STATE_DIR/cloudflare-ips-v6" > "$STATE_DIR/cf-v6.clean" || true

    if [[ ! -s "$STATE_DIR/cn-v6.clean" || ! -s "$STATE_DIR/cf-v6.clean" ]]; then
      echo "ERROR: downloaded IPv6 lists are empty or invalid." >&2
      exit 1
    fi
  fi
}

load_one_set() {
  local set_name="$1"
  local family="$2"
  local list_file="$3"
  local tmp_set="${set_name}_tmp"

  run ipset create "$tmp_set" hash:net family "$family" -exist
  run ipset flush "$tmp_set"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && run ipset add "$tmp_set" "$cidr" -exist
  done < "$list_file"

  run ipset create "$set_name" hash:net family "$family" -exist
  run ipset swap "$tmp_set" "$set_name"
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

  while spec="$("$table_cmd" -S INPUT 2>/dev/null | grep -- "-j $chain" | head -n 1 | sed 's/^-A INPUT /-D INPUT /')" && [[ -n "$spec" ]]; do
    # shellcheck disable=SC2086
    run "$table_cmd" $spec
    [[ "$DRY_RUN" == "1" ]] && break
  done
}

apply_ipv4_rules() {
  remove_input_jumps_to_chain iptables "$CHAIN_V4"
  remove_input_jumps_to_chain iptables "$CHAIN_ICMP_V4"

  run iptables -N "$CHAIN_V4" 2>/dev/null || true
  run iptables -F "$CHAIN_V4"
  run iptables -A "$CHAIN_V4" -m set --match-set "$IPSET_CF4" src -j ACCEPT
  run iptables -A "$CHAIN_V4" -m set --match-set "$IPSET_CN4" src -j ACCEPT
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
  [[ "$ENABLE_IPV6" == "1" ]] || return 0

  remove_input_jumps_to_chain ip6tables "$CHAIN_V6"
  remove_input_jumps_to_chain ip6tables "$CHAIN_ICMP_V6"

  run ip6tables -N "$CHAIN_V6" 2>/dev/null || true
  run ip6tables -F "$CHAIN_V6"
  run ip6tables -A "$CHAIN_V6" -m set --match-set "$IPSET_CF6" src -j ACCEPT
  run ip6tables -A "$CHAIN_V6" -m set --match-set "$IPSET_CN6" src -j ACCEPT
  run ip6tables -A "$CHAIN_V6" -j DROP

  run ip6tables -N "$CHAIN_ICMP_V6" 2>/dev/null || true
  run ip6tables -F "$CHAIN_ICMP_V6"
  run ip6tables -A "$CHAIN_ICMP_V6" -m set --match-set "$IPSET_CN6" src -j DROP
  run ip6tables -A "$CHAIN_ICMP_V6" -j RETURN

  [[ "$ALLOW_ESTABLISHED" == "1" ]] && ensure_established_rule ip6tables
  ensure_jump ip6tables "$CHAIN_V6" tcp 2 --dport "$SSH_PORT"
  ensure_jump ip6tables "$CHAIN_ICMP_V6" ipv6-icmp 2
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
    echo "ERROR: connectivity check failed; rolling back." >&2
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
CF_IPV4_URL="$CF_IPV4_URL"
CF_IPV6_URL="$CF_IPV6_URL"
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

  mkdir -p "$PERSIST_DIR"
  tmp_file="$(mktemp)"
  for set_name in "$IPSET_CN4" "$IPSET_CN6" "$IPSET_CF4" "$IPSET_CF6"; do
    ipset list "$set_name" >/dev/null 2>&1 && ipset save "$set_name" >> "$tmp_file"
  done
  install -m 0600 "$tmp_file" "$IPSET_PERSIST_FILE"
  rm -f "$tmp_file"
  iptables-save > "$PERSIST_DIR/rules.v4"
  [[ "$ENABLE_IPV6" == "1" ]] && ip6tables-save > "$PERSIST_DIR/rules.v6"
}

install_self() {
  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$INSTALL_PATH" ]]; then
    run install -m 0755 "${BASH_SOURCE[0]}" "$INSTALL_PATH"
  fi
}

install_systemd_units() {
  run tee /etc/systemd/system/fwguard-ipset-restore.service >/dev/null <<EOF
[Unit]
Description=Restore fwguard ipsets before persistent iptables
DefaultDependencies=no
Before=netfilter-persistent.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test ! -s $IPSET_PERSIST_FILE || /usr/sbin/ipset restore -exist < $IPSET_PERSIST_FILE'

[Install]
WantedBy=multi-user.target
EOF

  run tee /etc/systemd/system/fwguard-ipset-refresh.service >/dev/null <<EOF
[Unit]
Description=Refresh Cloudflare and China ipsets for fwguard
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH refresh
EOF

  run tee /etc/systemd/system/fwguard-ipset-refresh.timer >/dev/null <<EOF
[Unit]
Description=Daily fwguard ipset refresh

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
  run systemctl enable --now fwguard-ipset-refresh.timer
  run systemctl enable netfilter-persistent.service >/dev/null 2>&1 || true
}

load_config_if_present() {
  if [[ -f "$STATE_DIR/config" ]]; then
    # shellcheck disable=SC1091
    source "$STATE_DIR/config"
  fi
}

refresh_ipsets() {
  need_root
  apt_install_missing
  validate_deps
  load_config_if_present
  validate_ssh_port "${SSH_PORT:-22}"
  SSH_PORT="${SSH_PORT:-22}"
  download_lists
  load_ipsets
  apply_ipv4_rules
  apply_ipv6_rules
  persist_rules
  echo "Refreshed ipsets and persisted firewall rules."
}

confirm_rules() {
  need_root
  mkdir -p "$WORKDIR"
  touch "$CONFIRM_FILE"
  echo "Confirmed. Rollback guard will leave the persistent rules in place."
}

rollback_latest() {
  need_root
  local latest
  latest="$(ls -dt "$WORKDIR"/backup-* 2>/dev/null | head -n 1 || true)"
  [[ -n "${latest:-}" && -x "$latest/rollback.sh" ]] || {
    echo "ERROR: no rollback backup found under $WORKDIR." >&2
    exit 1
  }
  bash "$latest/rollback.sh"
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
Applied and persisted firewall rules.

Backup directory: $BACKUP_DIR
Persistent files:
  $IPSET_PERSIST_FILE
  $PERSIST_DIR/rules.v4
  $PERSIST_DIR/rules.v6
Systemd timer:
  fwguard-ipset-refresh.timer

China IPv4 CIDRs: $cn4
China IPv6 CIDRs: $cn6
Cloudflare IPv4 CIDRs: $cf4
Cloudflare IPv6 CIDRs: $cf6
SSH port: $SSH_PORT

IMPORTANT:
  A rollback guard is active for ${ROLLBACK_SECONDS} seconds.
  If SSH/network is OK and you want to keep these rules, run:

    sudo $INSTALL_PATH confirm

  To manually rollback now, run:

    sudo $INSTALL_PATH rollback
EOF
}

apply_rules() {
  need_root
  apt_install_missing
  validate_deps
  prompt_ssh_port
  backup_rules
  start_rollback_guard
  trap 'echo "ERROR: apply failed; rolling back." >&2; [[ "$DRY_RUN" == "1" ]] || bash "$ROLLBACK_SCRIPT"; exit 1' ERR
  download_lists
  load_ipsets
  apply_ipv4_rules
  apply_ipv6_rules
  connectivity_check
  write_config
  persist_rules
  install_self
  install_systemd_units
  trap - ERR
  print_summary
}

usage() {
  cat <<EOF
Usage: $0 [apply|confirm|rollback|refresh]

Environment:
  SSH_PORT=2222              Skip interactive SSH port prompt
  ROLLBACK_SECONDS=300       Roll back if not confirmed in this many seconds
  ENABLE_IPV6=0              Disable IPv6 rules
  DRY_RUN=1                  Print commands where possible
EOF
}

main() {
  case "${1:-apply}" in
    apply) apply_rules ;;
    confirm) confirm_rules ;;
    rollback) rollback_latest ;;
    refresh) refresh_ipsets ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
