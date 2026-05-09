#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# node-reporter.sh — TrafficBoard sidecar (v2.0)
#
# 兼容两种配置来源:
#   1. xboard-node config.yml (优先)
#   2. V2bX config.json (兼容旧版)
#
# Speed detection:
#   Mode A: iptables per-port counters  (per-node, accurate)
#   Mode B: NIC total fallback          (same speed for co-located nodes)
#
# Usage:
#   ./node-reporter.sh enable   [config]   # install systemd service
#   ./node-reporter.sh disable             # stop + clean iptables
#   ./node-reporter.sh run      [config]   # foreground
#   ./node-reporter.sh status              # show service status
#
# Environment:
#   TB_INTERVAL=10   seconds between pushes
#   TB_IFACE=eth0    override network interface
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SERVICE_NAME="tb-reporter"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INTERVAL="${TB_INTERVAL:-10}"
IFACE="${TB_IFACE:-}"
IPTABLES_CHAIN="TB_REPORTER"

# ── config search paths (优先级从高到低) ─────────────────────────────────────
CONFIG_SEARCH_PATHS=(
    "/opt/xboard-node/config/config.yml"
    "/etc/V2bX/config.json"
    "/usr/local/V2bX/etc/config.json"
    "/usr/local/etc/V2bX/config.json"
)

# ── iptables helpers ─────────────────────────────────────────────────────────
ipt_rule_exists() {
    local chain="$1" proto="$2" direction="$3" port="$4"
    iptables -C "${chain}" -p "${proto}" "--${direction}" "${port}" -j RETURN 2>/dev/null
}

setup_iptables_for_port() {
    local port="$1"
    [[ -z "${port}" || "${port}" == "0" ]] && return
    for proto in tcp udp; do
        ipt_rule_exists "${IPTABLES_CHAIN}" "${proto}" dport "${port}" || \
            iptables -A "${IPTABLES_CHAIN}" -p "${proto}" --dport "${port}" -j RETURN
        ipt_rule_exists "${IPTABLES_CHAIN}" "${proto}" sport "${port}" || \
            iptables -A "${IPTABLES_CHAIN}" -p "${proto}" --sport "${port}" -j RETURN
    done
}

init_iptables() {
    iptables -N "${IPTABLES_CHAIN}" 2>/dev/null || true
    iptables -C INPUT  -j "${IPTABLES_CHAIN}" 2>/dev/null || iptables -I INPUT  1 -j "${IPTABLES_CHAIN}"
    iptables -C OUTPUT -j "${IPTABLES_CHAIN}" 2>/dev/null || iptables -I OUTPUT 1 -j "${IPTABLES_CHAIN}"
}

cleanup_iptables() {
    iptables -D INPUT  -j "${IPTABLES_CHAIN}" 2>/dev/null || true
    iptables -D OUTPUT -j "${IPTABLES_CHAIN}" 2>/dev/null || true
    iptables -F "${IPTABLES_CHAIN}" 2>/dev/null || true
    iptables -X "${IPTABLES_CHAIN}" 2>/dev/null || true
}

read_port_bytes() {
    local direction="$1" port="$2"
    local ipt_pat
    [[ "${direction}" == "dport" ]] && ipt_pat="dpt:${port}" || ipt_pat="spt:${port}"
    iptables -vxnL "${IPTABLES_CHAIN}" 2>/dev/null \
        | awk -v pat="${ipt_pat}" '$0 ~ pat {sum += $2} END {print sum+0}'
}

# ── subcommand: status ───────────────────────────────────────────────────────
cmd_status() {
    echo ""
    if systemctl is-active "${SERVICE_NAME}" &>/dev/null; then
        echo "  tb-reporter: 运行中"
        systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null | head -10
    elif [ -f "${SERVICE_FILE}" ]; then
        echo "  tb-reporter: 已安装但未运行"
    else
        echo "  tb-reporter: 未安装"
    fi
    echo ""
    if iptables -L "${IPTABLES_CHAIN}" -n &>/dev/null 2>&1; then
        echo "  iptables chain ${IPTABLES_CHAIN}:"
        iptables -vxnL "${IPTABLES_CHAIN}" 2>/dev/null | head -20
    fi
    exit 0
}

# ── subcommand dispatch ──────────────────────────────────────────────────────
CMD="${1:-run}"
case "${CMD}" in
    enable)
        CONFIG_ARG="${2:-}"
        command -v systemctl &>/dev/null || { echo "ERROR: systemd not found." >&2; exit 1; }
        EXEC_LINE="${SELF} run"
        [[ -n "${CONFIG_ARG}" ]] && EXEC_LINE="${SELF} run ${CONFIG_ARG}"
        cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=TrafficBoard Node Reporter
After=network.target docker.service

[Service]
ExecStart=/bin/bash ${EXEC_LINE}
ExecStop=/bin/bash ${SELF} _cleanup
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "${SERVICE_NAME}"
        echo "Service ${SERVICE_NAME} installed and started."
        echo "Logs: journalctl -u ${SERVICE_NAME} -f"
        exit 0
        ;;
    disable)
        command -v systemctl &>/dev/null || { echo "ERROR: systemd not found." >&2; exit 1; }
        systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        cleanup_iptables
        echo "Service ${SERVICE_NAME} stopped, iptables rules removed."
        exit 0
        ;;
    _cleanup)
        cleanup_iptables
        exit 0
        ;;
    status|st)
        cmd_status
        ;;
    run)
        CONFIG_FILE="${2:-}"
        ;;
    *)
        CONFIG_FILE="${1:-}"
        ;;
esac

# ── locate config ────────────────────────────────────────────────────────────
if [[ -z "${CONFIG_FILE}" ]]; then
    for f in "${CONFIG_SEARCH_PATHS[@]}"; do
        [[ -f "${f}" ]] && CONFIG_FILE="${f}" && break
    done
fi
[[ -z "${CONFIG_FILE}" || ! -f "${CONFIG_FILE}" ]] && { echo "ERROR: 找不到配置文件。支持 xboard-node config.yml 或 V2bX config.json" >&2; exit 1; }

echo "Using config: ${CONFIG_FILE}"

command -v python3 &>/dev/null || { echo "ERROR: python3 required." >&2; exit 1; }

# ── parse config (auto-detect format) + fetch ports from API ─────────────────
echo "Fetching node ports from panel..."
mapfile -t NODE_ENTRIES < <(python3 - "${CONFIG_FILE}" <<'PYEOF'
import json, sys, os, urllib.request, urllib.error

config_path = sys.argv[1]
nodes_out = []

def fetch_port(host, key, nid, ntype):
    """从面板 API 获取节点端口"""
    url = f"{host}/api/v1/server/UniProxy/config?token={key}&node_id={nid}&node_type={ntype}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
            return str(data.get("server_port") or "")
    except Exception as e:
        sys.stderr.write(f"WARN: could not fetch port for node {nid}: {e}\n")
        return ""

def parse_xboard_yml(path):
    """解析 xboard-node 的 config.yml (简易 YAML 解析，不依赖 pyyaml)"""
    with open(path) as f:
        content = f.read()

    # 提取 panel 信息
    host = ""
    token = ""
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("url:"):
            host = stripped.split(":", 1)[1].strip().strip('"').strip("'").rstrip("/")
        elif stripped.startswith("token:"):
            token = stripped.split(":", 1)[1].strip().strip('"').strip("'")

    # 提取 node_ids
    node_ids = []
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("- node_id:"):
            nid = stripped.split(":", 1)[1].strip()
            node_ids.append(nid)

    # 提取 kernel type
    ntype = "trojan"  # 默认
    for line in content.splitlines():
        stripped = line.strip()
        if stripped.startswith("type:"):
            val = stripped.split(":", 1)[1].strip().strip('"').strip("'").lower()
            if val in ("singbox", "xray"):
                # xboard-node 的 type 是内核类型，不是协议类型
                # 需要从 API 获取实际协议类型，这里先用通用的
                pass

    results = []
    for nid in node_ids:
        if host and token and nid:
            # 用 trojan 作为默认 node_type，尝试获取端口
            # 如果失败，也尝试其他常见类型
            port = ""
            for try_type in ("trojan", "vmess", "vless", "shadowsocks", "hysteria2"):
                port = fetch_port(host, token, nid, try_type)
                if port:
                    break
            tag = f"node-{nid}"
            results.append(f"{host}|{token}|{nid}|{tag}|{port}")
    return results

def parse_v2bx_json(path):
    """解析 V2bX 的 config.json"""
    with open(path) as f:
        cfg = json.load(f)

    results = []
    for n in cfg.get("Nodes", []):
        a = n.get("ApiConfig") or n
        host  = (a.get("ApiHost") or a.get("APIHost") or "").rstrip("/")
        key   = a.get("ApiKey")  or a.get("Key")      or ""
        nid   = str(a.get("NodeID") or a.get("NodeId") or "")
        ntype = (a.get("NodeType") or "").lower()
        tag   = f"{ntype}-{nid}"

        port = ""
        if host and key and nid and ntype:
            port = fetch_port(host, key, nid, ntype)

        if host and key and nid:
            results.append(f"{host}|{key}|{nid}|{tag}|{port}")
    return results

# 自动检测格式
if config_path.endswith((".yml", ".yaml")):
    entries = parse_xboard_yml(config_path)
elif config_path.endswith(".json"):
    entries = parse_v2bx_json(config_path)
else:
    # 尝试 JSON 优先
    try:
        with open(config_path) as f:
            json.load(f)
        entries = parse_v2bx_json(config_path)
    except json.JSONDecodeError:
        entries = parse_xboard_yml(config_path)

for e in entries:
    print(e)
PYEOF
)

[[ ${#NODE_ENTRIES[@]} -eq 0 ]] && { echo "ERROR: No valid nodes found in config." >&2; exit 1; }

# ── detect speed mode ────────────────────────────────────────────────────────
USE_IPTABLES=false
if command -v iptables &>/dev/null; then
    if iptables -L INPUT -n &>/dev/null 2>&1; then
        USE_IPTABLES=true
    fi
fi

echo "TrafficBoard reporter started — ${#NODE_ENTRIES[@]} node(s), interval=${INTERVAL}s"
echo "Speed mode: $( ${USE_IPTABLES} && echo 'iptables per-port (per-node)' || echo 'NIC total (same for co-located nodes)' )"
for entry in "${NODE_ENTRIES[@]}"; do
    IFS='|' read -r h _ nid itag port <<< "${entry}"
    echo "  node_id=${nid}  tag=${itag}  port=${port:-unknown}  host=${h}"
done

# ── setup iptables ───────────────────────────────────────────────────────────
if "${USE_IPTABLES}"; then
    init_iptables
    for entry in "${NODE_ENTRIES[@]}"; do
        IFS='|' read -r _ _ nid _ port <<< "${entry}"
        if [[ -n "${port}" && "${port}" != "0" ]]; then
            setup_iptables_for_port "${port}"
            echo "  iptables rules added for port ${port} (node ${nid})"
        fi
    done
fi

# ── helpers ──────────────────────────────────────────────────────────────────
detect_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -n "${iface}" ]] && echo "${iface}" && return
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1
}

read_iface_bytes() {
    awk -v iface="$1:" '$1 == iface { print $2, $10 }' /proc/net/dev
}

read_cpu_jiffies() {
    awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat
}

read_mem_kb() {
    awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {print total, total-avail}' /proc/meminfo
}

push_node() {
    local host="$1" key="$2" nid="$3" in_speed="$4" out_speed="$5" cpu="$6" mem_total="$7" mem_used="$8"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${host}/plugins/traffic-board/node-push" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "token=${key}" \
        --data-urlencode "node_id=${nid}" \
        --data-urlencode "in_speed=${in_speed}" \
        --data-urlencode "out_speed=${out_speed}" \
        --data-urlencode "cpu=${cpu}" \
        --data-urlencode "mem_total=${mem_total}" \
        --data-urlencode "mem_used=${mem_used}" \
        --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")
    if [[ "${code}" != "200" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')  node_id=${nid}  push failed (HTTP ${code})" >&2
    fi
}

# ── main loop ────────────────────────────────────────────────────────────────
ACTIVE_IFACE="${IFACE:-$(detect_iface)}"
! "${USE_IPTABLES}" && echo "Network interface: ${ACTIVE_IFACE}"

PREV_RX=0; PREV_TX=0
if ! "${USE_IPTABLES}"; then
    read -r PREV_RX PREV_TX <<< "$(read_iface_bytes "${ACTIVE_IFACE}")" || true
fi

declare -A PREV_IN_BYTES=()
declare -A PREV_OUT_BYTES=()
if "${USE_IPTABLES}"; then
    for entry in "${NODE_ENTRIES[@]}"; do
        IFS='|' read -r _ _ nid _ port <<< "${entry}"
        [[ -z "${port}" || "${port}" == "0" ]] && continue
        PREV_IN_BYTES["${nid}"]=$(read_port_bytes dport "${port}")
        PREV_OUT_BYTES["${nid}"]=$(read_port_bytes sport "${port}")
    done
fi

read -r cu cn cs ci ciow cirq csirq cst <<< "$(read_cpu_jiffies)" || true
PREV_IDLE=${ci:-0}
PREV_TOTAL=$(( ${cu:-0}+${cn:-0}+${cs:-0}+${ci:-0}+${ciow:-0}+${cirq:-0}+${csirq:-0}+${cst:-0} ))

LAST_PUSH=$(( $(date +%s) - INTERVAL ))

while true; do
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_PUSH ))
    if [[ "${ELAPSED}" -lt "${INTERVAL}" ]]; then
        sleep $(( INTERVAL - ELAPSED ))
        NOW=$(date +%s)
        ELAPSED=$(( NOW - LAST_PUSH ))
    fi

    if "${USE_IPTABLES}"; then
        declare -A CURR_IN_BYTES=()
        declare -A CURR_OUT_BYTES=()
        declare -A NODE_IN_SPEED=()
        declare -A NODE_OUT_SPEED=()
        for entry in "${NODE_ENTRIES[@]}"; do
            IFS='|' read -r _ _ nid _ port <<< "${entry}"
            [[ -z "${port}" || "${port}" == "0" ]] && { NODE_IN_SPEED["${nid}"]=0; NODE_OUT_SPEED["${nid}"]=0; continue; }
            CURR_IN_BYTES["${nid}"]=$(read_port_bytes dport "${port}")
            CURR_OUT_BYTES["${nid}"]=$(read_port_bytes sport "${port}")
            prev_in="${PREV_IN_BYTES[${nid}]:-0}"
            prev_out="${PREV_OUT_BYTES[${nid}]:-0}"
            IN_DELTA=$(( CURR_IN_BYTES["${nid}"] - prev_in ))
            OUT_DELTA=$(( CURR_OUT_BYTES["${nid}"] - prev_out ))
            [[ "${IN_DELTA}"  -lt 0 ]] && IN_DELTA=0
            [[ "${OUT_DELTA}" -lt 0 ]] && OUT_DELTA=0
            NODE_IN_SPEED["${nid}"]=$(( IN_DELTA  / ELAPSED ))
            NODE_OUT_SPEED["${nid}"]=$(( OUT_DELTA / ELAPSED ))
        done
        for nid in "${!CURR_IN_BYTES[@]}"; do
            PREV_IN_BYTES["${nid}"]=${CURR_IN_BYTES["${nid}"]}
            PREV_OUT_BYTES["${nid}"]=${CURR_OUT_BYTES["${nid}"]}
        done
    else
        CURR_RX=0; CURR_TX=0
        read -r CURR_RX CURR_TX <<< "$(read_iface_bytes "${ACTIVE_IFACE}")" || true
        RX_DELTA=$(( CURR_RX - PREV_RX )); [[ "${RX_DELTA}" -lt 0 ]] && RX_DELTA=0
        TX_DELTA=$(( CURR_TX - PREV_TX )); [[ "${TX_DELTA}" -lt 0 ]] && TX_DELTA=0
        IN_SPEED=$(( RX_DELTA / ELAPSED ))
        OUT_SPEED=$(( TX_DELTA / ELAPSED ))
        PREV_RX=${CURR_RX}; PREV_TX=${CURR_TX}
    fi

    read -r cu cn cs ci ciow cirq csirq cst <<< "$(read_cpu_jiffies)" || true
    CURR_TOTAL=$(( ${cu:-0}+${cn:-0}+${cs:-0}+${ci:-0}+${ciow:-0}+${cirq:-0}+${csirq:-0}+${cst:-0} ))
    CURR_IDLE=${ci:-0}
    DTOTAL=$(( CURR_TOTAL - PREV_TOTAL ))
    DIDLE=$(( CURR_IDLE  - PREV_IDLE  ))
    [[ "${DTOTAL}" -gt 0 ]] \
        && CPU=$(awk "BEGIN {printf \"%.1f\", (1-${DIDLE}/${DTOTAL})*100}") \
        || CPU="0.0"
    PREV_TOTAL=${CURR_TOTAL}; PREV_IDLE=${CURR_IDLE}

    MEM_TOTAL_KB=0; MEM_USED_KB=0
    read -r MEM_TOTAL_KB MEM_USED_KB <<< "$(read_mem_kb)" || true
    MEM_TOTAL=$(( MEM_TOTAL_KB * 1024 ))
    MEM_USED=$(( MEM_USED_KB  * 1024 ))

    echo "$(date '+%Y-%m-%d %H:%M:%S')  cpu=${CPU}%  mem=${MEM_USED}/${MEM_TOTAL}"

    for entry in "${NODE_ENTRIES[@]}"; do
        IFS='|' read -r h k nid itag port <<< "${entry}"
        if "${USE_IPTABLES}"; then
            node_in="${NODE_IN_SPEED[${nid}]:-0}"
            node_out="${NODE_OUT_SPEED[${nid}]:-0}"
            echo "  node_id=${nid}(port=${port})  in=${node_in}B/s out=${node_out}B/s"
        else
            node_in="${IN_SPEED}"
            node_out="${OUT_SPEED}"
        fi
        push_node "${h}" "${k}" "${nid}" "${node_in}" "${node_out}" "${CPU}" "${MEM_TOTAL}" "${MEM_USED}"
    done

    LAST_PUSH=${NOW}
done