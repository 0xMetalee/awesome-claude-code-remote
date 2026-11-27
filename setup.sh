#!/usr/bin/env bash
# ==============================================================================
# Author: 0xMetalee (WindFlame | https://windflame.org)
# Description: 我自用的 macOS 远程工作站环境初始化与出口 IP 纯净度审计脚本
# License: MIT
# ==============================================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC}  $1"; }

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}  Claude Code 远程工作站环境审计与初始化 (macOS Production)   ${NC}"
echo -e "${GREEN}==============================================================${NC}\n"

# 1. 出口 IP 纯净度、ASN 与时区一致性审计
log_info "[1/4] 正在审计出口 IP、ASN 归属及系统时区一致性..."
IP_JSON=$(curl -fsSL --max-time 8 https://ipinfo.io 2>/dev/null)

if [ -z "$IP_JSON" ]; then
    log_err "无法获取 ipinfo.io 数据，请检查当前网络出口连通性。"
else
    parse_json() {
        local key="$1"
        if command -v python3 >/dev/null 2>&1; then
            printf '%s' "$IP_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('$key', 'Unknown'))" 2>/dev/null
        else
            osascript -l JavaScript -e 'function run(argv) {
                try {
                    var d = JSON.parse(argv[0]);
                    return d[argv[1]] ? String(d[argv[1]]) : "Unknown";
                } catch (e) { return "Unknown"; }
            }' "$IP_JSON" "$key" 2>/dev/null
        fi
    }

    IP=$(parse_json "ip")
    CITY=$(parse_json "city")
    REGION=$(parse_json "region")
    COUNTRY=$(parse_json "country")
    ORG=$(parse_json "org")
    IP_TZ=$(parse_json "timezone")
    SYS_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##' || date +%Z)

    echo -e "   • 出口 IP 地址  : ${GREEN}${IP}${NC}"
    echo -e "   • 地理位置归属  : ${GREEN}${COUNTRY} / ${REGION} / ${CITY}${NC}"
    echo -e "   • 运营商 / ASN  : ${GREEN}${ORG}${NC}"
    echo -e "   • IP 归属地时区 : ${CYAN}${IP_TZ}${NC}"
    echo -e "   • 本机系统时区  : ${CYAN}${SYS_TZ}${NC}"

    if [ -n "$IP_TZ" ] && [ "$IP_TZ" != "Unknown" ] && [ "$IP_TZ" != "$SYS_TZ" ]; then
        log_warn "系统时区 (${SYS_TZ}) 与出口 IP 时区 (${IP_TZ}) 不一致！建议执行以下命令对齐以降低风控权重："
        echo -e "     ${YELLOW}sudo systemsetup -settimezone ${IP_TZ}${NC}"
    else
        log_ok "系统时区与出口 IP 归属地完全匹配。"
    fi
fi
echo ""

# 2. Anthropic API 网关 TLS 握手与延迟测试
log_info "[2/4] 正在测试 Anthropic 官方网关连通性..."
METRICS=$(curl -o /dev/null -s -w "%{http_code} %{time_namelookup} %{time_connect} %{time_total}" --max-time 10 https://anthropic.com 2>/dev/null)
HTTP_CODE=$(echo "$METRICS" | awk '{print $1}')
DNS_TIME=$(echo "$METRICS" | awk '{print $2}')
TOTAL_TIME=$(echo "$METRICS" | awk '{print $4}')

if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
    log_ok "网关连通正常 (HTTP ${HTTP_CODE}) | DNS: ${DNS_TIME}s | 总延迟: ${TOTAL_TIME}s"
else
    log_err "无法连接 https://anthropic.com，请检查网络路由或代理设置。"
fi
echo ""

# 3. 基础依赖审计与安装 (Homebrew, tmux, Node.js)
log_info "[3/4] 正在检查基础运行依赖 (Homebrew / tmux / Node.js)..."
if ! command -v brew >/dev/null 2>&1; then
    log_warn "未检测到 Homebrew，跳过自动包管理安装。建议手动安装: https://brew.sh"
else
    if ! command -v tmux >/dev/null 2>&1; then
        log_info "正在通过 Homebrew 安装 tmux..."
        brew install tmux
    else
        log_ok "tmux 已就绪: $(tmux -V)"
    fi

    if ! command -v node >/dev/null 2>&1; then
        log_info "正在通过 Homebrew 安装 Node.js..."
        brew install node
    else
        log_ok "Node.js 已就绪: $(node -v)"
    fi
fi
echo ""

# 4. Claude Code CLI 安装与健康检查
log_info "[4/4] 正在检查 Claude Code CLI 状态..."
if ! command -v claude >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
        log_info "正在全局安装 @anthropic-ai/claude-code..."
        if npm install -g @anthropic-ai/claude-code; then
            log_ok "Claude Code CLI 安装成功: $(claude --version 2>/dev/null)"
        else
            log_err "npm 全局安装失败（可能是目录权限问题），请尝试修复 npm prefix 或执行 sudo npm install -g @anthropic-ai/claude-code"
        fi
    else
        log_err "未检测到 npm，无法自动安装 Claude Code CLI。"
    fi
else
    log_ok "Claude Code CLI 已就绪: $(claude --version 2>/dev/null)"
fi

echo -e "\n${GREEN}==============================================================${NC}"
echo -e "${GREEN}✅ 环境审计完毕！下一步建议：${NC}"
echo -e "   1. 运行 ${YELLOW}claude${NC} 完成账号首次授权（新号前 72h 观察期请保持常规交互节奏）。"
echo -e "   2. 运行 ${YELLOW}bash watchdog.sh /path/to/project${NC} 开启防休眠持久化工作站。"
echo -e "${GREEN}==============================================================${NC}"
