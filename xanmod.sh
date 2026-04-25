#!/usr/bin/env bash
set -euo pipefail

REPO="avsba001/kernel-build"
API_URL="https://api.github.com/repos/${REPO}/releases?per_page=100"

fetch_releases_json() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: xanmod-installer" \
    "$API_URL"
}

resolve_release_assets() {
  local series="$1"
  local releases_json="$2"

  RELEASES_JSON="$releases_json" python3 - "$series" <<'PY'
import json
import os
import re
import sys

series = sys.argv[1]
data = json.loads(os.environ["RELEASES_JSON"])

pattern = re.compile(rf"^{re.escape(series)}(?:\.|$)")
candidates = []
for release in data:
    tag = release.get("tag_name", "")
    if pattern.match(tag):
        candidates.append((tag, release))

if not candidates:
    sys.exit(2)

# sort tags by numeric segments where possible, fallback to lexical
def vkey(tag: str):
    return [int(x) if x.isdigit() else x for x in re.split(r"([0-9]+)", tag)]

latest_tag, latest_release = sorted(candidates, key=lambda x: vkey(x[0]))[-1]
urls = [a.get("browser_download_url", "") for a in latest_release.get("assets", [])]
deb_urls = [u for u in urls if u.endswith(".deb")]

if not deb_urls:
    sys.exit(3)

print(latest_tag)
for u in deb_urls:
    print(u)
PY
}

main() {
  echo "请选择要安装的 XanMod 内核系列："
  PS3="输入序号 (1-2): "
  select series in "6.12" "6.18"; do
    case "${series:-}" in
      6.12|6.18) break ;;
      *) echo "无效选择，请重试。" ;;
    esac
  done

  echo "正在获取 ${REPO} Releases..."
  releases_json="$(fetch_releases_json)"

  set +e
  resolved="$(resolve_release_assets "$series" "$releases_json")"
  status=$?
  set -e

  if [[ $status -eq 2 ]]; then
    echo "未找到 ${series} 系列可用版本，请检查 Releases 页面。" >&2
    exit 1
  elif [[ $status -eq 3 ]]; then
    echo "找到 ${series} 最新版本，但未包含 .deb 安装包。" >&2
    exit 1
  elif [[ $status -ne 0 ]]; then
    echo "解析 Releases 数据失败。" >&2
    exit 1
  fi

  mapfile -t lines <<< "$resolved"
  latest_tag="${lines[0]}"
  deb_urls=("${lines[@]:1}")

  echo "已选择系列: ${series}"
  echo "将安装最新版本: ${latest_tag}"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  cd "$tmpdir"

  for url in "${deb_urls[@]}"; do
    echo "下载: $url"
    curl -fL -O "$url"
  done

  echo "安装内核包..."
  sudo dpkg -i ./*.deb
  echo "安装完成。建议重启系统以加载新内核。"
}

main "$@"
