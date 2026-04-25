#!/usr/bin/env bash
set -euo pipefail

REPO="avsba001/kernel-build"
API_BASE="https://api.github.com/repos/${REPO}/releases"
MAX_PAGES=20

resolve_release_assets() {
  local series="$1"

  python3 - "$series" "$API_BASE" "$MAX_PAGES" <<'PY'
import json
import os
import re
import sys
import urllib.request

series = sys.argv[1]
api_base = sys.argv[2]
max_pages = int(sys.argv[3])

headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "xanmod-installer",
}

releases = []
for page in range(1, max_pages + 1):
    url = f"{api_base}?per_page=100&page={page}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as resp:
        page_data = json.load(resp)

    if not page_data:
        break

    releases.extend(page_data)

    if len(page_data) < 100:
        break

# 从资产文件名中提取并匹配内核版本，例如：
# linux-headers-6.18.24-x64v3-cloud-xanmod1_..._amd64.deb
asset_pattern = re.compile(
    r"^linux-(?:headers|image|modules|libc-dev)-(?P<kver>\d+\.\d+\.\d+)-.*\.deb$"
)
matches = []
for release in releases:
    tag = release.get("tag_name", "")
    publish_time = release.get("published_at") or release.get("created_at") or ""
    for asset in release.get("assets", []):
        url = asset.get("browser_download_url", "")
        if not url.endswith(".deb"):
            continue
        fname = asset.get("name") or os.path.basename(url)
        m = asset_pattern.match(fname)
        if not m:
            continue
        kver = m.group("kver")
        if not kver.startswith(series + "."):
            continue
        kver_key = tuple(int(x) for x in kver.split("."))
        matches.append((kver_key, kver, publish_time, tag, url))

if not matches:
    sys.exit(2)

# 先按内核版本选最新，再以发布时间兜底，输出该版本所有 deb
best_key, best_kver, _, _, _ = sorted(matches, key=lambda x: (x[0], x[2]))[-1]
deb_urls = sorted({u for key, kver, _, _, u in matches if key == best_key and kver == best_kver})

if not deb_urls:
    sys.exit(3)

print(best_kver)
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

  echo "正在获取 ${REPO} Releases（分页查询）..."

  set +e
  resolved="$(resolve_release_assets "$series")"
  status=$?
  set -e

  if [[ $status -eq 2 ]]; then
    echo "未找到 ${series} 系列可用的内核 .deb 资产，请检查 Releases 页面。" >&2
    exit 1
  elif [[ $status -eq 3 ]]; then
    echo "找到 ${series} 最新版本，但未包含 .deb 安装包。" >&2
    exit 1
  elif [[ $status -ne 0 ]]; then
    echo "解析 Releases 数据失败。" >&2
    exit 1
  fi

  mapfile -t lines <<< "$resolved"
  latest_kernel="${lines[0]}"
  deb_urls=("${lines[@]:1}")

  echo "已选择系列: ${series}"
  echo "将安装最新内核版本: ${latest_kernel}"

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
