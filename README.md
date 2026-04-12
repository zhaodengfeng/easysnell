# EasySnell

一个安全、健壮、跨发行版兼容的 **Snell** 协议一键部署与管理脚本。

> Snell 是由 [Surge](https://nssurge.com) 团队开发的高性能加密代理协议，专为 Surge 用户设计。

---

## ✨ 特性

- **一键部署**：全自动下载、配置、启动 Snell 服务
- **跨发行版兼容**：支持 Debian/Ubuntu、CentOS/RHEL/Alma/Rocky/Fedora、Arch/Manjaro
- **systemd 专用**：针对现代 Linux 发行版优化（要求 systemd）
- **自动防火墙**：自动放行 ufw / firewalld / iptables 端口
- **BBR 加速**：内核 5.0+ 自动开启 BBR 网络优化
- **配置备份**：重新安装时自动备份旧配置，防止误覆盖
- **非交互模式**：支持 `-q/--quick` 自动化部署
- **完整 CLI**：安装、更新、卸载、启停、查看配置一键完成

---

## 🚀 快速开始

**要求：** root 权限 + systemd

```bash
# 方式一：交互式菜单（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/zhaodengfeng/easysnell/main/easysnell.sh)

# 方式二：全自动快速安装
bash <(curl -fsSL https://raw.githubusercontent.com/zhaodengfeng/easysnell/main/easysnell.sh) --quick
```

安装完成后，终端会输出可直接复制到 Surge 中的配置行。

---

## 📋 支持的系统

| 系统 | 状态 |
|------|------|
| Debian 9+ | ✅ |
| Ubuntu 18.04+ | ✅ |
| CentOS 7+ | ✅ |
| RHEL / AlmaLinux / Rocky Linux 8+ | ✅ |
| Fedora | ✅ |
| Arch Linux / Manjaro | ✅ |
| Alpine Linux / Docker / WSL1 | ❌（无 systemd） |

---

## 🛠️ 使用方式

### 交互式菜单

不带参数运行脚本即可进入菜单：

```bash
bash easysnell.sh
```

菜单选项：
1. 安装 Snell 服务
2. 卸载 Snell 服务
3. 启动 / 停止 Snell 服务
4. 更新 Snell 服务
5. 查看 Snell 配置
0. 退出

### 快捷参数

```bash
bash easysnell.sh -q, --quick           # 非交互式快速安装（随机参数）
bash easysnell.sh -y, --yes             # 同上
bash easysnell.sh -u, --uninstall       # 卸载（带确认提示）
bash easysnell.sh -f, --force-uninstall # 强制卸载（跳过确认）
bash easysnell.sh -U, --update          # 更新 Snell 二进制
bash easysnell.sh -r, --restart         # 重启服务
bash easysnell.sh --start               # 启动服务
bash easysnell.sh --stop                # 停止服务
bash easysnell.sh -s, --status          # 查看服务状态
bash easysnell.sh -v, --version         # 显示版本信息
bash easysnell.sh -c, --config          # 查看配置
bash easysnell.sh -h, --help            # 显示帮助
```

### 环境变量

```bash
NO_COLOR=1            # 禁用颜色输出
EASYSNELL_NO_CLEAR=1  # 禁用菜单清屏
```

---

## 🔧 常用命令

```bash
# 服务管理
systemctl start snell
systemctl stop snell
systemctl restart snell
systemctl status snell

# 查看日志
journalctl -u snell -f
journalctl -u snell -n 20 --no-pager

# 查看配置
cat /etc/snell/snell-server.conf
cat /etc/snell/surge-config.txt
```

---

## ⚙️ 配置文件说明

脚本安装后会生成两个配置文件：

- `/etc/snell/snell-server.conf` — Snell 服务端配置文件
- `/etc/snell/surge-config.txt` — 可直接复制到 Surge 客户端使用的配置行

### Snell 服务端配置示例

```ini
[snell-server]
listen = ::0:44321
psk = x7k9mP2qR5sL8vN4wJ6yZ
ipv6 = true
udp = true
obfs = tls
obfs-host = bing.com
```

### Surge 客户端配置示例

```ini
US = snell, 1.2.3.4, 44321, psk = x7k9mP2qR5sL8vN4wJ6yZ, version = 5, reuse = true, obfs = tls, obfs-host = bing.com
```

---

## 🔒 安全设计

- **低权限运行**：服务以独立的 `snell` 用户运行
- **文件权限限制**：配置文件默认 `640`，备份文件 `600`
- **临时文件安全**：使用 `mktemp` 生成不可预测的临时路径，失败时自动清理
- **输入校验**：端口、PSK、obfs-host 均经过正则过滤
- **无 HTTP 回退**：IP 检测仅使用 HTTPS，避免中间人攻击
- **systemd 硬化**：服务单元包含 `NoNewPrivileges=true` 和 `PrivateTmp=true`

---

## ⚠️ 免责声明

本项目仅供学习和技术研究使用，请勿用于违反当地法律法规的活动。使用本脚本所产生的一切后果由使用者自行承担。

---

## 📄 许可证

[MIT License](./LICENSE)
