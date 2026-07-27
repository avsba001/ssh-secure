# vps-secure

VPS 安全与网络优化一键工具。`vps-secure.sh` 是主入口脚本，提供交互式菜单，并按需下载和执行各功能脚本。

## 功能菜单

| 选项 | 调用脚本 | 作用 |
| --- | --- | --- |
| 1 | `sshd-secure-setup.sh` | 交互式加固 SSHD，配置端口、root 登录策略、密码登录、转发、加密算法和 KeepAlive。 |
| 2 | `cake.sh` | 配置 CAKE 队列管理，并创建 systemd 服务实现开机自动应用。 |
| 3 | `fail2ban.sh` | 安装并配置 Fail2Ban、UFW 与 ipset，对 SSH 爆破进行更强拦截和持久化封禁；可选择启用 Cloudflare ASN ipset 白名单保护，避免误封 Cloudflare IP。 |
| 4 | `xanmod.sh` | 从指定内核仓库选择并安装 XanMod Cloud 精简内核。 |
| 5 | `cn-ipset.sh` | 下载中国 IP 段，使用 ipset + iptables 屏蔽来自中国 IP 的 ICMP，并通过 systemd 开机应用。 |
| 6 | `pmtu-mss.sh` | 设置 iptables/ip6tables mangle 规则，按 MTU 自动计算并固定 TCP MSS，缓解 PMTU 问题。 |
| 7 | `cloudflare-ssh.sh` | SSH 默认仅允许 Cloudflare ASN 当前宣告的 IP 前缀访问，可选额外加入中国全量或指定省份 IP 白名单，同时屏蔽中国 IP 段 ICMP/ICMPv6，并配置定时更新和回滚保护。 |
| 8 | `ssh-whitelist-check.sh` | 检查当前生效的 SSH 白名单链和 ipset 集合，显示 Cloudflare ASN、中国全量或中国省份等 IP 段归属。 |
| 9 | 全部配置脚本 | 按顺序执行配置类功能。 |
| 10 | 主脚本内置 | 从最近备份撤销已支持的修改。 |

## 一键运行

```bash
bash <(curl -sL https://raw.githubusercontent.com/avsba001/vps-secure/refs/heads/main/vps-secure.sh)
```

国内加速：

```bash
bash <(curl -sL https://gh-proxy.com/https://raw.githubusercontent.com/avsba001/vps-secure/refs/heads/main/vps-secure.sh)
```

## 使用说明

- 请使用 `root` 用户运行。
- 主脚本会先检查远程 `VERSION`，发现新版本时自动更新后再继续执行。
- 大部分修改会在 `/var/backups/vps-secure` 下保存最近备份，可通过菜单中的“撤销修改”恢复。
- `xanmod.sh` 安装内核后需要重启系统才能加载新内核，主脚本不提供自动回滚。
- `cloudflare-ssh.sh` 自带回滚保护。应用后请按脚本提示确认 SSH 和网络正常，再执行确认命令保留规则。
