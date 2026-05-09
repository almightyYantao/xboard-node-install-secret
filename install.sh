#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# XBoard Node 一键安装 & 管理脚本
# 适配: CentOS Stream 10 (兼容 CentOS 8/9, RHEL 系)
# 版本: v1.2.0
#
# 用法:
#   curl -fsSL <url> | bash
#   或下载后: bash install.sh
# ══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_VERSION="v1.2.0"
INSTALL_DIR="/opt/xboard-node"
CONFIG_FILE="$INSTALL_DIR/config/config.yml"
LB_NODE_BIN="/usr/local/bin/lb-node"

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

# ── 关键修复: 支持 curl | bash 模式下的交互输入 ──────────────────────────────
# 当用 curl | bash 运行时，stdin 是 curl 的输出，read 读不到键盘
# 所以统一从 /dev/tty 读取用户输入
ask() {
    local prompt="$1"
    local varname="$2"
    read -rp "$(echo -e "$prompt")" "$varname" < /dev/tty
}

# ── Root 检查 ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ══════════════════════════════════════════════════════════════════════════════
#  检测当前环境
# ══════════════════════════════════════════════════════════════════════════════
DOCKER_INSTALLED=false
NODE_INSTALLED=false
NODE_RUNNING=false
LBNODE_INSTALLED=false

command -v docker &>/dev/null && DOCKER_INSTALLED=true
[ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/compose.yml" ] && NODE_INSTALLED=true
if $NODE_INSTALLED && $DOCKER_INSTALLED; then
    cd "$INSTALL_DIR"
    docker compose ps --status running 2>/dev/null | grep -q "xboard" && NODE_RUNNING=true
    cd - &>/dev/null
fi
[ -f "$LB_NODE_BIN" ] && LBNODE_INSTALLED=true

# ══════════════════════════════════════════════════════════════════════════════
#  Banner & 菜单
# ══════════════════════════════════════════════════════════════════════════════

show_banner() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  XBoard Node 安装 & 管理脚本  ${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Docker:       $(if $DOCKER_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    echo -e "  XBoard Node:  $(if $NODE_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    if $NODE_INSTALLED; then
        echo -e "  容器状态:     $(if $NODE_RUNNING; then echo -e "${GREEN}运行中${NC}"; else echo -e "${YELLOW}已停止${NC}"; fi)"
    fi
    echo -e "  lb-node 命令: $(if $LBNODE_INSTALLED; then echo -e "${GREEN}已安装${NC}"; else echo -e "${RED}未安装${NC}"; fi)"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  面板地址:     $(grep -E '^\s+url:' "$CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  节点 ID:      $(grep -E '^\s+- node_id:' "$CONFIG_FILE" 2>/dev/null | awk '{print $3}' | tr '\n' ' ')"
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
        echo "  1) 重新安装 (会停止当前服务，重新走完整流程)"
    fi
    echo "  2) 仅更新脚本 (更新 lb-node 命令，不动 Docker 和配置)"
    if $NODE_INSTALLED; then
        echo "  3) 重新配置 (修改面板地址/Token/节点ID，重启服务)"
        echo "  4) 更新镜像 (拉取最新 xboard-node 镜像并重启)"
    fi
    echo "  0) 退出"
    echo ""
    ask "${BOLD}请选择: ${NC}" MENU_CHOICE

    case "$MENU_CHOICE" in
        1) MODE="full_install" ;;
        2) MODE="update_script" ;;
        3)
            $NODE_INSTALLED || error "XBoard Node 未安装，请先执行全新安装"
            MODE="reconfigure"
            ;;
        4)
            $NODE_INSTALLED || error "XBoard Node 未安装，请先执行全新安装"
            MODE="update_image"
            ;;
        0) info "退出"; exit 0 ;;
        *) error "无效选择" ;;
    esac
}

# 全新环境直接装，不显示菜单
if ! $NODE_INSTALLED && ! $LBNODE_INSTALLED; then
    MODE="full_install"
    show_banner
    info "检测到全新环境，开始完整安装..."
else
    run_menu
fi

# ══════════════════════════════════════════════════════════════════════════════
#  函数定义
# ══════════════════════════════════════════════════════════════════════════════

detect_system() {
    step "系统检测"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
        info "操作系统: $OS_NAME $OS_VERSION"
    else
        error "无法识别操作系统"
    fi

    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    else
        error "未找到 dnf 或 yum，此脚本仅支持 RHEL/CentOS 系"
    fi
    info "包管理器: $PKG_MGR"
}

detect_v2bx() {
    step "检测已有节点后端"

    V2BX_FOUND=false
    V2BX_TYPE=""

    if systemctl list-unit-files 2>/dev/null | grep -qi "v2bx\|V2bX"; then
        V2BX_FOUND=true
        V2BX_TYPE="systemd"
        V2BX_SERVICE=$(systemctl list-unit-files 2>/dev/null | grep -i "v2bx" | awk '{print $1}' | head -1)
        if systemctl is-active "$V2BX_SERVICE" &>/dev/null; then
            V2BX_STATUS="运行中"
        else
            V2BX_STATUS="已停止"
        fi
        info "发现 V2bX (systemd): $V2BX_SERVICE [$V2BX_STATUS]"
    fi

    if command -v docker &>/dev/null; then
        V2BX_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i "v2bx" | head -1)
        if [[ -n "$V2BX_CONTAINER" ]]; then
            V2BX_FOUND=true
            V2BX_TYPE="docker"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "v2bx"; then
                V2BX_STATUS="运行中"
            else
                V2BX_STATUS="已停止"
            fi
            info "发现 V2bX (Docker): $V2BX_CONTAINER [$V2BX_STATUS]"
        fi
    fi

    if ! $V2BX_FOUND; then
        V2BX_BIN=$(command -v V2bX 2>/dev/null || command -v v2bx 2>/dev/null || true)
        if [[ -z "$V2BX_BIN" ]]; then
            for p in /usr/local/bin/V2bX /usr/local/bin/v2bx /opt/V2bX/V2bX /usr/bin/V2bX; do
                [ -f "$p" ] && V2BX_BIN="$p" && break
            done
        fi
        if [[ -n "$V2BX_BIN" ]]; then
            V2BX_FOUND=true
            V2BX_TYPE="binary"
            info "发现 V2bX 二进制: $V2BX_BIN"
        fi
    fi

    if $V2BX_FOUND; then
        echo ""
        warn "检测到已安装 V2bX，可能产生端口冲突"
        echo ""
        echo -e "${BOLD}请选择操作:${NC}"
        echo "  1) 卸载 V2bX (停止 + 删除)"
        echo "  2) 仅停止 V2bX (保留文件)"
        echo "  3) 跳过不处理"
        echo "  0) 退出安装"
        echo ""
        ask "${BOLD}请选择 [0/1/2/3]: ${NC}" V2BX_ACTION

        case "$V2BX_ACTION" in
            1)
                info "正在卸载 V2bX..."
                if [[ "$V2BX_TYPE" == "systemd" ]]; then
                    systemctl stop "$V2BX_SERVICE" 2>/dev/null || true
                    systemctl disable "$V2BX_SERVICE" 2>/dev/null || true
                    rm -f "/etc/systemd/system/$V2BX_SERVICE" 2>/dev/null || true
                    systemctl daemon-reload 2>/dev/null || true
                    info "已移除 systemd 服务: $V2BX_SERVICE"
                fi
                if [[ "$V2BX_TYPE" == "docker" ]]; then
                    docker stop "$V2BX_CONTAINER" 2>/dev/null || true
                    docker rm "$V2BX_CONTAINER" 2>/dev/null || true
                    info "已删除容器: $V2BX_CONTAINER"
                fi
                for p in /usr/local/bin/V2bX /usr/local/bin/v2bx /opt/V2bX /usr/bin/V2bX; do
                    [ -e "$p" ] && rm -rf "$p" && info "已删除: $p"
                done
                for cfg in /etc/V2bX /etc/v2bx /usr/local/etc/V2bX; do
                    if [ -d "$cfg" ]; then
                        ask "${YELLOW}是否删除配置目录 $cfg？[y/N]: ${NC}" DEL_CFG
                        [[ "$DEL_CFG" =~ ^[Yy]$ ]] && rm -rf "$cfg" && info "已删除: $cfg" || info "保留: $cfg"
                    fi
                done
                info "V2bX 卸载完成"
                ;;
            2)
                info "正在停止 V2bX..."
                if [[ "$V2BX_TYPE" == "systemd" ]]; then
                    systemctl stop "$V2BX_SERVICE" 2>/dev/null || true
                    systemctl disable "$V2BX_SERVICE" 2>/dev/null || true
                    info "已停止: $V2BX_SERVICE"
                fi
                if [[ "$V2BX_TYPE" == "docker" ]]; then
                    docker stop "$V2BX_CONTAINER" 2>/dev/null || true
                    info "已停止: $V2BX_CONTAINER"
                fi
                ;;
            3) warn "跳过 V2bX 处理" ;;
            0) info "退出安装"; exit 0 ;;
            *) error "无效选择" ;;
        esac
    else
        info "未检测到 V2bX，继续安装"
    fi
}

install_dependencies() {
    step "安装依赖 (Docker & Git)"

    for repo in epel epel-cisco-openh264 epel-next; do
        if [ -f "/etc/yum.repos.d/${repo}.repo" ] || $PKG_MGR repolist --enabled 2>/dev/null | grep -qi "$repo"; then
            warn "禁用仓库: $repo"
            $PKG_MGR config-manager --set-disabled "$repo" 2>/dev/null || true
        fi
    done
    DNF_OPTS="--disablerepo=epel --disablerepo=epel-cisco-openh264 --disablerepo=epel-next"

    if command -v git &>/dev/null; then
        info "Git 已安装: $(git --version)"
    else
        info "正在安装 Git..."
        $PKG_MGR install -y $DNF_OPTS git || error "Git 安装失败"
        info "Git 安装完成: $(git --version)"
    fi

    if command -v docker &>/dev/null; then
        info "Docker 已安装: $(docker --version)"
    else
        info "正在安装 Docker..."
        $PKG_MGR remove -y $DNF_OPTS docker docker-client docker-client-latest \
            docker-common docker-latest docker-engine podman buildah 2>/dev/null || true
        $PKG_MGR install -y $DNF_OPTS dnf-plugins-core || true

        [ ! -f /etc/yum.repos.d/docker-ce.repo ] && \
            $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

        MAJOR_VER="${OS_VERSION%%.*}"
        if [[ "$MAJOR_VER" -ge 10 ]]; then
            warn "CentOS/RHEL 10+ 适配: 使用 CentOS 9 仓库源"
            sed -i 's/$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
        fi

        $PKG_MGR install -y $DNF_OPTS \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin \
            || error "Docker 安装失败"
        info "Docker 安装完成: $(docker --version)"
    fi

    if ! systemctl is-active docker &>/dev/null; then
        systemctl start docker
        systemctl enable docker
        info "Docker 服务已启动"
    else
        info "Docker 服务运行中"
    fi

    docker compose version &>/dev/null || error "docker compose 不可用"
    info "Docker Compose: $(docker compose version --short)"
}

clone_repo() {
    step "克隆 xboard-node 仓库"

    if [ -d "$INSTALL_DIR" ]; then
        warn "目录 $INSTALL_DIR 已存在"
        ask "${YELLOW}是否删除并重新克隆？[y/N]: ${NC}" RECLONE
        if [[ "$RECLONE" =~ ^[Yy]$ ]]; then
            if [ -f "$INSTALL_DIR/compose.yml" ]; then
                info "停止已有容器..."
                cd "$INSTALL_DIR" && docker compose down 2>/dev/null || true
                cd /
            fi
            rm -rf "$INSTALL_DIR"
            info "已删除旧目录"
        else
            info "保留已有目录"
        fi
    fi

    if [ ! -d "$INSTALL_DIR" ]; then
        git clone -b compose --depth 1 https://github.com/cedar2025/xboard-node.git "$INSTALL_DIR" \
            || error "仓库克隆失败"
        info "克隆完成: $INSTALL_DIR"
    fi
}

interactive_config() {
    step "配置 XBoard Node"
    echo ""

    while true; do
        ask "${BOLD}面板地址 (Panel URL): ${NC}" PANEL_URL
        [[ -n "$PANEL_URL" ]] && { PANEL_URL="${PANEL_URL%/}"; break; }
        warn "面板地址不能为空"
    done

    while true; do
        ask "${BOLD}通信密钥 (Token): ${NC}" PANEL_TOKEN
        [[ -n "$PANEL_TOKEN" ]] && break
        warn "Token 不能为空"
    done

    echo ""
    echo -e "${BOLD}内核类型:${NC}"
    echo "  1) singbox (默认)"
    echo "  2) xray"
    ask "${BOLD}请选择 [1/2] (默认 1): ${NC}" KERNEL_CHOICE
    case "$KERNEL_CHOICE" in
        2) KERNEL_TYPE="xray" ;;
        *) KERNEL_TYPE="singbox" ;;
    esac
    info "内核: $KERNEL_TYPE"

    echo ""
    echo -e "${BOLD}证书模式:${NC}"
    echo "  1) self  - 自签证书 (默认)"
    echo "  2) http  - ACME HTTP-01"
    echo "  3) none  - 不使用 TLS"
    ask "${BOLD}请选择 [1/2/3] (默认 1): ${NC}" CERT_CHOICE
    case "$CERT_CHOICE" in
        2) CERT_MODE="http" ;;
        3) CERT_MODE="none" ;;
        *) CERT_MODE="self" ;;
    esac
    info "证书模式: $CERT_MODE"

    echo ""
    echo -e "${BOLD}配置节点 ID (输入完毕后直接按回车结束):${NC}"
    NODE_IDS=()
    NODE_COUNT=1
    while true; do
        ask "  节点 ${NODE_COUNT} 的 ID (留空结束): " NODE_INPUT
        if [[ -z "$NODE_INPUT" ]]; then
            [[ ${#NODE_IDS[@]} -eq 0 ]] && warn "至少需要一个节点 ID" && continue
            break
        fi
        ! [[ "$NODE_INPUT" =~ ^[0-9]+$ ]] && warn "节点 ID 必须为数字" && continue
        NODE_IDS+=("$NODE_INPUT")
        info "已添加节点: $NODE_INPUT"
        ((NODE_COUNT++))
    done
    info "节点列表: ${NODE_IDS[*]}"
}

generate_config() {
    mkdir -p "$INSTALL_DIR/config"

    if [ -f "$CONFIG_FILE" ]; then
        BACKUP="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
        cp "$CONFIG_FILE" "$BACKUP"
        info "旧配置已备份: $BACKUP"
    fi

    cat > "$CONFIG_FILE" <<EOF
# XBoard Node Configuration
# Generated by install script at $(date '+%Y-%m-%d %H:%M:%S')

panel:
  url: "${PANEL_URL}"
  token: "${PANEL_TOKEN}"
  node_id: ${NODE_IDS[0]}

nodes:
EOF

    for nid in "${NODE_IDS[@]}"; do
        echo "  - node_id: ${nid}" >> "$CONFIG_FILE"
    done

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

    info "配置文件已生成: $CONFIG_FILE"
    echo ""
    echo -e "${CYAN}─── 配置预览 ──────────────────────────────────────────────────────────────${NC}"
    cat "$CONFIG_FILE"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
}

start_service() {
    echo ""
    ask "${BOLD}确认启动？[Y/n]: ${NC}" CONFIRM_START
    if [[ "$CONFIRM_START" =~ ^[Nn]$ ]]; then
        info "已跳过启动。手动执行: cd $INSTALL_DIR && docker compose up -d"
        return
    fi
    info "正在拉取镜像并启动..."
    cd "$INSTALL_DIR"
    docker compose pull
    docker compose up -d
    info "服务已启动"
}

install_lbnode() {
    step "安装 lb-node 快捷命令"

    cat > "$LB_NODE_BIN" <<'LBEOF'
#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# lb-node — XBoard Node 快捷管理工具
# ══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/xboard-node"
CONFIG_FILE="$INSTALL_DIR/config/config.yml"

check_install() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}[ERROR]${NC} XBoard Node 未安装 ($INSTALL_DIR 不存在)"
        exit 1
    fi
}

cmd_status() {
    check_install
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  XBoard Node 状态${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}[容器]${NC}"
    cd "$INSTALL_DIR"
    docker compose ps 2>/dev/null || echo -e "  ${RED}容器未运行${NC}"
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${BOLD}[配置]${NC}"
        echo -e "  面板地址:  $(grep -E '^\s+url:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  节点 ID:   $(grep -E '^\s+- node_id:' "$CONFIG_FILE" | awk '{print $3}' | tr '\n' ' ')"
        echo -e "  内核类型:  $(grep -E '^\s+type:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo -e "  证书模式:  $(grep -E '^\s+cert_mode:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')"
        echo ""
    fi
    echo -e "${BOLD}[资源]${NC}"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}   内存: {{.MemUsage}}" \
        $(docker compose ps -q 2>/dev/null) 2>/dev/null || echo "  无法获取"
    echo ""
}

cmd_logs() {
    check_install
    cd "$INSTALL_DIR"
    docker compose logs -f "$@"
}

cmd_config() {
    check_install
    [ ! -f "$CONFIG_FILE" ] && echo -e "${RED}[ERROR]${NC} 配置文件不存在" && exit 1
    case "${1:-edit}" in
        --show|-s)
            echo ""
            echo -e "${CYAN}─── $CONFIG_FILE ───${NC}"
            cat "$CONFIG_FILE"
            echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
            echo ""
            ;;
        *)
            EDITOR_CMD="${EDITOR:-$(command -v vim || command -v vi || command -v nano)}"
            [[ -z "$EDITOR_CMD" ]] && echo -e "${RED}[ERROR]${NC} 未找到编辑器" && exit 1
            "$EDITOR_CMD" "$CONFIG_FILE"
            echo ""
            read -rp "$(echo -e "${YELLOW}配置已修改，是否重启使生效？[Y/n]: ${NC}")" RELOAD
            if [[ ! "$RELOAD" =~ ^[Nn]$ ]]; then
                cd "$INSTALL_DIR" && docker compose restart
                echo -e "${GREEN}[INFO]${NC} 已重启"
            fi
            ;;
    esac
}

cmd_start() {
    check_install; cd "$INSTALL_DIR"
    echo -e "${GREEN}[INFO]${NC} 正在启动..."
    docker compose up -d
    echo -e "${GREEN}[INFO]${NC} 启动完成"
    docker compose ps
}

cmd_stop() {
    check_install; cd "$INSTALL_DIR"
    echo -e "${YELLOW}[INFO]${NC} 正在停止..."
    docker compose down
    echo -e "${YELLOW}[INFO]${NC} 已停止"
}

cmd_restart() {
    check_install; cd "$INSTALL_DIR"
    echo -e "${GREEN}[INFO]${NC} 正在重启..."
    docker compose restart
    echo -e "${GREEN}[INFO]${NC} 重启完成"
    docker compose ps
}

cmd_update() {
    check_install; cd "$INSTALL_DIR"
    echo -e "${GREEN}[INFO]${NC} 拉取最新镜像..."
    docker compose pull
    echo -e "${GREEN}[INFO]${NC} 重建容器..."
    docker compose up -d
    echo -e "${GREEN}[INFO]${NC} 更新完成"
    docker compose ps
}

cmd_reset() {
    check_install; cd "$INSTALL_DIR"
    echo -e "${YELLOW}[INFO]${NC} 正在重建容器 (清除数据卷)..."
    docker compose down -v
    docker compose up -d
    echo -e "${GREEN}[INFO]${NC} 重建完成"
}

cmd_uninstall() {
    check_install
    echo ""
    echo -e "${RED}${BOLD}  ⚠  即将卸载 XBoard Node${NC}"
    echo "  这将停止容器、删除 $INSTALL_DIR 和 lb-node 命令"
    echo ""
    read -rp "$(echo -e "${RED}确认卸载？输入 YES 继续: ${NC}")" CONFIRM
    [[ "$CONFIRM" != "YES" ]] && echo "已取消" && exit 0
    cd "$INSTALL_DIR"
    docker compose down -v 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/lb-node
    echo -e "${GREEN}[INFO]${NC} XBoard Node 已卸载"
}

cmd_help() {
    echo ""
    echo -e "${BOLD}lb-node${NC} — XBoard Node 快捷管理工具"
    echo ""
    echo -e "${BOLD}用法:${NC}  lb-node <命令> [参数]"
    echo ""
    echo -e "${BOLD}命令:${NC}"
    echo -e "  ${GREEN}status${NC}          查看运行状态、配置摘要、资源占用"
    echo -e "  ${GREEN}logs${NC}            查看实时日志 (Ctrl+C 退出)"
    echo "                  lb-node logs -n 100        最近 100 行"
    echo "                  lb-node logs --since 30m   最近 30 分钟"
    echo "                  lb-node logs --tail 0 -f   只看新日志"
    echo -e "  ${GREEN}config${NC}          编辑配置文件 (保存后询问是否重启)"
    echo -e "  ${GREEN}config --show${NC}   查看配置 (不编辑)"
    echo -e "  ${GREEN}start${NC}           启动服务"
    echo -e "  ${GREEN}stop${NC}            停止服务"
    echo -e "  ${GREEN}restart${NC}         重启服务"
    echo -e "  ${GREEN}update${NC}          拉取最新镜像并重启"
    echo -e "  ${GREEN}reset${NC}           重建容器 (清除数据卷)"
    echo -e "  ${GREEN}uninstall${NC}       卸载 XBoard Node"
    echo -e "  ${GREEN}help${NC}            显示此帮助"
    echo ""
    echo -e "${BOLD}路径:${NC}"
    echo "  安装目录:  $INSTALL_DIR"
    echo "  配置文件:  $CONFIG_FILE"
    echo "  Compose:   $INSTALL_DIR/compose.yml"
    echo ""
}

case "${1:-help}" in
    status|st|s)           cmd_status             ;;
    logs|log|l)            shift; cmd_logs "$@"    ;;
    config|conf|cfg|c)     shift; cmd_config "$@"  ;;
    start|up)              cmd_start              ;;
    stop|down)             cmd_stop               ;;
    restart|rs)            cmd_restart            ;;
    update|upgrade|pull)   cmd_update             ;;
    reset)                 cmd_reset              ;;
    uninstall|remove|rm)   cmd_uninstall          ;;
    help|-h|--help)        cmd_help               ;;
    *)
        echo -e "${RED}[ERROR]${NC} 未知命令: $1"
        cmd_help
        exit 1
        ;;
esac
LBEOF

    chmod +x "$LB_NODE_BIN"
    info "lb-node 命令已安装"
}

show_done() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ 操作完成！${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "  安装目录:  ${BOLD}$INSTALL_DIR${NC}"
        echo -e "  面板地址:  ${BOLD}$(grep -E '^\s+url:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')${NC}"
        echo -e "  节点 ID:   ${BOLD}$(grep -E '^\s+- node_id:' "$CONFIG_FILE" | awk '{print $3}' | tr '\n' ' ')${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}快捷命令:${NC}"
    echo "  lb-node status      查看状态"
    echo "  lb-node logs        查看日志"
    echo "  lb-node config      编辑配置"
    echo "  lb-node config -s   查看配置"
    echo "  lb-node start       启动服务"
    echo "  lb-node stop        停止服务"
    echo "  lb-node restart     重启服务"
    echo "  lb-node update      更新版本"
    echo "  lb-node reset       重建容器"
    echo "  lb-node uninstall   卸载"
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
        show_done
        ;;
    update_script)
        install_lbnode
        if $NODE_RUNNING; then
            info "服务运行中，未做任何改动"
        fi
        show_done
        ;;
    reconfigure)
        interactive_config
        generate_config
        echo ""
        ask "${BOLD}是否重启服务使新配置生效？[Y/n]: ${NC}" DO_RESTART
        if [[ ! "$DO_RESTART" =~ ^[Nn]$ ]]; then
            cd "$INSTALL_DIR"
            docker compose restart
            info "服务已重启"
        fi
        install_lbnode
        show_done
        ;;
    update_image)
        step "更新镜像"
        cd "$INSTALL_DIR"
        docker compose pull
        docker compose up -d
        info "镜像更新完成"
        install_lbnode
        show_done
        ;;
esac