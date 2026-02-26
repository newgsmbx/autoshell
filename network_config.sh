#!/bin/bash

# ══════════════════════════════════════════════════════════
#  网络静态 IP 配置工具  |  支持: Debian / Ubuntu / Armbian
# ══════════════════════════════════════════════════════════

# ── 颜色定义 ──────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── 输出函数 ──────────────────────────────────────────────
info()    { echo -e "  ${CYAN}·${NC}  $*"; }
success() { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $*"; }
error()   { echo -e "  ${RED}✘${NC}  $*"; }
label()   { echo -e "\n${BOLD}${BLUE}$*${NC}"; echo -e "${DIM}  $(printf '%.0s─' {1..40})${NC}"; }
kv()      { printf "  ${DIM}%-14s${NC}  ${BOLD}%s${NC}\n" "$1" "$2"; }

# ── Ctrl+C 处理 ───────────────────────────────────────────
trap 'echo -e "\n"; error "操作已取消，程序退出。"; echo ""; exit 1' SIGINT

# ══════════════════════════════════════════════════════════
# 检查 root 权限
# ══════════════════════════════════════════════════════════
if [ "$EUID" -ne 0 ]; then
    error "请以 root 权限运行此脚本（使用 sudo）。"
    exit 1
fi

# ══════════════════════════════════════════════════════════
# 检测操作系统
# ══════════════════════════════════════════════════════════
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS=$ID
        OS_NAME=$NAME
    else
        error "无法识别操作系统，程序退出。"
        exit 1
    fi

    case "$OS" in
        ubuntu)
            if command -v netplan &>/dev/null; then
                CONFIG_MODE="netplan"
            else
                CONFIG_MODE="interfaces"
            fi
            ;;
        debian)
            CONFIG_MODE="interfaces"
            ;;
        armbian)
            if systemctl is-active --quiet NetworkManager && command -v nmcli &>/dev/null; then
                CONFIG_MODE="nmcli"
            else
                CONFIG_MODE="interfaces"
            fi
            ;;
        *)
            error "不支持的系统: ${OS_NAME}，仅支持 Ubuntu、Debian 和 Armbian。"
            exit 1
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
# 获取网卡名称
# ══════════════════════════════════════════════════════════
get_interface() {
    INTERFACE=$(ip -br link show | awk '{print $1}' | grep -v "lo" | head -n 1)
    if [ -z "$INTERFACE" ]; then
        error "未找到网络接口，程序退出。"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════
# 显示标题与系统信息
# ══════════════════════════════════════════════════════════
show_header() {
    echo ""
    echo -e "  ${BOLD}${BLUE}网络静态 IP 配置工具${NC}  ${DIM}Ubuntu / Debian / Armbian${NC}"
    echo ""
}

show_system_info() {
    CURRENT_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}')
    CURRENT_GATEWAY=$(ip route show default | awk '{print $3}')
    CURRENT_DNS=$(grep 'nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')

    label "系统环境"
    kv "操作系统"   "${OS_NAME}"
    kv "配置模式"   "${CONFIG_MODE}"
    kv "网络接口"   "${INTERFACE}"

    label "当前网络"
    kv "IP 地址"    "${CURRENT_IP:-未获取到}"
    kv "网关"       "${CURRENT_GATEWAY:-未获取到}"
    kv "DNS"        "${CURRENT_DNS:-未获取到}"
}

# ══════════════════════════════════════════════════════════
# IP 地址格式验证
# ══════════════════════════════════════════════════════════
validate_ip() {
    local ip=$1
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if ! [[ $ip =~ $ip_regex ]]; then
        return 1
    fi
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    return 0
}

# ══════════════════════════════════════════════════════════
# 前缀长度转子网掩码
# ══════════════════════════════════════════════════════════
prefix_to_netmask() {
    local prefix=$1
    local mask=""
    local full_octets=$((prefix / 8))
    local partial=$((prefix % 8))
    for ((i=0; i<4; i++)); do
        if [ "$i" -lt "$full_octets" ]; then
            mask+="255"
        elif [ "$i" -eq "$full_octets" ]; then
            if [ "$partial" -eq 0 ]; then
                mask+="0"
            else
                mask+=$((256 - (1 << (8 - partial))))
            fi
        else
            mask+="0"
        fi
        [ "$i" -lt 3 ] && mask+="."
    done
    echo "$mask"
}

# ══════════════════════════════════════════════════════════
# Ubuntu — Netplan 配置
# ══════════════════════════════════════════════════════════
apply_netplan() {
    if systemctl is-active --quiet NetworkManager; then
        RENDERER="NetworkManager"
    else
        RENDERER="networkd"
    fi

    NETPLAN_DIR="/etc/netplan"
    BACKUP_DIR="${NETPLAN_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    NETPLAN_FILE="${NETPLAN_DIR}/01-static-network.yaml"

    mkdir -p "$BACKUP_DIR"
    cp "${NETPLAN_DIR}"/*.yaml "$BACKUP_DIR"/ 2>/dev/null
    info "旧配置已备份  ${DIM}${BACKUP_DIR}${NC}"

    find "$NETPLAN_DIR" -maxdepth 1 -name "*.yaml" -delete

    DNS_YAML=""
    for dns in $DNS_SERVERS; do
        DNS_YAML+="          - ${dns}"$'\n'
    done
    DNS_YAML=$(printf '%s' "$DNS_YAML" | sed '$ s/\n$//')

    cat > "$NETPLAN_FILE" <<EOL
network:
  version: 2
  renderer: $RENDERER
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $IP_ADDRESS/$PREFIX
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses:
$DNS_YAML
EOL

    chmod 600 "$NETPLAN_FILE"
    info "配置文件已生成  ${DIM}${NETPLAN_FILE}${NC}"
    info "渲染器  ${BOLD}${RENDERER}${NC}"

    if NETPLAN_ERR=$(netplan generate 2>&1); then
        netplan apply
        success "Netplan 配置已应用"
    else
        error "Netplan 语法校验失败，正在恢复备份..."
        echo -e "${DIM}${NETPLAN_ERR}${NC}"
        cp "${BACKUP_DIR}"/*.yaml "${NETPLAN_DIR}"/ 2>/dev/null
        netplan apply
        warn "已恢复旧配置"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════
# Armbian — NetworkManager (nmcli) 配置
# ══════════════════════════════════════════════════════════
apply_nmcli() {
    CON_NAME="static-${INTERFACE}"
    DNS_NM=$(echo "$DNS_SERVERS" | tr ' ' ',')

    if nmcli connection show "$CON_NAME" &>/dev/null; then
        nmcli connection delete "$CON_NAME" &>/dev/null
        info "旧连接已删除  ${DIM}${CON_NAME}${NC}"
    fi

    if nmcli connection add \
        type ethernet \
        con-name "$CON_NAME" \
        ifname "$INTERFACE" \
        ipv4.method manual \
        ipv4.addresses "${IP_ADDRESS}/${PREFIX}" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$DNS_NM" \
        ipv6.method ignore; then

        nmcli connection up "$CON_NAME"
        success "NetworkManager 配置已应用"
    else
        error "nmcli 配置失败，请检查输入参数。"
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════
# Debian / 旧版 Armbian — interfaces 配置
# ══════════════════════════════════════════════════════════
apply_interfaces() {
    INTERFACES_FILE="/etc/network/interfaces"
    RESOLV_CONF_FILE="/etc/resolv.conf"
    BACKUP_FILE="/etc/network/interfaces.bak_$(date +%Y%m%d_%H%M%S)"

    cp "$INTERFACES_FILE" "$BACKUP_FILE" 2>/dev/null
    info "旧配置已备份  ${DIM}${BACKUP_FILE}${NC}"

    NETMASK=$(prefix_to_netmask "$PREFIX")

    cat > "$INTERFACES_FILE" <<EOL
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDRESS
    netmask $NETMASK
    gateway $GATEWAY
EOL

    # shellcheck disable=SC2188
    > "$RESOLV_CONF_FILE"
    for dns in $DNS_SERVERS; do
        echo "nameserver ${dns}" >> "$RESOLV_CONF_FILE"
    done
    info "DNS 已写入  ${DIM}${RESOLV_CONF_FILE}${NC}"

    if systemctl restart networking 2>/dev/null; then
        success "networking 服务重启成功"
    else
        ifdown "$INTERFACE" 2>/dev/null
        ifup "$INTERFACE" 2>/dev/null
        if ip addr show "$INTERFACE" | grep -q "$IP_ADDRESS"; then
            success "网络接口重启成功"
        else
            error "网络重启失败，请手动执行: ifdown ${INTERFACE} && ifup ${INTERFACE}"
            exit 1
        fi
    fi
}

# ══════════════════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════════════════
detect_os
get_interface
show_header
show_system_info

# ── 输入配置 ──────────────────────────────────────────────
label "新的网络配置"
echo ""

while true; do
    read -rp "  $(echo -e "${CYAN}IP 地址${NC}       : ") " IP_ADDRESS
    read -rp "  $(echo -e "${CYAN}前缀长度${NC} [24] : ") " PREFIX
    PREFIX=${PREFIX:-24}
    read -rp "  $(echo -e "${CYAN}网关地址${NC}       : ") " GATEWAY
    read -rp "  $(echo -e "${CYAN}DNS 服务器${NC}     : ") " DNS_SERVERS
    echo ""

    ERR=0
    if ! validate_ip "$IP_ADDRESS"; then
        error "IP 地址格式不正确: ${IP_ADDRESS}"
        ERR=1
    fi
    if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || [ "$PREFIX" -lt 1 ] || [ "$PREFIX" -gt 32 ]; then
        error "前缀长度必须为 1～32 的整数: ${PREFIX}"
        ERR=1
    fi
    if ! validate_ip "$GATEWAY"; then
        error "网关地址格式不正确: ${GATEWAY}"
        ERR=1
    fi
    if [ -z "$DNS_SERVERS" ]; then
        error "DNS 服务器不能为空"
        ERR=1
    fi
    if [ "$ERR" -eq 1 ]; then
        warn "请重新输入配置信息。"
        echo ""
        continue
    fi

    echo -e "  ${DIM}$(printf '%.0s─' {1..40})${NC}"
    kv "网络接口"   "${INTERFACE}"
    kv "IP 地址"    "${IP_ADDRESS}/${PREFIX}"
    kv "网关"       "${GATEWAY}"
    kv "DNS"        "${DNS_SERVERS}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..40})${NC}"
    echo ""
    read -rp "  $(echo -e "${YELLOW}确认应用以上配置?${NC} (y/n): ") " confirm_choice
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        break
    else
        warn "已取消，请重新输入。"
        echo ""
    fi
done

# ── 应用配置 ──────────────────────────────────────────────
label "正在应用配置"

case "$CONFIG_MODE" in
    netplan)    apply_netplan ;;
    nmcli)      apply_nmcli ;;
    interfaces) apply_interfaces ;;
esac

# ── 完成 ──────────────────────────────────────────────────
NEW_IP=$(ip addr show "$INTERFACE" | grep 'inet ' | awk '{print $2}')
echo ""
echo -e "  ${BOLD}${GREEN}配置完成${NC}"
echo -e "  ${DIM}$(printf '%.0s─' {1..40})${NC}"
kv "接口"  "${INTERFACE}"
kv "IP"    "${NEW_IP:-${IP_ADDRESS}/${PREFIX}}"
echo ""
