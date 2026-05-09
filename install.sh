#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# XBoard Node 一键安装脚本
# 适配: CentOS Stream 10 (兼容 CentOS 8/9, RHEL 系)
# 功能: 安装 Docker + Git → 克隆 xboard-node → 交互配置 → 启动
# ══════════════════════════════════════════════════════════════════════════════

set -e

# ── 颜色定义 ─────────────────────────────────────────────────────────────────
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

# ── Root 检查 ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

# ══════════════════════════════════════════════════════════════════════════════
# 1. 系统检测
# ══════════════════════════════════════════════════════════════════════════════
step "1/5  系统检测"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
    info "操作系统: $OS_NAME $OS_VERSION"
else
    error "无法识别操作系统"
fi

# 检测包管理器
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
else
    error "未找到 dnf 或 yum，此脚本仅支持 RHEL/CentOS 系"
fi
info "包管理器: $PKG_MGR"

# ══════════════════════════════════════════════════════════════════════════════
# 2. 处理有问题的仓库源 + 安装 Docker & Git
# ══════════════════════════════════════════════════════════════════════════════
step "2/5  安装依赖 (Docker & Git)"

# ── 禁用可能有问题的 EPEL 源 ────────────────────────────────────────────────
for repo in epel epel-cisco-openh264 epel-next; do
    if [ -f "/etc/yum.repos.d/${repo}.repo" ] || $PKG_MGR repolist --enabled 2>/dev/null | grep -qi "$repo"; then
        warn "禁用有问题的仓库: $repo"
        $PKG_MGR config-manager --set-disabled "$repo" 2>/dev/null || true
    fi
done

# ── 通用 DNF 安装参数 (跳过已禁用的源) ──────────────────────────────────────
DNF_OPTS="--disablerepo=epel --disablerepo=epel-cisco-openh264 --disablerepo=epel-next"

# ── 安装 Git ─────────────────────────────────────────────────────────────────
if command -v git &>/dev/null; then
    info "Git 已安装: $(git --version)"
else
    info "正在安装 Git..."
    $PKG_MGR install -y $DNF_OPTS git || error "Git 安装失败"
    info "Git 安装完成: $(git --version)"
fi

# ── 安装 Docker ──────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    info "Docker 已安装: $(docker --version)"
else
    info "正在安装 Docker..."

    # 清理旧包
    $PKG_MGR remove -y $DNF_OPTS docker docker-client docker-client-latest \
        docker-common docker-latest docker-engine podman buildah 2>/dev/null || true

    # 安装前置工具
    $PKG_MGR install -y $DNF_OPTS dnf-plugins-core || true

    # 添加 Docker 官方仓库
    if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
        $PKG_MGR config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    # CentOS Stream 10 适配: 强制使用 CentOS 9 的仓库
    MAJOR_VER="${OS_VERSION%%.*}"
    if [[ "$MAJOR_VER" -ge 10 ]]; then
        warn "检测到 CentOS/RHEL 10+，Docker 官方暂未适配，使用 CentOS 9 仓库源"
        sed -i 's/$releasever/9/g' /etc/yum.repos.d/docker-ce.repo
    fi

    # 安装 Docker
    $PKG_MGR install -y $DNF_OPTS \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin \
        || error "Docker 安装失败，请检查网络或仓库配置"

    info "Docker 安装完成: $(docker --version)"
fi

# ── 确保 Docker 运行 ────────────────────────────────────────────────────────
if ! systemctl is-active docker &>/dev/null; then
    systemctl start docker
    systemctl enable docker
    info "Docker 服务已启动并设为开机自启"
else
    info "Docker 服务运行中"
fi

# 验证 docker compose
docker compose version &>/dev/null || error "docker compose 不可用，请检查安装"
info "Docker Compose: $(docker compose version --short)"

# ══════════════════════════════════════════════════════════════════════════════
# 3. 克隆 xboard-node 仓库
# ══════════════════════════════════════════════════════════════════════════════
step "3/5  克隆 xboard-node 仓库"

INSTALL_DIR="/opt/xboard-node"

if [ -d "$INSTALL_DIR" ]; then
    warn "目录 $INSTALL_DIR 已存在"
    read -rp "$(echo -e "${YELLOW}是否删除并重新克隆？[y/N]: ${NC}")" RECLONE
    if [[ "$RECLONE" =~ ^[Yy]$ ]]; then
        # 先停掉可能在运行的容器
        if [ -f "$INSTALL_DIR/compose.yml" ] || [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
            info "停止已有容器..."
            cd "$INSTALL_DIR" && docker compose down 2>/dev/null || true
            cd /
        fi
        rm -rf "$INSTALL_DIR"
        info "已删除旧目录"
    else
        info "保留已有目录，跳过克隆"
    fi
fi

if [ ! -d "$INSTALL_DIR" ]; then
    git clone -b compose --depth 1 https://github.com/cedar2025/xboard-node.git "$INSTALL_DIR" \
        || error "仓库克隆失败，请检查网络连接"
    info "仓库克隆完成: $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# 4. 交互式配置
# ══════════════════════════════════════════════════════════════════════════════
step "4/5  配置 XBoard Node"

echo ""
# ── Panel URL ────────────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${BOLD}面板地址 (Panel URL): ${NC}")" PANEL_URL
    if [[ -n "$PANEL_URL" ]]; then
        # 去掉末尾斜杠
        PANEL_URL="${PANEL_URL%/}"
        break
    fi
    warn "面板地址不能为空"
done

# ── Token ────────────────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${BOLD}通信密钥 (Token): ${NC}")" PANEL_TOKEN
    if [[ -n "$PANEL_TOKEN" ]]; then
        break
    fi
    warn "Token 不能为空"
done

# ── Kernel 类型 ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}内核类型:${NC}"
echo "  1) singbox (默认)"
echo "  2) xray"
read -rp "$(echo -e "${BOLD}请选择 [1/2] (默认 1): ${NC}")" KERNEL_CHOICE
case "$KERNEL_CHOICE" in
    2) KERNEL_TYPE="xray" ;;
    *) KERNEL_TYPE="singbox" ;;
esac
info "内核: $KERNEL_TYPE"

# ── Cert Mode ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}证书模式:${NC}"
echo "  1) self  - 自签证书 (默认)"
echo "  2) http  - ACME HTTP-01"
echo "  3) none  - 不使用 TLS"
read -rp "$(echo -e "${BOLD}请选择 [1/2/3] (默认 1): ${NC}")" CERT_CHOICE
case "$CERT_CHOICE" in
    2) CERT_MODE="http" ;;
    3) CERT_MODE="none" ;;
    *) CERT_MODE="self" ;;
esac
info "证书模式: $CERT_MODE"

# ── Node IDs ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}配置节点 ID (输入完毕后直接按回车结束):${NC}"
NODE_IDS=()
NODE_COUNT=1
while true; do
    read -rp "$(echo -e "  节点 ${NODE_COUNT} 的 ID (留空结束): ")" NODE_INPUT
    if [[ -z "$NODE_INPUT" ]]; then
        if [[ ${#NODE_IDS[@]} -eq 0 ]]; then
            warn "至少需要一个节点 ID"
            continue
        fi
        break
    fi
    # 验证是否为数字
    if ! [[ "$NODE_INPUT" =~ ^[0-9]+$ ]]; then
        warn "节点 ID 必须为数字"
        continue
    fi
    NODE_IDS+=("$NODE_INPUT")
    info "已添加节点: $NODE_INPUT"
    ((NODE_COUNT++))
done

echo ""
info "节点列表: ${NODE_IDS[*]}"

# ══════════════════════════════════════════════════════════════════════════════
# 5. 生成配置文件 & 启动
# ══════════════════════════════════════════════════════════════════════════════
step "5/5  生成配置并启动"

# ── 生成 config.yml ──────────────────────────────────────────────────────────
CONFIG_FILE="$INSTALL_DIR/config/config.yml"
mkdir -p "$INSTALL_DIR/config"

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
echo ""

# ── 确认启动 ─────────────────────────────────────────────────────────────────
read -rp "$(echo -e "${BOLD}确认启动？[Y/n]: ${NC}")" CONFIRM_START
if [[ "$CONFIRM_START" =~ ^[Nn]$ ]]; then
    info "已跳过启动。你可以稍后手动执行:"
    echo "  cd $INSTALL_DIR && docker compose up -d"
    exit 0
fi

# ── 启动容器 ─────────────────────────────────────────────────────────────────
info "正在拉取镜像并启动..."
cd "$INSTALL_DIR"
docker compose pull
docker compose up -d

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ XBoard Node 安装完成！${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  安装目录:  ${BOLD}$INSTALL_DIR${NC}"
echo -e "  面板地址:  ${BOLD}$PANEL_URL${NC}"
echo -e "  节点 ID:   ${BOLD}${NODE_IDS[*]}${NC}"
echo -e "  内核类型:  ${BOLD}$KERNEL_TYPE${NC}"
echo -e "  证书模式:  ${BOLD}$CERT_MODE${NC}"
echo ""
echo -e "  ${BOLD}常用命令:${NC}"
echo "  查看日志:    cd $INSTALL_DIR && docker compose logs -f"
echo "  重启服务:    cd $INSTALL_DIR && docker compose restart"
echo "  停止服务:    cd $INSTALL_DIR && docker compose down"
echo "  更新版本:    cd $INSTALL_DIR && docker compose pull && docker compose up -d"
echo "  编辑配置:    vim $CONFIG_FILE"
echo ""