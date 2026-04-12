#!/usr/bin/env bash
#===============================================================================
#  easysnell - Snell 协议一键部署与管理脚本
#  https://github.com/zhaodengfeng/easysnell
#  支持: Debian/Ubuntu/CentOS/RHEL/Alma/Rocky/Fedora/Arch/Manjaro
#===============================================================================

set -euo pipefail

# Constants
readonly VERSION="v5.0.1"
readonly SCRIPT_VERSION="1.2.0"
readonly SNELL_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/snell"
readonly SERVICE_FILE="/etc/systemd/system/snell.service"

readonly RANDOM_PORT_MIN=30000
readonly RANDOM_PORT_MAX=65000
readonly PSK_LENGTH=24
readonly CURL_TIMEOUT=5
readonly APT_LOCK_WAIT_MAX=60
readonly SYSTEMD_CAP_VER=229
readonly LIMIT_NOFILE=32768
readonly SERVICE_VERIFY_SLEEP=2
readonly JOURNAL_TAIL_LINES=20

# Colors (TTY detection + NO_COLOR support)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; RESET=''
fi

# Logging helpers (use printf to avoid argument injection)
log_info()  { printf '%b[INFO]%b  %s\n' "$GREEN" "$RESET" "$*" >&2; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$*" >&2; }
log_step()  { printf '%b[STEP]%b  %s\n' "$BLUE" "$RESET" "$*" >&2; }

#===============================================================================
# 系统检测
#===============================================================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID" | tr '[:upper:]' '[:lower:]'
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        uname -s | tr '[:upper:]' '[:lower:]'
    fi
}

detect_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l)        echo "armv7l" ;;
        i386|i686)     echo "i386" ;;
        *)             echo "unknown" ;;
    esac
}

detect_ip() {
    local ip
    ip=$(curl -fsSL -m "${CURL_TIMEOUT}" https://api.ipify.org 2>/dev/null | tr -d '\n\r' || echo "")
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=""
    fi
    echo "$ip"
}

detect_country() {
    local ip=$1
    local country
    country=$(curl -fsSL -m "${CURL_TIMEOUT}" "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\n\r' | grep -oE '^[A-Z]{2}$' || echo "UN")
    echo "$country"
}

#===============================================================================
# 前置检查
#===============================================================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "请以 root 权限运行此脚本 (sudo -i)"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl &>/dev/null; then
        log_error "未检测到 systemd。本脚本目前仅支持 systemd 的系统。"
        log_error "Alpine / Docker (无 systemd) / WSL1 等环境请手动部署。"
        exit 1
    fi
}

wait_for_apt() {
    local i=0
    local has_fuser=0
    command -v fuser &>/dev/null && has_fuser=1

    if [[ $has_fuser -eq 0 ]]; then
        log_warn "未检测到 fuser，跳过 apt 锁等待检测"
        return 0
    fi

    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        log_warn "等待其他 apt 进程释放... (${i})"
        sleep 2
        i=$((i + 1))
        if [[ $i -gt APT_LOCK_WAIT_MAX ]]; then
            log_error "apt 锁等待超时"
            exit 1
        fi
    done
}

install_deps() {
    local os=$1
    log_step "安装必要依赖..."
    case "$os" in
        debian|ubuntu)
            wait_for_apt
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq wget curl unzip iptables ip6tables
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command -v dnf &>/dev/null; then
                dnf -y -q install wget curl unzip iptables-services
            else
                yum -y -q install wget curl unzip iptables-services
            fi
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm --needed wget curl unzip iptables
            ;;
        alpine)
            apk add --no-cache wget curl unzip iptables coreutils
            ;;
        *)
            log_error "不支持的系统: $os"
            exit 1
            ;;
    esac
}

#===============================================================================
# 网络优化 (BBR)
#===============================================================================
enable_bbr() {
    log_step "检测并尝试开启 BBR..."
    local kernel_major
    kernel_major=$(uname -r | cut -d. -f1)
    if [[ "$kernel_major" -ge 5 ]]; then
        if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            if [[ ! -f /etc/sysctl.d/99-bbr.conf ]]; then
                printf '%s\n%s\n' "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf
            fi
            sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
            if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
                log_info "BBR 已开启"
            else
                log_warn "BBR 配置已写入 /etc/sysctl.d/99-bbr.conf，重启后生效"
            fi
        else
            log_info "BBR 已经处于开启状态"
        fi
    else
        log_warn "内核版本 < 5.0，无法开启 BBR (当前: $(uname -r))"
    fi
}

#===============================================================================
# 防火墙配置
#===============================================================================
open_firewall_port() {
    local port=$1
    local proto=${2:-tcp}
    log_step "放行防火墙端口 ${port}/${proto}..."

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status numbered 2>/dev/null | grep -qE "\[.*\]\s+${port}/${proto}\s+"; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
            log_info "ufw 已放行 ${port}/${proto}"
        fi
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if ! firewall-cmd --list-ports 2>/dev/null | grep -qw "${port}/${proto}"; then
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            log_info "firewalld 已放行 ${port}/${proto}"
        fi
    fi

    iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true

    ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
}

close_firewall_port() {
    local port=$1
    local proto=${2:-tcp}
    log_step "撤销防火墙端口 ${port}/${proto}..."

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw status numbered 2>/dev/null | grep -qE "\[.*\]\s+${port}/${proto}\s+" && \
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || true
}

#===============================================================================
# 下载 Snell
#===============================================================================
download_snell() {
    local arch=$1
    local tmp_file=$2
    local url
    url="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${arch}.zip"

    log_step "下载 Snell ${VERSION} (${arch})..."
    if curl -fL --connect-timeout 10 --max-time 60 -o "${tmp_file}" "${url}"; then
        log_info "下载成功"
        return 0
    fi

    log_warn "官方源失败，尝试 GitHub 备用源..."
    local fallback_url
    fallback_url="https://github.com/surge-networks/snell/releases/download/${VERSION}/snell-server-${VERSION}-linux-${arch}.zip"
    if curl -fL --connect-timeout 10 --max-time 60 -o "${tmp_file}" "${fallback_url}"; then
        log_info "备用源下载成功"
        return 0
    fi

    log_error "下载失败，请检查网络连接"
    log_error "尝试的 URL: ${url} 和 ${fallback_url}"
    return 1
}

#===============================================================================
# 二进制部署
#===============================================================================
deploy_binary() {
    local tmp_file=$1
    local tmp_dir
    tmp_dir=$(mktemp -d)
    unzip -joq "${tmp_file}" -d "${tmp_dir}"
    mkdir -p "${SNELL_DIR}"
    mv "${tmp_dir}/snell-server" "${SNELL_DIR}/snell-server"
    rm -rf "${tmp_dir}"
    chmod +x "${SNELL_DIR}/snell-server"
}

#===============================================================================
# 配置生成
#===============================================================================
generate_config() {
    local port=$1
    local psk=$2
    local ipv6=$3
    local obfs=${4:-}
    local obfs_host=${5:-}
    local udp=${6:-true}

    mkdir -p "${CONF_DIR}"

    local config_body
    config_body="[snell-server]
listen = ::0:${port}
psk = ${psk}
ipv6 = ${ipv6}"

    if [[ -n "${obfs}" ]]; then
        config_body="${config_body}
obfs = ${obfs}"
        [[ -n "${obfs_host}" ]] && config_body="${config_body}
obfs-host = ${obfs_host}"
    fi

    [[ "${udp}" == "true" ]] && config_body="${config_body}
udp = true"

    printf '%s\n' "$config_body" > "${CONF_DIR}/snell-server.conf"
}

create_systemd_service() {
    local systemd_ver
    systemd_ver=$(systemctl --version | head -1 | grep -oE '[0-9]+' | head -1)

    local cap_lines=""
    if [[ -n "$systemd_ver" && "$systemd_ver" -ge "$SYSTEMD_CAP_VER" ]]; then
        cap_lines="AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW"
    else
        cap_lines="CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW"
    fi

    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snell
Group=snell
ExecStart=${SNELL_DIR}/snell-server -c ${CONF_DIR}/snell-server.conf
${cap_lines}
LimitNOFILE=${LIMIT_NOFILE}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

#===============================================================================
# 备份与恢复
#===============================================================================
backup_config() {
    if [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        local conf_bak
        conf_bak="${CONF_DIR}/snell-server.conf.bak.$(date +%s).${RANDOM}"
        cp "${CONF_DIR}/snell-server.conf" "${conf_bak}"
        chmod 600 "${conf_bak}"
        log_warn "检测到已有配置，已备份至 ${conf_bak}"
    fi
    if [[ -f "${CONF_DIR}/surge-config.txt" ]]; then
        local surge_bak
        surge_bak="${CONF_DIR}/surge-config.txt.bak.$(date +%s).${RANDOM}"
        cp "${CONF_DIR}/surge-config.txt" "${surge_bak}"
        chmod 600 "${surge_bak}"
    fi
}

#===============================================================================
# 随机生成器 (纯 Bash + /dev/urandom)
#===============================================================================
random_port() {
    local range=$((RANDOM_PORT_MAX - RANDOM_PORT_MIN + 1))
    local rand
    rand=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    echo "$((RANDOM_PORT_MIN + rand % range))"
}

random_psk() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${PSK_LENGTH}"
}

#===============================================================================
# 输入校验
#===============================================================================
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_error "端口号无效: ${port}"
        return 1
    fi
    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
        log_error "端口 ${port} 已被占用"
        return 1
    fi
    return 0
}

validate_psk() {
    local psk=$1
    if [[ -z "$psk" ]]; then
        log_error "PSK 不能为空"
        return 1
    fi
    if [[ ! "$psk" =~ ^[A-Za-z0-9@#\$%^\&*+=_-]+$ ]]; then
        log_error "PSK 包含非法字符，仅允许字母、数字及 @#\$%^\&*+=_-"
        return 1
    fi
    return 0
}

validate_obfs_host() {
    local host=$1
    if [[ -n "$host" && ! "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_warn "非法的 obfs-host，已忽略"
        return 1
    fi
    return 0
}

#===============================================================================
# 用户创建
#===============================================================================
find_nologin_shell() {
    for shell in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/nologin /bin/false; do
        if [[ -x "$shell" ]]; then
            echo "$shell"
            return 0
        fi
    done
    echo "/bin/false"
}

create_snell_user() {
    local os=$1
    local nologin_shell
    nologin_shell=$(find_nologin_shell)

    if id "snell" &>/dev/null; then
        return 0
    fi

    if command -v useradd &>/dev/null; then
        useradd -r -s "${nologin_shell}" -M snell
    elif command -v adduser &>/dev/null; then
        case "$os" in
            alpine)
                adduser -S -s "${nologin_shell}" -H -D snell
                ;;
            *)
                # Debian/Ubuntu 的 adduser 语法不同，尽量使用 useradd
                log_error "当前系统 adduser 语义不确定，且未找到 useradd"
                exit 1
                ;;
        esac
    else
        log_error "无法创建 snell 用户，请手动安装 useradd 或 adduser"
        exit 1
    fi
}

#===============================================================================
# 安装流程
#===============================================================================
install_snell() {
    local auto=${1:-false}
    local os
    local arch
    local ip
    local country
    local port
    local psk
    local obfs
    local obfs_host
    local udp
    local ipv6

    os=$(detect_os)
    arch=$(detect_arch)
    ip=$(detect_ip)

    if [[ -z "$ip" ]]; then
        log_warn "无法获取公网 IP，将使用 127.0.0.1 作为占位符"
        ip="127.0.0.1"
    fi

    country=$(detect_country "${ip}")

    if [[ "$arch" == "unknown" ]]; then
        log_error "不支持的架构: $(uname -m)"
        exit 1
    fi

    log_info "系统: ${os} | 架构: ${arch} | IP: ${ip}"

    if [[ "$auto" == "true" ]]; then
        port=$(random_port)
        while ! validate_port "$port"; do
            port=$(random_port)
        done
        psk=$(random_psk)
        ipv6="true"
        udp="true"
        obfs=""
        obfs_host=""
    else
        echo ""
        read -rp "请输入监听端口 [随机 ${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX}]: " port_input
        port=${port_input:-$(random_port)}
        if ! validate_port "$port"; then
            exit 1
        fi

        read -rp "请输入 PSK [随机生成]: " psk_input
        psk=${psk_input:-$(random_psk)}
        if ! validate_psk "$psk"; then
            exit 1
        fi

        read -rp "是否启用 IPv6? [Y/n]: " ipv6_input
        ipv6=${ipv6_input:-Y}
        ipv6=$(echo "$ipv6" | tr '[:lower:]' '[:upper:]')
        case "$ipv6" in
            Y|YES) ipv6="true" ;;
            *)     ipv6="false" ;;
        esac

        read -rp "是否启用 UDP (v5 QUIC Proxy 建议开启)? [Y/n]: " udp_input
        udp=${udp_input:-Y}
        udp=$(echo "$udp" | tr '[:lower:]' '[:upper:]')
        case "$udp" in
            Y|YES) udp="true" ;;
            *)     udp="false" ;;
        esac

        read -rp "是否启用 obfs? 输入 tls/http [直接回车跳过]: " obfs_input
        obfs=${obfs_input:-}
        obfs=$(echo "$obfs" | tr '[:upper:]' '[:lower:]')
        if [[ -n "$obfs" ]]; then
            if [[ "$obfs" != "tls" && "$obfs" != "http" ]]; then
                log_warn "不支持的 obfs 类型: ${obfs}，已忽略"
                obfs=""
            else
                read -rp "请输入 obfs-host [bing.com]: " obfs_host_input
                obfs_host=$(echo "$obfs_host_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                obfs_host=${obfs_host:-bing.com}
                if ! validate_obfs_host "$obfs_host"; then
                    obfs_host=""
                fi
            fi
        fi
    fi

    install_deps "${os}"

    local tmp_file
    local tmp_dir
    tmp_file=$(mktemp)
    tmp_dir=$(mktemp -d)
    trap 'rm -f "${tmp_file}"; rm -rf "${tmp_dir}"' EXIT ERR

    download_snell "${arch}" "${tmp_file}"
    deploy_binary "${tmp_file}"

    rm -f "${tmp_file}"
    rm -rf "${tmp_dir}"
    trap - EXIT ERR

    create_snell_user "${os}"

    backup_config
    generate_config "${port}" "${psk}" "${ipv6}" "${obfs}" "${obfs_host}" "${udp}"
    chown -R snell:snell "${CONF_DIR}"
    chmod 640 "${CONF_DIR}/snell-server.conf"

    create_systemd_service
    systemctl daemon-reload
    systemctl enable snell
    if ! systemctl start snell; then
        log_error "Snell 服务启动失败，查看日志:"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    sleep "${SERVICE_VERIFY_SLEEP}"
    if systemctl is-active --quiet snell; then
        log_info "Snell 服务运行正常"
    else
        log_error "Snell 服务未运行"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    open_firewall_port "${port}" "tcp"
    if [[ "${udp}" == "true" ]]; then
        open_firewall_port "${port}" "udp"
    fi

    enable_bbr

    cat > "${CONF_DIR}/surge-config.txt" << EOF
# Snell Server Config
# 生成时间: $(date '+%Y-%m-%dT%H:%M:%S%z')
# 服务器IP: ${ip}
# 注意: 请妥善保管 PSK，不要在公共日志中记录

${country} = snell, ${ip}, ${port}, psk = ${psk}, version = 5, reuse = true${obfs:+, obfs = $obfs}${obfs_host:+, obfs-host = $obfs_host}
EOF
    chmod 640 "${CONF_DIR}/surge-config.txt"
    chown snell:snell "${CONF_DIR}/surge-config.txt"

    echo ""
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}       Snell 部署成功!${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "  服务器IP: ${ip}"
    echo -e "  端口:     ${port}"
    echo -e "  PSK:      ${psk}"
    echo -e "  IPv6:     ${ipv6}"
    echo -e "  UDP:      ${udp}"
    [[ -n "$obfs" ]] && echo -e "  OBFS:     ${obfs}"
    [[ -n "$obfs_host" ]] && echo -e "  OBFS-HOST: ${obfs_host}"
    echo -e "${CYAN}--------------------------------------------${RESET}"
    echo -e "${YELLOW}Surge 配置行:${RESET}"
    grep -v '^#' "${CONF_DIR}/surge-config.txt"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "配置文件路径: ${CONF_DIR}/snell-server.conf"
    echo -e "Surge 配置路径: ${CONF_DIR}/surge-config.txt"
    echo -e "管理命令: systemctl {start|stop|restart|status} snell"
    echo -e "查看日志: journalctl -u snell -f"
    echo -e "${YELLOW}注意: 请妥善保管 PSK，不要在公共日志中记录。${RESET}"
    echo ""
}

#===============================================================================
# 更新 / 卸载 / 查看
#===============================================================================
update_snell() {
    if [[ ! -f "${SNELL_DIR}/snell-server" ]]; then
        log_warn "Snell 尚未安装"
        return
    fi
    log_step "正在更新 Snell..."

    local arch
    arch=$(detect_arch)

    local tmp_file
    local tmp_dir
    tmp_file=$(mktemp)
    tmp_dir=$(mktemp -d)
    trap 'rm -f "${tmp_file}"; rm -rf "${tmp_dir}"; systemctl start snell 2>/dev/null || true' EXIT ERR

    if ! download_snell "${arch}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        rm -rf "${tmp_dir}"
        trap - EXIT ERR
        exit 1
    fi

    systemctl stop snell || true
    deploy_binary "${tmp_file}"

    rm -f "${tmp_file}"
    rm -rf "${tmp_dir}"

    if systemctl restart snell; then
        trap - EXIT ERR
        log_info "更新完成"
    else
        log_error "更新后服务启动失败"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    sleep "${SERVICE_VERIFY_SLEEP}"
    if systemctl is-active --quiet snell; then
        log_info "服务运行正常"
    else
        log_error "服务未正常启动"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi
}

uninstall_snell() {
    local force=${1:-false}
    if [[ "$force" != "true" ]]; then
        read -rp "确认卸载并删除所有 Snell 配置? [y/N]: " confirm
        confirm=$(echo "$confirm" | tr '[:lower:]' '[:upper:]')
        if [[ "$confirm" != "Y" && "$confirm" != "YES" ]]; then
            log_info "已取消卸载"
            return
        fi
    fi

    log_step "正在卸载 Snell..."

    if [[ -d "${CONF_DIR}" ]]; then
        local bak_dir
        bak_dir="/etc/snell.bak.$(date +%s).${RANDOM}"
        cp -a "${CONF_DIR}" "${bak_dir}"
        chmod 700 "${bak_dir}"
        find "${bak_dir}" -type f -exec chmod 600 {} \;
        log_info "配置已备份至 ${bak_dir}"
    fi

    if [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        local old_port
        local old_udp
        old_port=$(grep -E '^listen' "${CONF_DIR}/snell-server.conf" 2>/dev/null | grep -oE '[0-9]+$' || echo "")
        old_udp=$(grep -E '^udp' "${CONF_DIR}/snell-server.conf" 2>/dev/null | grep -oE 'true|false' || echo "false")
        if [[ -n "$old_port" ]]; then
            close_firewall_port "$old_port" "tcp"
            [[ "$old_udp" == "true" ]] && close_firewall_port "$old_port" "udp"
        fi
    fi

    systemctl stop snell 2>/dev/null || true
    systemctl disable snell 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "${SNELL_DIR}/snell-server"
    rm -rf "${CONF_DIR}"
    rm -f /etc/sysctl.d/99-bbr.conf
    userdel snell 2>/dev/null || true
    log_info "Snell 已卸载"
}

show_config() {
    if [[ -f "${CONF_DIR}/surge-config.txt" ]]; then
        cat "${CONF_DIR}/surge-config.txt"
    elif [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        cat "${CONF_DIR}/snell-server.conf"
    else
        log_warn "配置文件不存在"
    fi
}

show_menu() {
    [[ -t 1 && -z "${EASYSNELL_NO_CLEAR:-}" ]] && clear
    local installed="未安装"
    local running="未启动"
    local ver="—"
    if [[ -f "${SNELL_DIR}/snell-server" ]]; then
        installed="已安装"
        ver=$("${SNELL_DIR}/snell-server" -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        systemctl is-active --quiet snell 2>/dev/null && running="运行中" || running="已停止"
    fi

    echo ""
    echo -e "${GREEN}======== EasySnell 管理工具 v${SCRIPT_VERSION} ========${RESET}"
    echo -e "  安装状态: ${installed}"
    echo -e "  运行状态: ${running}"
    echo -e "  当前版本: ${ver}"
    echo ""
    echo "  1. 安装 Snell 服务"
    echo "  2. 卸载 Snell 服务"
    if [[ -f "${SNELL_DIR}/snell-server" ]]; then
        if systemctl is-active --quiet snell 2>/dev/null; then
            echo "  3. 停止 Snell 服务"
        else
            echo "  3. 启动 Snell 服务"
        fi
    fi
    echo "  4. 更新 Snell 服务"
    echo "  5. 查看 Snell 配置"
    echo "  0. 退出"
    echo -e "${GREEN}=============================================${RESET}"
    read -rp "请选择 [0-5]: " choice
}

#===============================================================================
# 快捷参数支持
#===============================================================================
quick_install() {
    install_snell true
}

#===============================================================================
# 主入口
#===============================================================================
main() {
    check_root
    check_systemd

    case "${1:-}" in
        -q|--quick|quick)
            quick_install
            exit 0
            ;;
        -y|--yes|yes)
            install_snell true
            exit 0
            ;;
        -u|--uninstall|uninstall)
            uninstall_snell
            exit 0
            ;;
        -f|--force-uninstall|force-uninstall)
            uninstall_snell true
            exit 0
            ;;
        -U|--update|update)
            update_snell
            exit 0
            ;;
        -r|--restart|restart)
            systemctl restart snell && log_info "已重启" || log_error "重启失败"
            exit 0
            ;;
        --start|start)
            systemctl start snell && log_info "已启动" || log_error "启动失败"
            exit 0
            ;;
        --stop|stop)
            systemctl stop snell && log_info "已停止" || log_error "停止失败"
            exit 0
            ;;
        -s|--status|status)
            systemctl status snell
            exit 0
            ;;
        -v|--version|version)
            echo "easysnell ${SCRIPT_VERSION}"
            if [[ -f "${SNELL_DIR}/snell-server" ]]; then
                echo "snell-server $("${SNELL_DIR}/snell-server" -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")"
            else
                echo "snell-server 未安装"
            fi
            exit 0
            ;;
        -c|--config|config)
            show_config
            exit 0
            ;;
        -h|--help|help)
            echo "用法: bash easysnell.sh [选项]"
            echo ""
            echo "注意: 本脚本需要 root 权限运行"
            echo ""
            echo "选项:"
            echo "  -q, --quick           非交互式快速安装（随机参数）"
            echo "  -y, --yes             非交互式安装（效果同 --quick）"
            echo "  -u, --uninstall       卸载 Snell（带确认提示）"
            echo "  -f, --force-uninstall 强制卸载 Snell（跳过确认）"
            echo "  -U, --update          更新 Snell 二进制"
            echo "  -r, --restart         重启 Snell 服务"
            echo "  --start               启动 Snell 服务"
            echo "  --stop                停止 Snell 服务"
            echo "  -s, --status          查看 Snell 服务状态"
            echo "  -v, --version         显示版本信息"
            echo "  -c, --config          查看配置"
            echo "  -h, --help            显示帮助"
            echo ""
            echo "环境变量:"
            echo "  NO_COLOR=1            禁用颜色输出"
            echo "  EASYSNELL_NO_CLEAR=1  禁用菜单清屏"
            echo ""
            echo "不带参数则进入交互式菜单（需要 TTY）"
            exit 0
            ;;
    esac

    if [[ ! -t 0 ]]; then
        log_error "未检测到交互式终端，请使用快捷参数或非交互式模式"
        echo "示例: bash easysnell.sh --quick"
        exit 1
    fi

    while true; do
        show_menu
        case "${choice}" in
            1)
                install_snell
                ;;
            2)
                if [[ -f "${SNELL_DIR}/snell-server" ]]; then
                    uninstall_snell
                else
                    log_warn "Snell 尚未安装"
                fi
                ;;
            3)
                if [[ -f "${SNELL_DIR}/snell-server" ]]; then
                    if systemctl is-active --quiet snell 2>/dev/null; then
                        systemctl stop snell && log_info "已停止" || log_error "停止失败"
                    else
                        systemctl start snell && log_info "已启动" || log_error "启动失败"
                    fi
                else
                    log_warn "Snell 尚未安装"
                fi
                ;;
            4)
                update_snell
                ;;
            5)
                show_config
                ;;
            0)
                log_info "再见"
                exit 0
                ;;
            *)
                log_warn "无效的选项"
                ;;
        esac
        if [[ -t 0 ]]; then
            read -rp "按 Enter 继续..."
        fi
    done
}

main "$@"
