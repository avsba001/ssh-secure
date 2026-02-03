TMPDIR=$(mktemp -d) && cd "$TMPDIR" && \
curl -s https://api.github.com/repos/avsba001/kernel-build/releases/latest \
| grep -oP '"browser_download_url": "\K.*\.deb' \
| xargs -n 1 curl -LO && \
sudo dpkg -i *.deb && \
cd / && rm -rf "$TMPDIR"
