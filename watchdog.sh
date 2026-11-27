#!/usr/bin/env bash
# ==============================================================================
# Author: 0xMetalee | https://windflame.org/?ref=TBMW#register
# Description: 我自用的 macOS 7×24 小时 Claude Code 无人值守守护脚本（防休眠 + 断线续跑 + 风控熔断）
# Usage:
#   交互保活模式: bash watchdog.sh [项目目录] [会话名]
#   无人批跑模式: bash watchdog.sh [项目目录] [会话名] "任务指令 或 @TASK.md"
# ==============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"

PROJECT_DIR="${1:-$(pwd)}"
RAW_SESSION="${2:-claude-work}"
TASK_PROMPT="${3:-}"

if [[ "$RAW_SESSION" == *$'\n'* || "$RAW_SESSION" == *$'\r'* ]]; then
    echo "❌ 会话名不能包含换行。" >&2
    exit 1
fi

SESSION_NAME=$(printf '%s' "$RAW_SESSION" | tr '.:/' '---')
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/watchdog_${SESSION_NAME}.log"

# 1. 前置依赖检查
for cmd in tmux claude caffeinate; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ 缺少必要依赖: $cmd，请先运行 bash setup.sh 完成环境初始化。"
        exit 1
    fi
done

# 2. 校验项目目录并转换为规范绝对路径
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ 错误：目标项目目录不存在 -> $PROJECT_DIR"
    exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
mkdir -p "$LOG_DIR"
# Serialize startup and shutdown. Close this descriptor in persistent children.
exec 9>"$LOG_DIR/.lifecycle.lock"
/usr/bin/lockf -t 10 9 || exit 1

echo "🛡️  正在初始化 Claude Code 持久化运行环境..."
echo "   • 项目路径 : $PROJECT_DIR"
echo "   • 会话名称 : $SESSION_NAME"
echo "   • 运行模式 : $([ -n "$TASK_PROMPT" ] && echo "无人值守批处理 (-p)" || echo "交互式持久化保活")"
echo "   • 守护日志 : $LOG_FILE"

# 3. 启动 macOS 防休眠守护（防止合盖或空闲导致网络断开）
if ! pgrep -u "$(id -u)" -f '(^|/)caffeinate -disu$' >/dev/null 2>&1; then
    nohup caffeinate -disu >/dev/null 2>&1 9>&- &
    echo "✅ 已激活系统级防休眠守护 (caffeinate PID: $!)"
else
    echo "✅ 系统级防休眠守护已在运行中"
fi

# 4. 生成内部安全拉起脚本（注入 Apple Silicon PATH + SIGINT 识别 + 风控熔断器）
RUNNER_SCRIPT="$LOG_DIR/.runner_${SESSION_NAME}.sh"
cat > "$RUNNER_SCRIPT" << 'EOF'
#!/usr/bin/env bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.npm-global/bin:$PATH"

PROJECT_DIR="$1"
LOG_FILE="$2"
TASK_PROMPT="$3"

cd "$PROJECT_DIR" || exit 1

FAIL_COUNT=0
MAX_FAST_FAILS=3

while true; do
    START_TS=$(date +%s)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动 Claude Code 进程..." | tee -a "$LOG_FILE"

    if [ -n "$TASK_PROMPT" ]; then
        if [[ "$TASK_PROMPT" == @* ]] && [ -f "${TASK_PROMPT#@}" ]; then
            PROMPT_CONTENT=$(cat "${TASK_PROMPT#@}")
            claude -p "$PROMPT_CONTENT"
        else
            claude -p "$TASK_PROMPT"
        fi
        EXIT_CODE=$?
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 批处理任务执行完毕 (Exit Code: $EXIT_CODE)，已退出守护循环。" | tee -a "$LOG_FILE"
        break
    else
        PROJ_SLUG=$(printf '%s' "$PROJECT_DIR" | sed 's/[^a-zA-Z0-9]/-/g')
        HAS_HISTORY=$(find "$HOME/.claude/projects" -maxdepth 2 -path "*${PROJ_SLUG}*" -name "*.jsonl" 2>/dev/null | head -n 1)

        if [ -n "$HAS_HISTORY" ]; then
            claude --continue
        else
            claude
        fi
        EXIT_CODE=$?
    fi

    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))

    if [ "$EXIT_CODE" -eq 0 ] || [ "$EXIT_CODE" -eq 130 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 会话已人为正常退出 (Exit Code: $EXIT_CODE)，终止自动重启。" | tee -a "$LOG_FILE"
        break
    fi

    if [ "$DURATION" -lt 15 ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 警告：进程在 ${DURATION}s 内异常退出 (连续失败 ${FAIL_COUNT}/${MAX_FAST_FAILS} 次)" | tee -a "$LOG_FILE"
        if [ "$FAIL_COUNT" -ge "$MAX_FAST_FAILS" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🚨 触发安全熔断：短时间内连续异常退出，停止拉起以保护账号安全！请运行 claude doctor 排查。" | tee -a "$LOG_FILE"
            break
        fi
    else
        FAIL_COUNT=0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检测到异常中断 (Exit Code: $EXIT_CODE)，等待 20 秒后安全恢复..." | tee -a "$LOG_FILE"
    sleep 20
done
EOF

chmod +x "$RUNNER_SCRIPT"

# 5. 启动或复用 tmux 后台会话
if ! tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
    tmux new-session -d -s "$SESSION_NAME" -c "$PROJECT_DIR" 9>&-
    SAFE_CMD=$(printf 'bash %q %q %q %q' "$RUNNER_SCRIPT" "$PROJECT_DIR" "$LOG_FILE" "$TASK_PROMPT")
    tmux send-keys -t "=$SESSION_NAME:" "$SAFE_CMD" C-m
    echo "✅ 已创建全新后台会话: $SESSION_NAME"
else
    echo "ℹ️  会话 [$SESSION_NAME] 已存在，直接接入现有运行环境"
fi

echo ""
echo "=============================================================="
echo "🎉 7×24 小时持久化工作站已就绪！常用运维指令："
echo "   • 接入实时交互画面   : tmux attach -t $SESSION_NAME"
echo "   • 挂起画面(后台继续) : 先按 Ctrl+B，松开后再按 D"
echo "   • 查看守护运行日志   : tail -f $LOG_FILE"
echo "   • 彻底销毁后台会话   : bash stop.sh $SESSION_NAME"
echo "=============================================================="
