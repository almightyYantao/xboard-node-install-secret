#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# XBoard Node 一键安装 & 管理脚本
# 适配: CentOS Stream 10 (兼容 CentOS 8/9, RHEL 系)
# 版本: v1.3.0
#
# 包含: xboard-node + lb-node 快捷命令 + TrafficBoard 监控 (可选)
#
# 用法: curl -fsSL <url> | bash
# ══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_VERSION="v1.4.0"
INSTALL_DIR="/opt/xboard-node"
CONFIG_FILE="$INSTALL_DIR/config/config.yml"
LB_NODE_BIN="/usr/local/bin/lb-node"
REPORTER_SCRIPT="/opt/xboard-node/node-reporter.sh"
REPORTER_SERVICE="tb-reporter"
REPORTER_URL="https://raw.githubusercontent.com/almightyYantao/xboard-node-install-secret/main/node-reporter.sh"

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 工具函数 ─────────────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD} $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# curl | bash 兼容: 从终端读输入
ask() {
    local prompt="$1" varname="$2"
    read -rp "$(echo -e "$prompt")" "$varname" < /dev/tty
}

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ══════════════════════════════════════════════════════════════════════════════
#  检测环境
# ══════════════════════════════════════════════════════════════════════════════
DOCKER_INSTALLED=false
NODE_INSTALLED=false
NODE_RUNNING=false
LBNODE_INSTALLED=false
REPORTER_INSTALLED=false
REPORTER_RUNNING=false

command -v docker &>/dev/null && DOCKER_INSTALLED=true
[ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/compose.yml" ] && NODE_INSTALLED=true
if $NODE_INSTALLED && $DOCKER_INSTALLED; then
    cd "$INSTALL_DIR"
    docker compose ps --status running 2>/dev/null | grep -q "xboard" && NODE_RUNNING=true
    cd - &>/dev/null
fi
[ -f "$LB_NODE_BIN" ] && LBNODE_INSTALLED=true
[ -f "/etc/systemd/system/${REPORTER_SERVICE}.service" ] && REPORTER_INSTALLED=true
if $REPORTER_INSTALLED && systemctl is-active "$REPORTER_SERVICE" &>/dev/null; then
    REPORTER_RUNNING=true
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Banner & 菜单
# ══════════════════════════════════════════════════════════════════════════════
show_banner() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  XBoard Node 安装 & 管理脚本  ${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Docker:          $(if $DOCKER_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    echo -e "  XBoard Node:     $(if $NODE_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    if $NODE_INSTALLED; then
        echo -e "  容器状态:        $(if $NODE_RUNNING; then echo -e "${GREEN}运行中${NC}"; else echo -e "${YELLOW}已停止${NC}"; fi)"
    fi
    echo -e "  lb-node 命令:    $(if $LBNODE_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    echo -e "  TrafficBoard 监控: $(if $REPORTER_INSTALLED; then if $REPORTER_RUNNING; then echo -e "${GREEN}运行中${NC}"; else echo -e "${YELLOW}已安装(停止)${NC}"; fi; else echo -e "${RED}未安装${NC}"; fi)"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  面板地址:        $(grep -E '^\s+url:' "$CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  节点 ID:         $(grep -E '^\s+- node_id:' "$CONFIG_FILE" 2>/dev/null | awk '{print $3}' | tr '\n' ' ')"
    fi
    echo ""
}

run_menu() {
    show_banner
    echo -e "${BOLD}请选择操作:${NC}"
    echo ""
    if ! $NODE_INSTALLED; then
        echo "  1) 全新安装 (Docker + Git + XBoard Node + lb-node)"
    else
        echo "  1) 重新安装 (停止当前服务，走完整流程)"
    fi
    echo "  2) 仅更新脚本 (更新 lb-node，不动 Docker 和配置)"
    if $NODE_INSTALLED; then
        echo "  3) 重新配置 (修改面板/Token/节点ID)"
        echo "  4) 更新镜像 (拉最新 xboard-node 镜像)"
    fi
    echo "  5) 安装/管理 TrafficBoard 监控"
    echo "  6) TCP 网络优化 (BBR + FQ + 缓冲调优)"
    echo "  0) 退出"
    echo ""
    ask "${BOLD}请选择: ${NC}" MENU_CHOICE

    case "$MENU_CHOICE" in
        1) MODE="full_install" ;;
        2) MODE="update_script" ;;
        3) $NODE_INSTALLED || error "未安装，请先全新安装"; MODE="reconfigure" ;;
        4) $NODE_INSTALLED || error "未安装，请先全新安装"; MODE="update_image" ;;
        5) MODE="reporter_manage" ;;
        6) MODE="tcp_optimize" ;;
        0) exit 0 ;;
        *) error "无效选择" ;;
    esac
}

if ! $NODE_INSTALLED && ! $LBNODE_INSTALLED && ! $REPORTER_INSTALLED; then
    MODE="full_install"
    show_banner
    info "检测到全新环境，开始完整安装..."
else
    run_menu
fi

# ══════════════════════════════════════════════════════════════════════════════
#  核心函数
# ══════════════════════════════════════════════════════════════════════════════

detect_system() {
    step "系统检测"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"; OS_VERSION="$VERSION_ID"
        info "操作系统: $OS_NAME $OS_VERSION"
    else
        error "无法识别操作系统"
    fi
    if command -v dnf &>/dev/null; then PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then PKG_MGR="yum"
    else error "仅支持 RHEL/CentOS 系"; fi
    info "包管理器: $PKG_MGR"
}

detect_v2bx() {
    step "检测已有节点后端"
    V2BX_FOUND=false; V2BX_TYPE=""

    if systemctl list-unit-files 2>/dev/null | grep -qi "v2bx\|V2bX"; then
        V2BX_FOUND=true; V2BX_TYPE="systemd"
        V2BX_SERVICE=$(systemctl list-unit-files 2>/dev/null | grep -i "v2bx" | awk '{print $1}' | head -1)
        systemctl is-active "$V2BX_SERVICE" &>/dev/null && V2BX_STATUS="运行中" || V2BX_STATUS="已停止"
        info "发现 V2bX (systemd): $V2BX_SERVICE [$V2BX_STATUS]"
    fi

    if command -v docker &>/dev/null; then
        V2BX_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i "v2bx" | head -1)
        if [[ -n "$V2BX_CONTAINER" ]]; then
            V2BX_FOUND=true; V2BX_TYPE="docker"
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "v2bx" && V2BX_STATUS="运行中" || V2BX_STATUS="已停止"
            info "发现 V2bX (Docker): $V2BX_CONTAINER [$V2BX_STATUS]"
        fi
    fi

    if ! $V2BX_FOUND; then
        V2BX_BIN=$(command -v V2bX 2>/dev/null || command -v v2bx 2>/dev/null || true)
        [[ -z "$V2BX_BIN" ]] && for p in /usr/local/bin/V2bX /usr/local/bin/v2bx /opt/V2bX/V2bX /usr/bin/V2bX; do
            [ -f "$p" ] && V2BX_BIN="$p" && break
        done
        [[ -n "$V2BX_BIN" ]] && V2BX_FOUND=true && V2BX_TYPE="binary" && info "发现 V2bX 二进制: $V2BX_BIN"
    fi

    if $V2BX_FOUND; then
        echo ""
        warn "检测到 V2bX，可能产生端口冲突"
        echo ""
        echo "  1) 卸载 V2bX   2) 仅停止   3) 跳过   0) 退出"
        echo ""
        ask "${BOLD}请选择 [0/1/2/3]: ${NC}" V2BX_ACTION
        case "$V2BX_ACTION" in
            1)
                info "卸载 V2bX..."
                [[ "$V2BX_TYPE" == "systemd" ]] && {
                    systemctl stop "$V2BX_SERVICE" 2>/dev/null || true
                    systemctl disable "$V2BX_SERVICE" 2>/dev/null || true
                    rm -f "/etc/systemd/system/$V2BX_SERVICE" 2>/dev/null || true
                    systemctl daemon-reload 2>/dev/null || true
                }
                [[ "$V2BX_TYPE" == "docker" ]] && {
                    docker stop "$V2BX_CONTAINER" 2>/dev/null || true
                    docker rm "$V2BX_CONTAINER" 2>/dev/null || true
                }
                for p in /usr/local/bin/V2bX /usr/local/bin/v2bx /opt/V2bX /usr/bin/V2bX; do
                    [ -e "$p" ] && rm -rf "$p" && info "已删除: $p"
                done
                # 注意: 保留 V2bX 配置目录，reporter 可能还要读
                info "V2bX 卸载完成"
                ;;
            2)
                [[ "$V2BX_TYPE" == "systemd" ]] && systemctl stop "$V2BX_SERVICE" 2>/dev/null && systemctl disable "$V2BX_SERVICE" 2>/dev/null || true
                [[ "$V2BX_TYPE" == "docker" ]] && docker stop "$V2BX_CONTAINER" 2>/dev/null || true
                info "V2bX 已停止"
                ;;
            3) warn "跳过" ;;
            0) exit 0 ;;
            *) error "无效选择" ;;
        esac
    else
        info "未检测到 V2bX"
    fi
}

install_dependencies() {
    step "安装依赖 (Docker & Git)"
    for repo in epel epel-cisco-openh264 epel-next; do
        if [ -f "/etc/yum.repos.d/${repo}.repo" ] || $PKG_MGR repolist --enabled 2>/dev/null | grep -qi "$repo"; then
            $PKG_MGR config-manager --set-disabled "$repo" 2>/dev/null || true
        fi
    done
    DNF_OPTS="--disablerepo=epel --disablerepo=epel-cisco-openh264 --disablerepo=epel-next"

    command -v git &>/dev/null && info "Git: $(git --version)" || {
        $PKG_MGR install -y $DNF_OPTS git || error "Git 安装失败"
        info "Git 安装完成"
    }

    if command -v docker &>/dev/null; then
        info "Docker: $(docker --version)"
    else
        info "正在安装 Docker..."
        $PKG_MGR remove -y $DNF_OPTS docker docker-client docker-client-latest \
            docker-common docker-latest docker-engine podman buildah 2>/dev/null || true
        $PKG_MGR install -y $DNF_OPTS dnf-plugins-core || true
        [ ! -f /etc/yum.repos.d/docker-ce.repo ] && \
            $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        MAJOR_VER="${OS_VERSION%%.*}"
        [[ "$MAJOR_VER" -ge 10 ]] && {
            warn "CentOS 10+ 适配: 使用 CentOS 9 仓库"
            sed -i 's/$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
        }
        $PKG_MGR install -y $DNF_OPTS docker-ce docker-ce-cli containerd.io docker-compose-plugin || error "Docker 安装失败"
        info "Docker 安装完成"
    fi

    systemctl is-active docker &>/dev/null || { systemctl start docker; systemctl enable docker; }
    docker compose version &>/dev/null || error "docker compose 不可用"
}

clone_repo() {
    step "克隆 xboard-node"
    if [ -d "$INSTALL_DIR" ]; then
        warn "目录已存在: $INSTALL_DIR"
        ask "${YELLOW}删除并重新克隆？[y/N]: ${NC}" RECLONE
        if [[ "$RECLONE" =~ ^[Yy]$ ]]; then
            [ -f "$INSTALL_DIR/compose.yml" ] && { cd "$INSTALL_DIR"; docker compose down 2>/dev/null || true; cd /; }
            rm -rf "$INSTALL_DIR"
        fi
    fi
    [ ! -d "$INSTALL_DIR" ] && {
        git clone -b compose --depth 1 https://github.com/cedar2025/xboard-node.git "$INSTALL_DIR" || error "克隆失败"
        info "克隆完成"
    }
}

interactive_config() {
    step "配置 XBoard Node"
    echo ""
    while true; do
        ask "${BOLD}面板地址 (Panel URL): ${NC}" PANEL_URL
        [[ -n "$PANEL_URL" ]] && { PANEL_URL="${PANEL_URL%/}"; break; }
        warn "不能为空"
    done
    while true; do
        ask "${BOLD}通信密钥 (Token): ${NC}" PANEL_TOKEN
        [[ -n "$PANEL_TOKEN" ]] && break
        warn "不能为空"
    done

    echo ""; echo -e "${BOLD}内核类型:${NC}  1) singbox(默认)  2) xray"
    ask "${BOLD}选择 [1/2]: ${NC}" KERNEL_CHOICE
    [[ "$KERNEL_CHOICE" == "2" ]] && KERNEL_TYPE="xray" || KERNEL_TYPE="singbox"

    echo ""; echo -e "${BOLD}证书模式:${NC}  1) self(默认)  2) http  3) none"
    ask "${BOLD}选择 [1/2/3]: ${NC}" CERT_CHOICE
    case "$CERT_CHOICE" in 2) CERT_MODE="http";; 3) CERT_MODE="none";; *) CERT_MODE="self";; esac

    echo ""; echo -e "${BOLD}节点 ID (回车结束):${NC}"
    NODE_IDS=(); NODE_COUNT=1
    while true; do
        ask "  节点 ${NODE_COUNT} ID (留空结束): " NODE_INPUT
        [[ -z "$NODE_INPUT" ]] && { [[ ${#NODE_IDS[@]} -eq 0 ]] && warn "至少一个" && continue; break; }
        ! [[ "$NODE_INPUT" =~ ^[0-9]+$ ]] && warn "必须为数字" && continue
        NODE_IDS+=("$NODE_INPUT"); info "已添加: $NODE_INPUT"; ((NODE_COUNT++))
    done
    info "节点: ${NODE_IDS[*]}"
}

generate_config() {
    mkdir -p "$INSTALL_DIR/config"
    [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)" && info "旧配置已备份"

    cat > "$CONFIG_FILE" <<EOF
# XBoard Node Configuration — $(date '+%Y-%m-%d %H:%M:%S')
panel:
  url: "${PANEL_URL}"
  token: "${PANEL_TOKEN}"
  node_id: ${NODE_IDS[0]}

nodes:
EOF
    for nid in "${NODE_IDS[@]}"; do echo "  - node_id: ${nid}" >> "$CONFIG_FILE"; done
    cat >> "$CONFIG_FILE" <<EOF

kernel:
  type: "${KERNEL_TYPE}"
  config_dir: "/etc/xboard-node"
  log_level: "warn"

cert:
  cert_mode: "${CERT_MODE}"

log:
  level: "info"
  output: "stdout"
EOF
    info "配置已生成"
    echo -e "${CYAN}─── 配置预览 ──────────────────────────────────────────────────────────────${NC}"
    cat "$CONFIG_FILE"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
}

start_service() {
    echo ""
    ask "${BOLD}确认启动？[Y/n]: ${NC}" CONFIRM
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && { info "跳过启动"; return; }
    cd "$INSTALL_DIR"; docker compose pull; docker compose up -d
    info "服务已启动"
}

# ══════════════════════════════════════════════════════════════════════════════
#  TrafficBoard 监控管理
# ══════════════════════════════════════════════════════════════════════════════

manage_reporter() {
    step "TrafficBoard 监控管理"
    echo ""

    # 检测已有的旧版 reporter (可能指向 V2bX 配置)
    OLD_REPORTER=""
    if [ -f "/etc/systemd/system/${REPORTER_SERVICE}.service" ]; then
        OLD_EXEC=$(grep "^ExecStart=" "/etc/systemd/system/${REPORTER_SERVICE}.service" 2>/dev/null | head -1)
        if echo "$OLD_EXEC" | grep -q "V2bX\|v2bx\|config\.json"; then
            OLD_REPORTER="v2bx"
            warn "检测到旧版 reporter (指向 V2bX 配置)"
        elif echo "$OLD_EXEC" | grep -q "xboard-node"; then
            OLD_REPORTER="xboard"
            info "当前 reporter 已指向 xboard-node 配置"
        else
            OLD_REPORTER="unknown"
            info "检测到已有 reporter 服务"
        fi
    fi

    if $REPORTER_INSTALLED; then
        echo -e "  当前状态: $(if $REPORTER_RUNNING; then echo -e "${GREEN}运行中${NC}"; else echo -e "${YELLOW}已停止${NC}"; fi)"
        if [[ "$OLD_REPORTER" == "v2bx" ]]; then
            echo -e "  ${YELLOW}⚠ 配置源: V2bX (旧版，建议迁移到 xboard-node)${NC}"
        fi
        echo ""
        echo "  1) 重新安装/迁移 (使用 xboard-node 配置)"
        echo "  2) 重启"
        echo "  3) 查看日志"
        echo "  4) 停止"
        echo "  5) 卸载"
        echo "  0) 返回"
    else
        echo "  TrafficBoard 监控未安装"
        echo ""
        echo "  1) 安装并启用"
        echo "  0) 返回"
    fi
    echo ""
    ask "${BOLD}请选择: ${NC}" R_CHOICE

    case "$R_CHOICE" in
        1)
            # 安装/迁移 reporter
            if ! [ -f "$CONFIG_FILE" ]; then
                warn "xboard-node 配置文件不存在，reporter 将尝试自动查找配置"
            fi

            # 下载最新 reporter 脚本
            info "下载 node-reporter.sh..."
            curl -fsSL "$REPORTER_URL" -o "$REPORTER_SCRIPT" || {
                warn "下载失败，尝试使用本地版本"
                if [ ! -f "$REPORTER_SCRIPT" ]; then
                    error "reporter 脚本不存在且无法下载"
                fi
            }
            chmod +x "$REPORTER_SCRIPT"
            info "reporter 脚本已更新: $REPORTER_SCRIPT"

            # 确保 python3 存在
            if ! command -v python3 &>/dev/null; then
                info "安装 python3..."
                DNF_OPTS="--disablerepo=epel --disablerepo=epel-cisco-openh264 --disablerepo=epel-next"
                if command -v dnf &>/dev/null; then
                    dnf install -y $DNF_OPTS python3 || error "python3 安装失败"
                elif command -v yum &>/dev/null; then
                    yum install -y $DNF_OPTS python3 || error "python3 安装失败"
                fi
            fi

            # 停止旧的
            if $REPORTER_INSTALLED; then
                systemctl stop "$REPORTER_SERVICE" 2>/dev/null || true
                info "已停止旧 reporter"
            fi

            # 用 enable 子命令安装 systemd 服务
            bash "$REPORTER_SCRIPT" enable "$CONFIG_FILE"
            info "TrafficBoard 监控已启用"
            echo ""
            echo "  查看日志: journalctl -u $REPORTER_SERVICE -f"
            echo "  或使用:   lb-node reporter logs"
            ;;
        2)
            systemctl restart "$REPORTER_SERVICE" 2>/dev/null || error "重启失败"
            info "已重启"
            ;;
        3)
            echo "按 Ctrl+C 退出日志..."
            journalctl -u "$REPORTER_SERVICE" -f --no-pager < /dev/tty
            ;;
        4)
            systemctl stop "$REPORTER_SERVICE" 2>/dev/null || true
            info "已停止"
            ;;
        5)
            bash "$REPORTER_SCRIPT" disable 2>/dev/null || {
                systemctl disable --now "$REPORTER_SERVICE" 2>/dev/null || true
                rm -f "/etc/systemd/system/${REPORTER_SERVICE}.service"
                systemctl daemon-reload
            }
            info "已卸载"
            ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
#  TCP 网络优化 (BBR + FQ + 缓冲调优)
#  注: 仅使用内核自带 BBR v1，不安装 XanMod；不修改 DNS。
# ══════════════════════════════════════════════════════════════════════════════

TCP_SYSCTL_CONF="/etc/sysctl.d/99-xboard-tcp.conf"
TCP_IPV6_CONF="/etc/sysctl.d/99-xboard-disable-ipv6.conf"
TCP_BBR_MODULE="/etc/modules-load.d/99-xboard-bbr.conf"
TCP_LIMITS_CONF="/etc/systemd/system.conf.d/99-xboard-limits.conf"
TCP_BACKUP_DIR="/var/backups/xboard-tcp"

manage_tcp() {
    step "TCP 网络优化"

    local cur_cc cur_qdisc cur_v6
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    cur_v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")

    echo ""
    echo -e "${BOLD}当前内核网络状态:${NC}"
    echo -e "  拥塞控制:  ${cur_cc}"
    echo -e "  默认队列:  ${cur_qdisc}"
    echo -e "  IPv6 禁用: $([ "$cur_v6" = "1" ] && echo "是" || echo "否")"

    local applied=false
    [ -f "$TCP_SYSCTL_CONF" ] && applied=true

    echo ""
    if $applied; then
        echo -e "  ${GREEN}● 已应用 XBoard TCP 优化${NC}"
        echo ""
        echo "  1) 重新优化 (重新选档并应用)"
        echo "  2) 查看当前配置"
        echo "  3) 还原 (移除优化，恢复冲突项)"
        echo "  0) 返回"
    else
        echo -e "  ${YELLOW}● 尚未应用 TCP 优化${NC}"
        echo ""
        echo "  1) 应用 TCP 优化"
        echo "  0) 返回"
    fi
    echo ""
    ask "${BOLD}请选择: ${NC}" T_CHOICE

    case "$T_CHOICE" in
        1) tcp_apply ;;
        2) $applied && { echo ""; cat "$TCP_SYSCTL_CONF"; echo ""; } ;;
        3) $applied && tcp_revert ;;
        0) return ;;
        *) warn "无效选择" ;;
    esac
}

detect_link_speed_mbps() {
    # 输出 Mbps 整数；失败返回非 0
    local iface speed
    iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$iface" ] && return 1
    LINK_IFACE="$iface"

    if command -v ethtool >/dev/null 2>&1; then
        speed=$(ethtool "$iface" 2>/dev/null | awk -F: '/Speed:/ {gsub(/[^0-9]/,"",$2); print $2}')
        if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
            LINK_SOURCE="ethtool"
            echo "$speed"; return 0
        fi
    fi

    if [ -r "/sys/class/net/$iface/speed" ]; then
        speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
            LINK_SOURCE="sysfs"
            echo "$speed"; return 0
        fi
    fi

    return 1
}

mbps_to_buffer_mb() {
    local mbps="$1"
    if   [ "$mbps" -le 100 ];  then echo 16
    elif [ "$mbps" -le 500 ];  then echo 32
    elif [ "$mbps" -le 1000 ]; then echo 64
    elif [ "$mbps" -le 2500 ]; then echo 128
    else echo 256
    fi
}

run_speedtest_mbps() {
    # 输出上传带宽 Mbps 到 stdout；所有提示走 stderr 避免污染 $(…) 捕获
    local upload_mbps speedtest_bin
    speedtest_bin="$(command -v speedtest-cli || true)"
    if [ -z "$speedtest_bin" ]; then
        info "安装 speedtest-cli (单文件 Python 脚本)..." >&2
        if curl -fsSL "https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py" \
            -o /usr/local/bin/speedtest-cli 2>/dev/null && chmod +x /usr/local/bin/speedtest-cli; then
            speedtest_bin="/usr/local/bin/speedtest-cli"
        else
            warn "下载 speedtest-cli 失败" >&2
            return 1
        fi
    fi
    command -v python3 >/dev/null 2>&1 || { warn "speedtest-cli 需要 python3" >&2; return 1; }
    info "跑 Ookla speedtest (约 30-60 秒)..." >&2
    upload_mbps=$(python3 "$speedtest_bin" --simple --no-download 2>/dev/null | awk '/Upload:/ {print int($2)}')
    if [[ "$upload_mbps" =~ ^[0-9]+$ ]] && [ "$upload_mbps" -gt 0 ]; then
        echo "$upload_mbps"; return 0
    fi
    warn "speedtest 未返回有效结果" >&2
    return 1
}

tcp_apply() {
    # 检查 BBR 内核支持
    if ! modprobe tcp_bbr 2>/dev/null && ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        error "当前内核不支持 BBR，请升级内核 (Linux ≥ 4.9)"
    fi

    # 内存检测
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)
    info "系统内存: ${mem_mb} MB"

    # 自动检测链路速度
    local link_mbps recommended_mb detect_note=""
    LINK_IFACE=""; LINK_SOURCE=""
    link_mbps=$(detect_link_speed_mbps) || link_mbps=""
    if [ -n "$link_mbps" ]; then
        recommended_mb=$(mbps_to_buffer_mb "$link_mbps")
        info "链路检测: ${LINK_IFACE} = ${link_mbps} Mbps (来源: ${LINK_SOURCE}) → 推荐 ${recommended_mb}MB"
    else
        recommended_mb=64
        detect_note="(未检测到链路速度，按 1Gbps 默认)"
        warn "无法检测链路速度 ${detect_note}，推荐 ${recommended_mb}MB"
    fi

    # 缓冲档位选择
    echo ""
    echo -e "${BOLD}请选择 TCP 缓冲档位:${NC}"
    echo -e "  1) 使用推荐值 ${recommended_mb}MB ${GREEN}⭐${NC} (默认)"
    echo "  2) 16MB    (≤100Mbps / 小内存保守)"
    echo "  3) 32MB    (100-500Mbps)"
    echo "  4) 64MB    (500Mbps-1Gbps)"
    echo "  5) 128MB   (1-2.5Gbps)"
    echo "  6) 256MB   (≥2.5Gbps)"
    echo "  7) 跑 Ookla speedtest 实测后再决定 (~30-60s)"
    echo "  8) 手动输入 MB (4-512)"
    echo ""
    echo "  提示: 缓冲不是越大越好，过大会增加内存压力和 bufferbloat。"
    echo ""
    ask "${BOLD}选择 [1]: ${NC}" BUF_CHOICE

    local buffer_mb
    case "${BUF_CHOICE:-1}" in
        1) buffer_mb=$recommended_mb ;;
        2) buffer_mb=16 ;;
        3) buffer_mb=32 ;;
        4) buffer_mb=64 ;;
        5) buffer_mb=128 ;;
        6) buffer_mb=256 ;;
        7)
            local st_mbps
            if st_mbps=$(run_speedtest_mbps); then
                local st_recommended
                st_recommended=$(mbps_to_buffer_mb "$st_mbps")
                info "speedtest 上传: ${st_mbps} Mbps → 推荐 ${st_recommended}MB"
                ask "${BOLD}使用此推荐值？[Y/n]: ${NC}" USE_ST
                if [[ ! "$USE_ST" =~ ^[Nn]$ ]]; then
                    buffer_mb=$st_recommended
                else
                    buffer_mb=$recommended_mb
                fi
            else
                warn "speedtest 失败，回退到 ethtool 推荐 ${recommended_mb}MB"
                buffer_mb=$recommended_mb
            fi
            ;;
        8)
            local manual=""
            while true; do
                ask "${BOLD}请输入缓冲大小 MB (4-512): ${NC}" manual
                if [[ "$manual" =~ ^[0-9]+$ ]] && [ "$manual" -ge 4 ] && [ "$manual" -le 512 ]; then
                    buffer_mb=$manual; break
                fi
                warn "请输入 4-512 之间的整数"
            done
            ;;
        *) buffer_mb=$recommended_mb ;;
    esac

    # 内存上限保护
    local cap=256 reason="bandwidth-tier"
    if   [ "$mem_mb" -lt 1024 ]; then cap=16;  reason="<1GB RAM cap"
    elif [ "$mem_mb" -lt 2048 ]; then cap=32;  reason="<2GB RAM cap"
    elif [ "$mem_mb" -lt 4096 ]; then cap=128; reason="<4GB RAM cap"
    fi
    if [ "$buffer_mb" -gt "$cap" ]; then
        warn "内存限制: ${buffer_mb}MB → ${cap}MB ($reason)"
        buffer_mb=$cap
    fi
    local buffer_bytes=$((buffer_mb * 1024 * 1024))
    info "TCP 缓冲: ${buffer_mb}MB"

    # IPv6 选择
    local ipv6_disable=""
    ask "${BOLD}永久禁用 IPv6？(纯 IPv4 节点建议禁用) [y/N]: ${NC}" ipv6_disable

    # 备份 + 清理冲突
    info "清理冲突的 sysctl 配置..."
    mkdir -p "$TCP_BACKUP_DIR"
    local ts; ts=$(date +%Y%m%d%H%M%S)
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf "$TCP_BACKUP_DIR/sysctl.conf.bak.$ts"
        sed -i -E '/^net\.core\.(rmem_max|wmem_max)/s/^/# xboard-tcp disabled: /' /etc/sysctl.conf 2>/dev/null || true
        sed -i -E '/^net\.ipv4\.tcp_(rmem|wmem|congestion_control)/s/^/# xboard-tcp disabled: /' /etc/sysctl.conf 2>/dev/null || true
    fi
    find /etc/sysctl.d -maxdepth 1 -type f \
        ! -name '99-xboard-tcp.conf' ! -name '99-xboard-disable-ipv6.conf' 2>/dev/null | while read -r conf; do
        if grep -qE '^(net\.core\.(rmem_max|wmem_max)|net\.ipv4\.tcp_(rmem|wmem|congestion_control))' "$conf" 2>/dev/null; then
            cp "$conf" "$TCP_BACKUP_DIR/$(basename "$conf").bak.$ts"
            sed -i -E '/^net\.core\.(rmem_max|wmem_max)/s/^/# xboard-tcp disabled: /;/^net\.ipv4\.tcp_(rmem|wmem|congestion_control)/s/^/# xboard-tcp disabled: /' "$conf" 2>/dev/null || true
        fi
    done

    # BBR 模块持久化
    cat > "$TCP_BBR_MODULE" <<'EOF'
tcp_bbr
EOF

    # vm 调优 (小内存机器用更保守的值)
    local vm_swappiness=10 vm_dirty_ratio=15 vm_min_free_kbytes=65536
    if [ "$mem_mb" -lt 2048 ]; then
        vm_swappiness=20
        vm_min_free_kbytes=32768
    fi

    # 写 sysctl 配置
    cat > "$TCP_SYSCTL_CONF" <<EOF
# XBoard Node TCP 优化 — $(date '+%Y-%m-%d %H:%M:%S')
# 内存: ${mem_mb}MB | 缓冲: ${buffer_mb}MB | 策略: ${reason}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_abort_on_overflow = 0
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.rmem_max = ${buffer_bytes}
net.core.wmem_max = ${buffer_bytes}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 ${buffer_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${buffer_bytes}
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = ${vm_swappiness}
vm.dirty_ratio = ${vm_dirty_ratio}
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
vm.min_free_kbytes = ${vm_min_free_kbytes}
vm.vfs_cache_pressure = 50
EOF

    info "应用 sysctl 参数..."
    if ! sysctl -p "$TCP_SYSCTL_CONF" >/dev/null 2>&1; then
        warn "部分 sysctl 参数应用失败，已保留可用项"
    fi

    # FQ qdisc 应用到物理网卡
    info "应用 FQ 队列..."
    local fq_ok=0 fq_total=0 dev
    for dev in $(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)'); do
        fq_total=$((fq_total + 1))
        tc qdisc replace dev "$dev" root fq >/dev/null 2>&1 || true
        tc qdisc show dev "$dev" 2>/dev/null | grep -q '^qdisc fq ' && fq_ok=$((fq_ok + 1))
    done
    info "FQ 队列: ${fq_ok}/${fq_total} 个网卡已应用"

    # 文件句柄上限
    if ! grep -q 'XBoard Node file descriptor limits' /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'

# XBoard Node file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi
    mkdir -p /etc/systemd/system.conf.d
    cat > "$TCP_LIMITS_CONF" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
    systemctl daemon-reexec >/dev/null 2>&1 || true

    # IPv6
    if [[ "$ipv6_disable" =~ ^[Yy]$ ]]; then
        cat > "$TCP_IPV6_CONF" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl -p "$TCP_IPV6_CONF" >/dev/null 2>&1 || true
        info "已禁用 IPv6"
    else
        rm -f "$TCP_IPV6_CONF"
    fi

    echo ""
    echo -e "${GREEN}✓ TCP 优化已应用${NC}"
    echo -e "  拥塞控制:  $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  默认队列:  $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo -e "  TCP 缓冲:  ${buffer_mb}MB"
    echo -e "  文件句柄:  1048576"
    echo ""
    info "配置文件: $TCP_SYSCTL_CONF"
    info "备份目录: $TCP_BACKUP_DIR"
    warn "建议重启 xboard-node 容器使新缓冲生效: lb-node restart"
}

tcp_revert() {
    info "移除 TCP 优化配置..."
    rm -f "$TCP_SYSCTL_CONF" "$TCP_IPV6_CONF" "$TCP_BBR_MODULE" "$TCP_LIMITS_CONF"
    sed -i '/# XBoard Node file descriptor limits/,/^root hard nofile/d' /etc/security/limits.conf 2>/dev/null || true

    # 恢复被注释掉的冲突项
    sed -i 's/^# xboard-tcp disabled: //' /etc/sysctl.conf 2>/dev/null || true
    find /etc/sysctl.d -maxdepth 1 -type f 2>/dev/null | while read -r conf; do
        sed -i 's/^# xboard-tcp disabled: //' "$conf" 2>/dev/null || true
    done

    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reexec >/dev/null 2>&1 || true
    info "已移除（重启后完全生效）"
}

# ══════════════════════════════════════════════════════════════════════════════
#  安装 lb-node
# ══════════════════════════════════════════════════════════════════════════════

install_lbnode() {
    step "安装 lb-node 快捷命令"

    cat > "$LB_NODE_BIN" <<'LBEOF'
#!/bin/bash
# lb-node — XBoard Node 快捷管理工具

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/xboard-node"
CONFIG_FILE="$INSTALL_DIR/config/config.yml"
REPORTER_SERVICE="tb-reporter"
REPORTER_SCRIPT="$INSTALL_DIR/node-reporter.sh"

check_install() { [ ! -d "$INSTALL_DIR" ] && echo -e "${RED}[ERROR]${NC} 未安装${NC}" && exit 1; }

cmd_status() {
    check_install
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  XBoard Node 状态${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}[容器]${NC}"
    cd "$INSTALL_DIR"; docker compose ps 2>/dev/null || echo -e "  ${RED}未运行${NC}"
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${BOLD}[配置]${NC}"
        echo -e "  面板:    $(grep -E '^\s+url:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  节点:    $(grep -E '^\s+- node_id:' "$CONFIG_FILE" | awk '{print $3}' | tr '\n' ' ')"
        echo -e "  内核:    $(grep -E '^\s+type:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  证书:    $(grep -E '^\s+cert_mode:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo ""
    fi
    echo -e "${BOLD}[资源]${NC}"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}   内存: {{.MemUsage}}" \
        $(docker compose ps -q 2>/dev/null) 2>/dev/null || echo "  无法获取"
    echo ""
    echo -e "${BOLD}[监控]${NC}"
    if systemctl is-active "$REPORTER_SERVICE" &>/dev/null; then
        echo -e "  TrafficBoard: ${GREEN}运行中${NC}"
    elif [ -f "/etc/systemd/system/${REPORTER_SERVICE}.service" ]; then
        echo -e "  TrafficBoard: ${YELLOW}已安装(停止)${NC}"
    else
        echo -e "  TrafficBoard: ${RED}未安装${NC}"
    fi
    echo ""
}

cmd_logs()    { check_install; cd "$INSTALL_DIR"; docker compose logs -f "$@"; }
cmd_start()   { check_install; cd "$INSTALL_DIR"; docker compose up -d; docker compose ps; }
cmd_stop()    { check_install; cd "$INSTALL_DIR"; docker compose down; }
cmd_restart() { check_install; cd "$INSTALL_DIR"; docker compose restart; docker compose ps; }
cmd_update()  { check_install; cd "$INSTALL_DIR"; docker compose pull; docker compose up -d; docker compose ps; }
cmd_reset()   { check_install; cd "$INSTALL_DIR"; docker compose down -v; docker compose up -d; }

cmd_config() {
    check_install; [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}配置不存在${NC}" && exit 1
    case "${1:-edit}" in
        --show|-s) cat "$CONFIG_FILE" ;;
        *)
            EDITOR_CMD="${EDITOR:-$(command -v vim || command -v vi || command -v nano)}"
            [[ -z "$EDITOR_CMD" ]] && echo "未找到编辑器" && exit 1
            "$EDITOR_CMD" "$CONFIG_FILE"
            read -rp "$(echo -e "${YELLOW}重启生效？[Y/n]: ${NC}")" R
            [[ ! "$R" =~ ^[Nn]$ ]] && { cd "$INSTALL_DIR"; docker compose restart; echo -e "${GREEN}已重启${NC}"; }
            ;;
    esac
}

cmd_reporter() {
    case "${1:-status}" in
        logs|log)   journalctl -u "$REPORTER_SERVICE" -f --no-pager ;;
        restart|rs) systemctl restart "$REPORTER_SERVICE"; echo "已重启" ;;
        stop)       systemctl stop "$REPORTER_SERVICE"; echo "已停止" ;;
        start)      systemctl start "$REPORTER_SERVICE"; echo "已启动" ;;
        status|st)
            if systemctl is-active "$REPORTER_SERVICE" &>/dev/null; then
                echo -e "TrafficBoard: ${GREEN}运行中${NC}"
                systemctl status "$REPORTER_SERVICE" --no-pager -l 2>/dev/null | head -8
            else
                echo -e "TrafficBoard: ${RED}未运行${NC}"
            fi
            ;;
        *) echo "用法: lb-node reporter {status|logs|restart|stop|start}" ;;
    esac
}

cmd_tcp() {
    case "${1:-check}" in
        check|status|st)
            local cc qdisc bbr_loaded fq_count fq_total rmem_max wmem_max nofile fastopen
            cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
            qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
            bbr_loaded=$(lsmod 2>/dev/null | grep -c '^tcp_bbr')
            rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
            wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
            fastopen=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)
            nofile=$(ulimit -n 2>/dev/null || echo "?")
            fq_count=0; fq_total=0
            for d in $(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap)'); do
                fq_total=$((fq_total + 1))
                tc qdisc show dev "$d" 2>/dev/null | grep -q '^qdisc fq ' && fq_count=$((fq_count + 1))
            done

            chk() { [ "$1" = "$2" ] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"; }
            chk_ge() { [ "$1" -ge "$2" ] 2>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"; }

            echo ""
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  TCP 优化状态检查${NC}"
            echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  $(chk "$cc" bbr)         拥塞控制:    ${cc} ${cc:+(期望 bbr)}"
            echo -e "  $(chk "$qdisc" fq)         默认队列:    ${qdisc} (期望 fq)"
            echo -e "  $(chk_ge "$bbr_loaded" 1)         BBR 模块:    $([ "$bbr_loaded" -ge 1 ] && echo "已加载" || echo "未加载")"
            echo -e "  $(chk_ge "$fq_count" 1)         FQ 网卡:     ${fq_count}/${fq_total} 个物理网卡已应用"
            echo -e "  $(chk_ge "$rmem_max" 16777216)         rmem_max:    $((rmem_max/1024/1024))MB"
            echo -e "  $(chk_ge "$wmem_max" 16777216)         wmem_max:    $((wmem_max/1024/1024))MB"
            echo -e "  $(chk "$fastopen" 3)         TCP Fastopen: ${fastopen} (期望 3)"
            echo -e "             文件句柄上限: ${nofile}"
            echo ""

            local conf="/etc/sysctl.d/99-xboard-tcp.conf"
            if [ -f "$conf" ]; then
                echo -e "${BOLD}[配置文件]${NC} $conf"
                grep -E "^# (内存|Bandwidth)" "$conf" 2>/dev/null | head -2 | sed 's/^/  /'
            else
                echo -e "${YELLOW}● 未应用 XBoard TCP 优化配置${NC}"
                echo -e "  运行: ${CYAN}bash <(curl -fsSL <脚本URL>)${NC} → 选择 6"
            fi
            echo ""
            ;;
        bench)
            command -v iperf3 >/dev/null 2>&1 || { echo -e "${YELLOW}未安装 iperf3${NC}，安装中..."; (command -v dnf >/dev/null && dnf install -y iperf3) || (command -v yum >/dev/null && yum install -y iperf3) || { echo "安装失败"; exit 1; }; }
            echo -e "${BOLD}启动 iperf3 服务端 (端口 5201)${NC}"
            echo "客户端测试命令:"
            echo "  iperf3 -c $(curl -s -4 ifconfig.me 2>/dev/null || echo "<本机IP>") -t 30 -P 4"
            echo "  iperf3 -c $(curl -s -4 ifconfig.me 2>/dev/null || echo "<本机IP>") -t 30 -R   # 反向"
            echo ""
            echo "Ctrl+C 退出"
            iperf3 -s
            ;;
        *) echo "用法: lb-node tcp {check|bench}" ;;
    esac
}

cmd_uninstall() {
    check_install
    echo -e "${RED}⚠  即将卸载 XBoard Node${NC}"
    read -rp "输入 YES 确认: " C; [[ "$C" != "YES" ]] && exit 0
    # 停止 reporter
    systemctl disable --now "$REPORTER_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${REPORTER_SERVICE}.service"
    systemctl daemon-reload 2>/dev/null || true
    # 停止容器
    cd "$INSTALL_DIR"; docker compose down -v 2>/dev/null || true
    rm -rf "$INSTALL_DIR" /usr/local/bin/lb-node
    echo -e "${GREEN}已卸载${NC}"
}

cmd_help() {
    echo ""
    echo -e "${BOLD}lb-node${NC} — XBoard Node 管理工具"
    echo ""
    echo -e "${BOLD}命令:${NC}"
    echo -e "  ${GREEN}status${NC}              状态总览"
    echo -e "  ${GREEN}logs${NC} [args]         容器日志 (支持 -n 100, --since 30m)"
    echo -e "  ${GREEN}config${NC}              编辑配置 (保存后重启)"
    echo -e "  ${GREEN}config --show${NC}       查看配置"
    echo -e "  ${GREEN}start${NC}               启动"
    echo -e "  ${GREEN}stop${NC}                停止"
    echo -e "  ${GREEN}restart${NC}             重启"
    echo -e "  ${GREEN}update${NC}              拉新镜像并重启"
    echo -e "  ${GREEN}reset${NC}               重建容器(清数据卷)"
    echo -e "  ${GREEN}reporter${NC} {cmd}      TrafficBoard 监控管理"
    echo "                     status / logs / restart / stop / start"
    echo -e "  ${GREEN}tcp${NC} {cmd}           TCP 优化检查 / 性能测试"
    echo "                     check (默认) / bench (启动 iperf3)"
    echo -e "  ${GREEN}uninstall${NC}           卸载"
    echo ""
}

case "${1:-help}" in
    status|st|s)           cmd_status              ;;
    logs|log|l)            shift; cmd_logs "$@"     ;;
    config|conf|cfg|c)     shift; cmd_config "$@"   ;;
    start|up)              cmd_start               ;;
    stop|down)             cmd_stop                ;;
    restart|rs)            cmd_restart             ;;
    update|upgrade|pull)   cmd_update              ;;
    reset)                 cmd_reset               ;;
    reporter|tb|monitor)   shift; cmd_reporter "$@" ;;
    tcp|tcp-check|tc)      shift; cmd_tcp "$@"      ;;
    uninstall|remove|rm)   cmd_uninstall           ;;
    help|-h|--help)        cmd_help                ;;
    *) echo -e "${RED}未知: $1${NC}"; cmd_help; exit 1 ;;
esac
LBEOF

    chmod +x "$LB_NODE_BIN"
    info "lb-node 已安装"
}

# ══════════════════════════════════════════════════════════════════════════════
#  完成信息
# ══════════════════════════════════════════════════════════════════════════════

show_done() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ 操作完成！${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    [ -f "$CONFIG_FILE" ] && {
        echo -e "  面板:  ${BOLD}$(grep -E '^\s+url:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')${NC}"
        echo -e "  节点:  ${BOLD}$(grep -E '^\s+- node_id:' "$CONFIG_FILE" | awk '{print $3}' | tr '\n' ' ')${NC}"
        echo ""
    }
    echo -e "  ${BOLD}快捷命令:${NC}"
    echo "  lb-node status          状态总览"
    echo "  lb-node logs            容器日志"
    echo "  lb-node config          编辑配置"
    echo "  lb-node config -s       查看配置"
    echo "  lb-node start/stop/restart"
    echo "  lb-node update          更新镜像"
    echo "  lb-node reporter logs   监控日志"
    echo "  lb-node reporter restart"
    echo "  lb-node uninstall       卸载"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  执行
# ══════════════════════════════════════════════════════════════════════════════

case "$MODE" in
    full_install)
        detect_system
        detect_v2bx
        install_dependencies
        clone_repo
        interactive_config
        generate_config
        start_service
        install_lbnode
        # 询问是否安装监控
        echo ""
        ask "${BOLD}是否安装 TrafficBoard 监控？[y/N]: ${NC}" INSTALL_REPORTER
        if [[ "$INSTALL_REPORTER" =~ ^[Yy]$ ]]; then
            manage_reporter
        fi
        show_done
        ;;
    update_script)
        install_lbnode
        show_done
        ;;
    reconfigure)
        interactive_config
        generate_config
        ask "${BOLD}重启服务？[Y/n]: ${NC}" DO_RESTART
        [[ ! "$DO_RESTART" =~ ^[Nn]$ ]] && { cd "$INSTALL_DIR"; docker compose restart; info "已重启"; }
        # 如果 reporter 在跑，也需要重启让它读新配置
        if systemctl is-active "$REPORTER_SERVICE" &>/dev/null; then
            systemctl restart "$REPORTER_SERVICE"
            info "TrafficBoard 监控已同步重启"
        fi
        install_lbnode
        show_done
        ;;
    update_image)
        step "更新镜像"
        cd "$INSTALL_DIR"; docker compose pull; docker compose up -d
        info "更新完成"
        install_lbnode
        show_done
        ;;
    reporter_manage)
        manage_reporter
        install_lbnode
        ;;
    tcp_optimize)
        manage_tcp
        ;;
esac