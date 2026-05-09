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

SCRIPT_VERSION="v1.3.0"
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
    echo "  0) 退出"
    echo ""
    ask "${BOLD}请选择: ${NC}" MENU_CHOICE

    case "$MENU_CHOICE" in
        1) MODE="full_install" ;;
        2) MODE="update_script" ;;
        3) $NODE_INSTALLED || error "未安装，请先全新安装"; MODE="reconfigure" ;;
        4) $NODE_INSTALLED || error "未安装，请先全新安装"; MODE="update_image" ;;
        5) MODE="reporter_manage" ;;
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
esac