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
readonly APT_LOCK_WAIT_CYCLES=30  # 30 cycles × 2s = 60s max
readonly LIMIT_NOFILE=32768
readonly SERVICE_VERIFY_SLEEP=2
readonly JOURNAL_TAIL_LINES=20
readonly BACKUP_RETAIN_DAYS=30

# 回滚标记
ROLLBACK_REQUIRED=0
SNELL_BACKUP_DIR=""

# 全局清理状态
_CLEANUP_TMP_FILE=""
_CLEANUP_TMP_DIR=""

# 统一退出处理：根据退出码决定回滚或清理备份
_on_exit() {
    local exit_code=$?
    # 清理临时文件
    [[ -n "${_CLEANUP_TMP_FILE}" ]] && rm -f "${_CLEANUP_TMP_FILE}" 2>/dev/null || true
    [[ -n "${_CLEANUP_TMP_DIR}" ]] && rm -rf "${_CLEANUP_TMP_DIR}" 2>/dev/null || true
    # 根据退出状态决定回滚或清理备份
    if [[ "${ROLLBACK_REQUIRED}" -eq 1 ]]; then
        if [[ ${exit_code} -ne 0 ]]; then
            rollback
        else
            cleanup_backup
        fi
    fi
}

_on_signal() {
    exit 130
}

# 统一注册信号处理（安装/更新流程共用）
setup_traps() {
    trap '_on_exit' EXIT
    trap '_on_signal' INT TERM
}

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

# Logging helpers (use printf + "$@" to avoid injection and preserve arguments)
log_info()  { printf '%b[INFO]%b  %s\n' "$GREEN" "$RESET" "$@" >&2; }
log_warn()  { printf '%b[WARN]%b  %s\n' "$YELLOW" "$RESET" "$@" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$@" >&2; }
log_step()  { printf '%b[STEP]%b  %s\n' "$BLUE" "$RESET" "$@" >&2; }

# Service status helper
is_service_active() {
    timeout 10 systemctl is-active --quiet snell 2>/dev/null
}

#===============================================================================
# 系统检测
#===============================================================================
detect_os() {
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id=$(. /etc/os-release && echo "$ID")
        echo "${os_id}" | tr '[:upper:]' '[:lower:]'
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
    # 优先使用双栈 API（自动返回 IPv4 或 IPv6）
    ip=$(curl -fsSL -m "${CURL_TIMEOUT}" https://api64.ipify.org 2>/dev/null | tr -d '\n\r') || ip=""
    # IPv4 验证
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return
    fi
    # IPv6 验证
    if [[ -n "$ip" ]] && _is_valid_ip "$ip" && [[ "$ip" == *:* ]]; then
        echo "$ip"
        return
    fi
    # Fallback: 仅 IPv4
    ip=$(curl -fsSL -m "${CURL_TIMEOUT}" https://api.ipify.org 2>/dev/null | tr -d '\n\r') || ip=""
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip=""
    fi
    echo "$ip"
}

detect_country() {
    local ip=$1
    local country=""
    local tmp_result

    # 依次尝试多个 GeoIP API，使用第一个成功的
    tmp_result=$(mktemp) || {
        echo "UN"
        return
    }
    # 尝试 ipinfo.io
    (curl -fsSL -m "${CURL_TIMEOUT}" "https://ipinfo.io/${ip}/country" 2>/dev/null | tr -d '\n\r' | grep -oE '^[A-Z]{2}$') > "${tmp_result}" 2>/dev/null || true

    if [[ ! -s "${tmp_result}" ]]; then
        # 备用：ip-api.com (HTTPS)
        (curl -fsSL -m "${CURL_TIMEOUT}" "https://ip-api.com/line/${ip}/countryCode" 2>/dev/null | grep -oE '^[A-Z]{2}$') > "${tmp_result}" 2>/dev/null || true
    fi

    if [[ ! -s "${tmp_result}" ]]; then
        # 备用：ipapi.co
        (curl -fsSL -m "${CURL_TIMEOUT}" "https://ipapi.co/${ip}/country_code" 2>/dev/null | tr -d '\n\r' | grep -oE '^[A-Z]{2}$') > "${tmp_result}" 2>/dev/null || true
    fi

    country=$(cat "${tmp_result}" 2>/dev/null || true)
    rm -f "${tmp_result}"

    echo "${country:-UN}"
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
    if command -v fuser &>/dev/null; then
        has_fuser=1
    fi

    if [[ $has_fuser -eq 0 ]]; then
        log_warn "未检测到 fuser，跳过 apt 锁等待检测"
        return 0
    fi

    # 先检查锁文件是否存在
    local lock_files="/var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
    local any_lock_exists=0
    for lock in $lock_files; do
        if [[ -f "$lock" ]]; then
            any_lock_exists=1
            break
        fi
    done

    if [[ $any_lock_exists -eq 0 ]]; then
        return 0
    fi

    while fuser $lock_files >/dev/null 2>&1; do
        log_warn "等待其他 apt 进程释放... (${i})"
        sleep 2
        i=$((i + 1))
        if [[ $i -gt APT_LOCK_WAIT_CYCLES ]]; then
            log_error "apt 锁等待超时"
            exit 1
        fi
    done
}

# dnf/yum 锁等待
wait_for_dnf() {
    local i=0
    if ! command -v fuser &>/dev/null; then
        return 0
    fi
    local lock_files="/var/lib/dnf/rpmdb_lock.pid /var/run/yum.pid /var/lib/rpm/.rpm.lock"
    local any_lock_exists=0
    for lock in $lock_files; do
        if [[ -f "$lock" ]]; then
            any_lock_exists=1
            break
        fi
    done

    if [[ $any_lock_exists -eq 0 ]]; then
        return 0
    fi

    while fuser $lock_files >/dev/null 2>&1; do
        log_warn "等待其他 dnf 进程释放... (${i})"
        sleep 2
        i=$((i + 1))
        if [[ $i -gt APT_LOCK_WAIT_CYCLES ]]; then
            log_error "dnf/yum 锁等待超时"
            exit 1
        fi
    done
}

# pacman 锁等待
wait_for_pacman() {
    local i=0
    if ! command -v fuser &>/dev/null; then
        return 0
    fi
    if [[ -f /var/lib/pacman/db.lck ]]; then
        while fuser /var/lib/pacman/db.lck >/dev/null 2>&1; do
            log_warn "等待其他 pacman 进程释放... (${i})"
            sleep 2
            i=$((i + 1))
            if [[ $i -gt APT_LOCK_WAIT_CYCLES ]]; then
                log_error "pacman 锁等待超时"
                exit 1
            fi
        done
    fi
}

install_deps() {
    local os=$1
    log_step "安装必要依赖..."
    case "$os" in
        debian|ubuntu)
            wait_for_apt
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -q
            apt-get install -y -q wget curl unzip iptables ip6tables
            ;;
        centos|rhel|almalinux|rocky|fedora)
            wait_for_dnf
            if command -v dnf &>/dev/null; then
                dnf -y -q install wget curl unzip iptables-services
            else
                yum -y -q install wget curl unzip iptables-services
            fi
            ;;
        arch|manjaro)
            wait_for_pacman
            pacman -Sy --noconfirm --needed wget curl unzip iptables
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

    # 解析内核版本 (e.g. "5.10.0-21-amd64" -> major=5, minor=10)
    local kernel_version
    kernel_version=$(uname -r)
    local kernel_major kernel_minor
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    kernel_minor=$(echo "$kernel_version" | cut -d. -f2 | cut -d- -f1)

    # 版本比较：5.0+
    local supports_bbr=0
    if [[ "$kernel_major" -gt 5 ]] || \
       [[ "$kernel_major" -eq 5 && "$kernel_minor" -ge 0 ]]; then
        supports_bbr=1
    fi

    if [[ "$supports_bbr" -eq 0 ]]; then
        log_warn "内核版本 < 5.0，无法开启 BBR (当前: ${kernel_version})"
        return 0
    fi

    local bbr_enabled=0
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        bbr_enabled=1
    fi

    if [[ "$bbr_enabled" -eq 1 ]]; then
        log_info "BBR (IPv4) 已经处于开启状态"
    else
        if [[ ! -f /etc/sysctl.d/99-bbr.conf ]] || \
           ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.d/99-bbr.conf 2>/dev/null; then
            cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        fi
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            log_info "BBR (IPv4) 已开启"
        else
            log_warn "BBR 配置已写入 /etc/sysctl.d/99-bbr.conf，重启后生效"
        fi
    fi

    # 同时检查 IPv6 BBR
    if [[ -e /proc/sys/net/ipv6/tcp_congestion_control ]]; then
        if sysctl net.ipv6.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            log_info "BBR (IPv6) 已经处于开启状态"
        else
            # IPv6 BBR 配置
            if ! grep -q "net.ipv6.tcp_congestion_control" /etc/sysctl.d/99-bbr.conf 2>/dev/null; then
                printf '\nnet.ipv6.tcp_congestion_control=bbr\n' >> /etc/sysctl.d/99-bbr.conf
                sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
            fi
        fi
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

    # iptables: 只添加一次，用注释标记便于识别和清理
    if ! iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null; then
        iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null || true
    fi

    if ! ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null; then
        ip6tables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null || true
    fi
}

close_firewall_port() {
    local port=$1
    local proto=${2:-tcp}
    local had_rule=false

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status numbered 2>/dev/null | grep -qE "\[.*\]\s+${port}/${proto}\s+"; then
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 || true
            had_rule=true
        fi
    fi

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "${port}/${proto}"; then
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            had_rule=true
        fi
    fi

    if iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null; then
        iptables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null || true
        had_rule=true
    fi

    if ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null; then
        ip6tables -D INPUT -p "${proto}" --dport "${port}" -j ACCEPT -m comment --comment "EASYSNELL-${port}-${proto}" 2>/dev/null || true
        had_rule=true
    fi

    if [[ "${had_rule}" == "true" ]]; then
        log_info "防火墙已撤销 ${port}/${proto}"
    fi
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
        log_info "下载成功（官方源）"
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
    log_error "尝试的 URL:"
    log_error "  官方: ${url}"
    log_error "  备用: ${fallback_url}"
    return 1
}

#===============================================================================
# 二进制部署
#===============================================================================
deploy_binary() {
    local tmp_file=$1
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/easysnell.XXXXXX)
    chmod 700 "${tmp_dir}"

    if ! unzip -o "${tmp_file}" -d "${tmp_dir}" 2>/dev/null; then
        log_error "解压失败，文件可能已损坏"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    if [[ ! -f "${tmp_dir}/snell-server" ]]; then
        log_error "解压后未找到 snell-server 二进制文件"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    # 验证是有效的 ELF 可执行文件 (检查魔数 \x7fELF)
    local magic
    magic=$(head -c 4 "${tmp_dir}/snell-server" | od -An -tx1 | tr -d ' \n')
    if [[ "$magic" != "7f454c46" ]]; then
        log_error "下载的文件不是有效的 ELF 可执行文件 (magic: ${magic})"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    mkdir -p "${SNELL_DIR}"
    if ! mv "${tmp_dir}/snell-server" "${SNELL_DIR}/snell-server" 2>/dev/null; then
        log_error "部署 snell-server 二进制文件失败"
        rm -rf "${tmp_dir}"
        exit 1
    fi
    rm -rf "${tmp_dir}"
    if ! chmod +x "${SNELL_DIR}/snell-server" 2>/dev/null; then
        log_error "设置可执行权限失败"
        exit 1
    fi
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
    local dns=${7:-}

    mkdir -p "${CONF_DIR}"
    # 目录权限: 750 (owner=rwx, group=r-x, other=---)
    chmod 750 "${CONF_DIR}"

    {
        echo "[snell-server]"
        echo "listen = ::0:${port}"
        echo "psk = ${psk}"
        echo "ipv6 = ${ipv6}"
        if [[ -n "${dns}" ]]; then
            echo "dns = ${dns}"
        fi
        if [[ -n "${obfs}" ]]; then
            echo "obfs = ${obfs}"
            if [[ -n "${obfs_host}" ]]; then
                echo "obfs-host = ${obfs_host}"
            fi
        fi
        if [[ "${udp}" == "true" ]]; then
            echo "udp = true"
        fi
    } > "${CONF_DIR}/snell-server.conf" || {
        log_error "写入配置文件失败"
        exit 1
    }
}

create_systemd_service() {
    # Snell 只需要绑定特权端口，不需要 NET_ADMIN/NET_RAW
    # CAP_NET_BIND_SERVICE 从 systemd v229 开始支持 AmbientCapabilities
    # CapabilityBoundingSet 更广泛支持，因此只使用它

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
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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

    if [[ ! -f "${SERVICE_FILE}" ]]; then
        log_error "写入 systemd 服务文件失败"
        exit 1
    fi
}

#===============================================================================
# 备份与恢复
#===============================================================================
backup_config() {
    # 清理超过保留天数的旧备份
    find "${CONF_DIR}" -maxdepth 1 -name "*.bak.*" -mtime +${BACKUP_RETAIN_DAYS} -delete 2>/dev/null || true

    if [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        local conf_bak
        conf_bak="${CONF_DIR}/snell-server.conf.bak.$(date +%s).${RANDOM}"
        if cp "${CONF_DIR}/snell-server.conf" "${conf_bak}" 2>/dev/null; then
            chmod 600 "${conf_bak}"
            log_warn "检测到已有配置，已备份至 ${conf_bak}"
        fi
    fi
    if [[ -f "${CONF_DIR}/surge-config.txt" ]]; then
        local surge_bak
        surge_bak="${CONF_DIR}/surge-config.txt.bak.$(date +%s).${RANDOM}"
        if cp "${CONF_DIR}/surge-config.txt" "${surge_bak}" 2>/dev/null; then
            chmod 600 "${surge_bak}"
        fi
    fi
}

#===============================================================================
# 随机生成器 (纯 Bash + /dev/urandom)
#===============================================================================
random_port() {
    shuf -i "${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX}" -n 1 2>/dev/null || \
        od -An -N2 -tu2 /dev/urandom | tr -d ' ' | awk -v min="${RANDOM_PORT_MIN}" -v max="${RANDOM_PORT_MAX}" '{print min + ($1 % (max - min + 1))}'
}

random_psk() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${PSK_LENGTH}"
}

# 查找可用端口（自动模式专用）
find_available_port() {
    local retries=0
    local port
    port=$(random_port)
    while ! validate_port "$port"; do
        retries=$((retries + 1))
        if [[ $retries -gt 10 ]]; then
            log_error "无法找到可用端口，请手动指定或检查服务器环境"
            return 1
        fi
        port=$(random_port)
    done
    echo "$port"
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
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            log_error "TCP 端口 ${port} 已被占用"
            return 1
        fi
        if ss -ulnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
            log_error "UDP 端口 ${port} 已被占用"
            return 1
        fi
    fi
    return 0
}

validate_psk() {
    local psk=$1
    if [[ -z "$psk" ]]; then
        log_error "PSK 不能为空"
        return 1
    fi
    # 仅允许字母数字，与 random_psk 保持一致
    if [[ ! "$psk" =~ ^[A-Za-z0-9]+$ ]]; then
        log_error "PSK 包含非法字符，仅允许字母和数字"
        return 1
    fi
    return 0
}

validate_obfs_host() {
    local host=$1
    if [[ -n "$host" && ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        log_warn "非法的 obfs-host: ${host}，已忽略"
        return 1
    fi
    return 0
}

validate_dns() {
    local dns=$1
    if [[ -z "$dns" ]]; then
        return 0
    fi
    # 使用 read -ra 避免通配符展开
    local -a addrs
    local old_ifs="$IFS"
    IFS=', '
    read -ra addrs <<< "$dns"
    IFS="$old_ifs"
    local addr
    for addr in "${addrs[@]}"; do
        addr="${addr// /}"  # trim spaces
        if [[ -z "$addr" ]]; then
            continue
        fi
        if ! _is_valid_ip "$addr"; then
            log_error "非法的 DNS 地址: ${addr}"
            return 1
        fi
    done
    return 0
}

# IP 地址格式校验（IPv4 + IPv6）
_is_valid_ip() {
    local addr=$1
    # IPv4
    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    # IPv6: 必须包含冒号，仅含十六进制和冒号，长度合理
    if [[ "$addr" == *:* ]] && \
       [[ "$addr" =~ ^[0-9a-fA-F:]+$ ]] && \
       [[ ${#addr} -le 45 ]]; then
        return 0
    fi
    return 1
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
    log_error "未找到任何可用的 nologin shell"
    return 1
}

create_snell_user() {
    local os=$1
    local nologin_shell
    nologin_shell=$(find_nologin_shell) || {
        log_error "无法找到可用的 nologin shell"
        exit 1
    }

    if id "snell" &>/dev/null; then
        return 0
    fi

    if command -v useradd &>/dev/null; then
        if ! useradd -r -s "${nologin_shell}" -M snell 2>/dev/null; then
            log_error "创建 snell 用户失败"
            exit 1
        fi
    elif command -v adduser &>/dev/null; then
        case "$os" in
            alpine)
                if ! adduser -S -s "${nologin_shell}" -H -D snell 2>/dev/null; then
                    log_error "创建 snell 用户失败 (adduser)"
                    exit 1
                fi
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
    local dns

    # 注册统一信号处理
    setup_traps
    # 创建预安装备份（失败时跳过回滚保护）
    if ! create_pre_install_backup; then
        log_warn "备份创建失败，将跳过回滚保护"
    fi

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
        port=$(find_available_port) || exit 1
        psk=$(random_psk)
        ipv6="true"
        udp="true"
        obfs=""
        obfs_host=""
        dns="1.1.1.1, 8.8.8.8"
    else
        echo ""
        read -rp "请输入监听端口 [随机 ${RANDOM_PORT_MIN}-${RANDOM_PORT_MAX}]: " port_input
        port_input="${port_input// /}"
        port=${port_input:-$(random_port)}
        if ! validate_port "$port"; then
            exit 1
        fi

        read -rp "请输入 PSK [随机生成]: " psk_input
        psk_input="${psk_input// /}"
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

        read -rp "请输入 DNS 服务器地址 [1.1.1.1, 8.8.8.8]: " dns_input
        dns=${dns_input:-1.1.1.1, 8.8.8.8}
        if ! validate_dns "$dns"; then
            exit 1
        fi
    fi

    if ! install_deps "${os}"; then
        log_error "依赖安装失败，请检查网络或手动安装后重试"
        log_error "需要: wget curl unzip iptables"
        exit 1
    fi

    local tmp_file
    tmp_file=$(mktemp)
    _CLEANUP_TMP_FILE="${tmp_file}"

    download_snell "${arch}" "${tmp_file}"
    deploy_binary "${tmp_file}"

    rm -f "${tmp_file}"
    _CLEANUP_TMP_FILE=""

    create_snell_user "${os}"

    backup_config
    generate_config "${port}" "${psk}" "${ipv6}" "${obfs}" "${obfs_host}" "${udp}" "${dns}"
    if ! chown snell:snell "${CONF_DIR}" "${CONF_DIR}/snell-server.conf" 2>/dev/null; then
        log_warn "设置配置所有者失败"
    fi
    if ! chmod 640 "${CONF_DIR}/snell-server.conf" 2>/dev/null; then
        log_warn "设置配置权限失败"
    fi

    create_systemd_service
    systemctl daemon-reload
    systemctl enable snell
    if ! systemctl start snell; then
        log_error "Snell 服务启动失败，查看日志:"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    sleep "${SERVICE_VERIFY_SLEEP}"
    if is_service_active; then
        log_info "Snell 服务运行正常"
    else
        log_error "Snell 服务未运行"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    # 先配置系统级优化，再开放防火墙
    enable_bbr

    open_firewall_port "${port}" "tcp"
    if [[ "${udp}" == "true" ]]; then
        open_firewall_port "${port}" "udp"
    fi

    # IPv6 地址在 Surge 配置中需要方括号包裹
    local ip_display="${ip}"
    if [[ "$ip" == *:* ]]; then
        ip_display="[${ip}]"
    fi

    cat > "${CONF_DIR}/surge-config.txt" << EOF
# Snell Server Config
# 生成时间: $(date '+%Y-%m-%dT%H:%M:%S%z')
# 服务器IP: ${ip}
# 注意: 请妥善保管 PSK，不要在公共日志中记录

${country} = snell, ${ip_display}, ${port}, psk = ${psk}, version = 5, reuse = true${obfs:+, obfs = $obfs}${obfs_host:+, obfs-host = $obfs_host}
EOF
    chmod 640 "${CONF_DIR}/surge-config.txt" 2>/dev/null || true
    chown snell:snell "${CONF_DIR}/surge-config.txt" 2>/dev/null || true

    echo ""
    printf '%b\n' "${CYAN}============================================${RESET}"
    printf '%b\n' "${GREEN}       Snell 部署成功!${RESET}"
    printf '%b\n' "${CYAN}============================================${RESET}"
    printf '  服务器IP: %s\n' "${ip}"
    printf '  端口:     %s\n' "${port}"
    # PSK 用掩码显示，只显示前4位和后4位
    local psk_masked="${psk:0:4}...${psk: -4}"
    printf '  PSK:      %s\n' "${psk_masked}"
    printf '  IPv6:     %s\n' "${ipv6}"
    printf '  UDP:      %s\n' "${udp}"
    if [[ -n "$obfs" ]]; then
        printf '  OBFS:     %s\n' "${obfs}"
    fi
    if [[ -n "$obfs_host" ]]; then
        printf '  OBFS-HOST: %s\n' "${obfs_host}"
    fi
    printf '%b\n' "${CYAN}--------------------------------------------${RESET}"
    printf '%b\n' "${YELLOW}Surge 配置行:${RESET}"
    grep -v '^#' "${CONF_DIR}/surge-config.txt"
    printf '%b\n' "${CYAN}============================================${RESET}"
    printf '配置文件路径: %s\n' "${CONF_DIR}/snell-server.conf"
    printf 'Surge 配置路径: %s\n' "${CONF_DIR}/surge-config.txt"
    printf '管理命令: systemctl {start|stop|restart|status} snell\n'
    printf '查看日志: journalctl -u snell -f\n'
    printf '%b\n' "${YELLOW}注意: 请妥善保管 PSK，完整 PSK 已在配置文件中。${RESET}"
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

    # 注册统一信号处理 + 回滚保护
    setup_traps
    if ! create_pre_install_backup; then
        log_warn "备份创建失败，将跳过回滚保护"
    fi

    log_step "正在更新 Snell..."

    local arch
    arch=$(detect_arch)

    local tmp_file
    tmp_file=$(mktemp)
    _CLEANUP_TMP_FILE="${tmp_file}"

    if ! download_snell "${arch}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        _CLEANUP_TMP_FILE=""
        exit 1
    fi

    if systemctl stop snell 2>/dev/null; then
        log_info "服务已停止"
    else
        log_warn "服务停止失败或未运行，继续更新..."
    fi
    deploy_binary "${tmp_file}"

    rm -f "${tmp_file}"
    _CLEANUP_TMP_FILE=""

    if ! systemctl restart snell; then
        log_error "更新后服务启动失败"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    sleep "${SERVICE_VERIFY_SLEEP}"
    if is_service_active; then
        log_info "服务运行正常"
    else
        log_error "服务未正常启动"
        journalctl -u snell --no-pager -n "${JOURNAL_TAIL_LINES}" || true
        exit 1
    fi

    # 清理旧的二进制备份（超过 BACKUP_RETAIN_DAYS 天）
    find "${SNELL_DIR}" -maxdepth 1 -name 'snell-server.bak.*' -mtime +${BACKUP_RETAIN_DAYS} -delete 2>/dev/null || true

    log_info "更新完成"
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
        if cp -a "${CONF_DIR}" "${bak_dir}" 2>/dev/null; then
            chmod 700 "${bak_dir}"
            find "${bak_dir}" -type f -exec chmod 600 {} \; 2>/dev/null || true
            log_info "配置已备份至 ${bak_dir}"
        else
            log_warn "备份配置失败"
        fi
    fi

    if [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        local old_port
        local old_udp
        old_port=$(grep -E '^listen' "${CONF_DIR}/snell-server.conf" 2>/dev/null | grep -oE '[0-9]+$' || echo "")
        old_udp=$(grep -E '^udp' "${CONF_DIR}/snell-server.conf" 2>/dev/null | grep -oE 'true|false' || echo "false")
        if [[ -n "$old_port" ]]; then
            close_firewall_port "$old_port" "tcp"
            if [[ "$old_udp" == "true" ]]; then
                close_firewall_port "$old_port" "udp"
            fi
        fi
    fi

    systemctl stop snell 2>/dev/null || true
    systemctl disable snell 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "${SNELL_DIR}/snell-server"
    find "${SNELL_DIR}" -maxdepth 1 -name 'snell-server.bak.*' -delete 2>/dev/null || true
    rm -rf "${CONF_DIR}"
    # 保留 BBR 配置（系统级优化，与 Snell 无关）
    if id "snell" &>/dev/null; then
        userdel snell 2>/dev/null || log_warn "删除 snell 用户失败（可能仍有进程使用）"
    fi
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
    if [[ -t 1 && -z "${EASYSNELL_NO_CLEAR:-}" ]]; then
        clear || true
    fi
    local installed="未安装"
    local running="未启动"
    local ver="—"
    if [[ -f "${SNELL_DIR}/snell-server" ]]; then
        installed="已安装"
        ver=$("${SNELL_DIR}/snell-server" -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        if is_service_active; then
            running="运行中"
        else
            running="已停止"
        fi
    fi

    echo ""
    printf '%b\n' "${GREEN}======== EasySnell 管理工具 v${SCRIPT_VERSION} ========${RESET}"
    printf '  安装状态: %s\n' "${installed}"
    printf '  运行状态: %s\n' "${running}"
    printf '  当前版本: %s\n' "${ver}"
    echo ""
    echo "  1. 安装 Snell 服务"
    echo "  2. 卸载 Snell 服务"
    if [[ -f "${SNELL_DIR}/snell-server" ]]; then
        if is_service_active; then
            echo "  3. 停止 Snell 服务"
        else
            echo "  3. 启动 Snell 服务"
        fi
    fi
    echo "  4. 更新 Snell 服务"
    echo "  5. 查看 Snell 配置"
    echo "  0. 退出"
    printf '%b\n' "${GREEN}=============================================${RESET}"
    read -rp "请选择 [0-5]: " choice
}

#===============================================================================
# 快捷参数支持
#===============================================================================
quick_install() {
    install_snell true
}

# 回滚函数
rollback() {
    if [[ "$ROLLBACK_REQUIRED" -eq 0 ]]; then
        return 0
    fi
    log_warn "执行回滚操作..."

    if [[ -n "$SNELL_BACKUP_DIR" && -d "$SNELL_BACKUP_DIR" ]]; then
        # 恢复配置文件
        if [[ -f "${SNELL_BACKUP_DIR}/snell-server.conf" ]]; then
            cp -p "${SNELL_BACKUP_DIR}/snell-server.conf" "${CONF_DIR}/" 2>/dev/null || true
        fi
        if [[ -f "${SNELL_BACKUP_DIR}/snell-server" ]]; then
            mkdir -p "${SNELL_DIR}"
            cp -p "${SNELL_BACKUP_DIR}/snell-server" "${SNELL_DIR}/" 2>/dev/null || true
        fi
        if [[ -f "${SNELL_BACKUP_DIR}/snell.service" ]]; then
            cp -p "${SNELL_BACKUP_DIR}/snell.service" "${SERVICE_FILE}"
        fi
        # 恢复服务状态
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart snell 2>/dev/null || log_warn "服务重启失败，请手动处理"
        log_info "配置和服务已回滚"
    fi

    # 清理备份目录
    if [[ -n "$SNELL_BACKUP_DIR" && -d "$SNELL_BACKUP_DIR" ]]; then
        rm -rf "${SNELL_BACKUP_DIR}"
    fi
    ROLLBACK_REQUIRED=0
}

# 清理备份（安装成功后）
cleanup_backup() {
    if [[ -n "$SNELL_BACKUP_DIR" && -d "$SNELL_BACKUP_DIR" ]]; then
        rm -rf "${SNELL_BACKUP_DIR}"
    fi
    ROLLBACK_REQUIRED=0
}

# 注册信号处理回滚（已由 setup_traps 统一管理）
# 注册成功退出清理（已由 _on_exit 统一管理）

# 创建安装前备份（用于回滚）
create_pre_install_backup() {
    if [[ -f "${SNELL_DIR}/snell-server" ]] || [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
        SNELL_BACKUP_DIR=$(mktemp -d /tmp/easysnell-backup.XXXXXX)
        if [[ -z "$SNELL_BACKUP_DIR" || ! -d "$SNELL_BACKUP_DIR" ]]; then
            log_error "无法创建备份目录，请检查 /tmp 空间"
            return 1
        fi
        chmod 700 "${SNELL_BACKUP_DIR}"
        if [[ -f "${SNELL_DIR}/snell-server" ]]; then
            cp -p "${SNELL_DIR}/snell-server" "${SNELL_BACKUP_DIR}/"
        fi
        if [[ -f "${CONF_DIR}/snell-server.conf" ]]; then
            cp -p "${CONF_DIR}/snell-server.conf" "${SNELL_BACKUP_DIR}/"
        fi
        if [[ -f "${SERVICE_FILE}" ]]; then
            cp -p "${SERVICE_FILE}" "${SNELL_BACKUP_DIR}/"
        fi
        ROLLBACK_REQUIRED=1
    fi
}

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
                    if is_service_active; then
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
