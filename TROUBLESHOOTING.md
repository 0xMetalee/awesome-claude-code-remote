[中文](./TROUBLESHOOTING.md) | [English](./TROUBLESHOOTING_EN.md) | [返回主页 / Back to Home](./README.md)

# Claude Code 远程运行排错指南（2026）

我在国内写业务代码，远程 Mac mini 负责跑任务。半夜出错时，我按报错、会话、日志这个顺序查。这份笔记覆盖 HTTP 403、429、SSH 断连、权限阻塞和 watchdog 熔断，也把“防封”相关的网络自查落到具体命令上。

核对日期为 2026-11-27。下面的命令在远程宿主 Mac 上运行，默认使用本仓库的 `setup.sh`、`watchdog.sh` 和 `stop.sh`。先进入本仓库根目录，在同一个终端设置路径；提示时输入实际业务项目的绝对路径。

```bash
repo_dir="$(pwd -P)"
printf 'Project directory: '
IFS= read -r project_dir
test -f "$repo_dir/watchdog.sh" && test -d "$project_dir"
claude --version
sw_vers
```

最后的路径检查应成功；失败时先修正路径。项目目录和运维脚本目录可以分开。

## 目录

- [HTTP 403 Forbidden、账号风控与美区 KYC](#http-403-forbidden账号风控与美区-kyc)
- [HTTP 429 Rate Limit、5 小时额度与长任务](#http-429-rate-limit5-小时额度与长任务)
- [SSH 断连、tmux 恢复与上下文定位](#ssh-断连tmux-恢复与上下文定位)
- [无人值守权限阻塞与 JSON 白名单](#无人值守权限阻塞与-json-白名单)
- [连续快速崩溃与 watchdog 安全熔断](#连续快速崩溃与-watchdog-安全熔断)

## HTTP 403 Forbidden、账号风控与美区 KYC

我先保存完整错误文本、时间和 request ID，再确认正在用的账号及组织。403 的排查入口包括资源权限、组织配置和代理链路；账号停用或验证通知则按通知处理。[官方排错入口](https://code.claude.com/docs/en/troubleshooting) · [API 错误说明](https://platform.claude.com/docs/en/api/errors)

```bash
cd "$repo_dir" || exit 1
bash setup.sh
claude auth status
readlink /etc/localtime
date '+%Y-%m-%d %H:%M:%S %Z %z'
curl -fsS --max-time 10 https://ipinfo.io/json | python3 -m json.tool
```

`setup.sh` 会输出 IP、城市、运营商/ASN 和两边时区，也会尝试安装缺少的 tmux、Node.js、Claude Code。我看 `org` 是否符合实际线路，比较 IP 的 `timezone` 与系统时区。地理库可能有偏差，记录差异后再核实机房位置和 macOS 时间设置。ASN 和时区用于定位环境变化，账号是否需要验证以官方页面为准。

排查本地代理、远程终端、浏览器混用时，我先看代理配置，再核对各端登录的账号。下面只输出环境变量是否设置，方便检查遗留配置。

```bash
scutil --proxy
python3 - <<'PY'
import os
names = (
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN',
)
for name in names:
    print(f"{name}={'set' if os.environ.get(name) else 'unset'}")
PY
```

我会在本地 Mac 和远程 Mac 分别核对这段输出，并查看浏览器的代理扩展、系统代理和账号页面。终端 curl 与浏览器可能走不同配置。确认线路和凭据后，我在选定的远程环境复现一次，保留结果给管理员或支持人员。

遇到“美区 KYC”或 identity verification 提示，我从官方 Claude 页面进入验证流程，使用本人真实资料。验证所需材料以页面为准，官方说明包括有效政府签发的照片证件，部分流程会要求实时自拍。调整时区或更换网络的诊断结果可以提供给支持人员，账号审核仍由官方处理。[身份验证说明](https://support.claude.com/en/articles/14328960-identity-verification-on-claude)

## HTTP 429 Rate Limit、5 小时额度与长任务

我先打开账号的 Usage 页面，核对当前窗口和重置时间。多数订阅有五小时会话额度，窗口从首次消息开始计时，到期整体重置；周额度也可能同时生效，具体以账号页面为准。不同 Claude 客户端共享用量。[额度说明](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)

API 调用出现 429 时，我检查错误中的速率、支出上限和组织信息。有 `retry-after` 就按它等待；达到支出上限时先处理额度。重试设次数上限，避免多层自动重试叠加。[API 429 与重试说明](https://platform.claude.com/docs/en/api/errors)

我把大 `TASK.md` 拆成能单独验收的阶段，每阶段写清目标、允许修改的文件、测试命令和停止条件。下面在项目中生成唯一命名的任务目录，保留原始需求，再写第一阶段。

```bash
cd "$project_dir" || exit 1
task_dir="$(mktemp -d ./tasks.XXXXXX)"
cp TASK.md "$task_dir/TASK.original.md"
cat > "$task_dir/01-plan.md" <<'TASK'
# Phase 1 — Plan
Read TASK.original.md beside this file.
Inspect the relevant source files and list the smallest implementation steps.
Write acceptance criteria and test commands for each step.
Save the plan as PLAN.md beside this file, then stop for review.
TASK
printf 'Task directory: %s\n' "$task_dir"
tmux list-sessions
```

确认 `task_dir` 中的内容后，我一次只启动一个阶段。若 `claude-batch` 已存在，先接入它确认任务状态，已有任务完成后再停止并复用该名字。

```bash
bash "$repo_dir/watchdog.sh" "$project_dir" claude-batch "@$task_dir/01-plan.md"
tmux attach -t '=claude-batch'
```

我在验收第一阶段后才准备实现、测试等后续文件。额度耗尽时先停掉对应自动任务，等 Usage 页面显示可用后再启动。当前脚本的批处理是单次执行，重跑前先看日志、`git diff` 和实际产物，确认上次做到哪一步。

## SSH 断连、tmux 恢复与上下文定位

SSH 重新连上远程 Mac 后，我先找原会话。`tmux` 能保住服务器上的终端进程，远程主机本身需要保持运行；重启或宿主机休眠后还要检查进程状态。

```bash
tmux list-sessions
tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_current_path} #{pane_current_command}'
tmux attach -t '=claude-work'
```

暂离时按 `Ctrl+B`，松开再按 `D`。如果 Claude 已退出，我回到原项目目录，从下面两条命令中选一条。`--continue` 恢复当前目录最近一次会话，`--resume` 打开选择器。[会话恢复说明](https://code.claude.com/docs/en/sessions)

```bash
cd "$project_dir" || exit 1
claude --continue
```

```bash
cd "$project_dir" || exit 1
claude --resume
```

需要定位历史文件时，我按修改时间查看默认 `~/.claude/projects/` 下的 `.jsonl`。下面也兼容 `CLAUDE_CONFIG_DIR`。文件名通常包含会话 ID，选定后可交给 `claude --resume`。我保留原文件，用选择器核对项目和对话内容。[历史文件位置](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored)

```bash
python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'projects'
files = sorted(root.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)
for path in files[:20]:
    print(path)
PY
```

## 无人值守权限阻塞与 JSON 白名单

任务看起来“挂住”时，我先接入 tmux 看最后一屏。交互会话可能停在授权提示；`-p` 批处理也可能直接拒绝未授权的工具调用。先在项目目录检查配置，再用 `claude` 打开交互会话，运行 `/permissions` 核对实际生效规则。

下面是我的最小起步示例，允许 `src`、`tests`、`docs` 的常见文件操作和三条明确的测试命令。`Edit` 路径规则也覆盖内置 Write 工具。按项目实际目录调整，并保留已有的限制规则。[权限规则说明](https://code.claude.com/docs/en/permissions)

```json
{
  "permissions": {
    "allow": [
      "Read(/src/**)",
      "Read(/tests/**)",
      "Read(/docs/**)",
      "Edit(/src/**)",
      "Edit(/tests/**)",
      "Edit(/docs/**)",
      "Bash(npm test)",
      "Bash(npm run lint)",
      "Bash(python3 -m pytest)"
    ],
    "deny": [
      "Read(/**/.env*)",
      "Edit(/**/.env*)",
      "Read(/secrets/**)",
      "Edit(/secrets/**)"
    ]
  }
}
```

我先备份再编辑，把示例合并到 `.claude/settings.local.json`，随后校验 JSON。此文件使用严格 JSON，注释和尾随逗号都会导致语法错误。[配置文件说明](https://code.claude.com/docs/en/settings)

```bash
cd "$project_dir" || exit 1
mkdir -p .claude
if [ -f .claude/settings.local.json ]; then
    backup_file="$(mktemp .claude/settings.local.json.backup.XXXXXX)"
    cp .claude/settings.local.json "$backup_file"
fi
nano .claude/settings.local.json
python3 -m json.tool .claude/settings.local.json >/dev/null
claude doctor
```

测试命令会执行项目代码，我会先审查 `package.json` 和测试入口。应用层权限规则对间接读取文件的脚本有边界，涉及系统级隔离时还要配合沙箱或专用系统用户。[文件规则边界](https://code.claude.com/docs/en/permissions#what-read-and-edit-rules-cover)

我只在专用、可恢复的远程物理 Mac mini 上考虑 `--dangerously-skip-permissions`，使用低权限用户、最小范围凭据和可信任务，清理个人数据、生产密钥与共享挂载，并保留可回滚代码。拥有独立硬件后仍要配置这些边界；该参数会跳过权限提示。[权限模式说明](https://code.claude.com/docs/en/permissions#permission-modes)

```bash
cd "$project_dir" || exit 1
claude --dangerously-skip-permissions -p "Read TASK.md, complete only the approved scope, run the specified tests, and stop with a summary."
```

这条命令直接运行 Claude。当前 `watchdog.sh` 的第三个参数整体作为任务文本传入，使用上述模式时单独执行这条命令。

## 连续快速崩溃与 watchdog 安全熔断

看到“连续失败 3/3”或“触发安全熔断”，我先读日志。当前交互守护的条件是连续三次运行各不足 15 秒、退出码均异常，两次重试之间各等 20 秒。退出码 `0`、`130` 会结束循环；一次运行达到 15 秒会重置快速失败计数。批处理模式运行一次后退出循环。[当前脚本](./watchdog.sh)

```bash
claude doctor
bash -c 'shopt -s nullglob; logs=("$HOME"/.claude/logs/watchdog_*.log); if ((${#logs[@]})); then tail -n 50 "${logs[@]}"; else echo "No watchdog logs found."; fi'
tmux list-sessions
```

有日志时也可以直接运行 `tail -n 50 ~/.claude/logs/watchdog_*.log`。上面的写法兼容 macOS 默认 zsh 在没有匹配文件时的处理。watchdog 日志主要记录启动、退出码和重试；具体 API 或程序错误还要看 tmux 留下的终端输出。

```bash
tmux capture-pane -p -S -200 -t '=claude-work:'
curl -I --connect-timeout 5 --max-time 15 https://api.anthropic.com
claude auth status
```

curl 用于检查 DNS、TLS 和 HTTP 响应；认证与实际请求仍要用 Claude 验证。我先处理 PATH、配置、登录或网络问题；遇到 429 按前面的额度步骤等待。然后在**另一个 SSH 终端**停掉旧会话，确认旧会话消失，再重新拉起。

```bash
bash "$repo_dir/stop.sh" claude-work
tmux list-sessions
```

如果还显示 `claude-work`，先处理停止失败的原因。全部会话结束时，`tmux list-sessions` 会提示服务器未运行。网络和账号检查正常后再执行下面的启动命令。

```bash
bash "$repo_dir/watchdog.sh" "$project_dir" claude-work
tmux attach -t '=claude-work'
```

我先做一次小任务验证，再恢复长任务。`watchdog.sh` 对已存在的会话只会复用，熔断后先停止旧会话才能启动新的 runner。

---

我把远程宿主机的采购和运维整理成了自己的海外独享物理 Mac mini 托管方案，有需要可以看实际配置。[WindFlame](https://windflame.org/?ref=TBMW#register)

脚本报错欢迎提 Issue，也可以加我微信 `agent2199`，备注 **【CC工作站】**，带上脱敏后的错误和复现步骤。

<div align="left">
  <img src="./wechat.png" alt="微信二维码" width="240" />
</div>
