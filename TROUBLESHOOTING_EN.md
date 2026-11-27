[中文](./TROUBLESHOOTING.md) | [English](./TROUBLESHOOTING_EN.md) | [返回主页 / Back to Home](./README_EN.md)

# Claude Code Remote Troubleshooting Guide (2026)

I write production code from China and run the jobs on a remote Mac mini. When something breaks at night, I check the error, the session, then the logs. These notes cover HTTP 403, 429, SSH disconnects, permission blocks, and watchdog failures, with concrete network checks for account-risk troubleshooting.

Checked on 2026-11-27. Run these commands on the remote host Mac using this repository's `setup.sh`, `watchdog.sh`, and `stop.sh`. Start in this repository's root directory and set the paths in the same terminal. At the prompt, enter the absolute path to your actual project.

```bash
repo_dir="$(pwd -P)"
printf 'Project directory: '
IFS= read -r project_dir
test -f "$repo_dir/watchdog.sh" && test -d "$project_dir"
claude --version
sw_vers
```

The path check should succeed. Fix the paths first if it fails. Your project and these operations scripts can live in different directories.

## Contents

- [HTTP 403 Forbidden, Account Restrictions, and US KYC](#http-403-forbidden-account-restrictions-and-us-kyc)
- [HTTP 429 Rate Limit, Five-Hour Usage Windows, and Long Tasks](#http-429-rate-limit-five-hour-usage-windows-and-long-tasks)
- [SSH Disconnects, tmux Recovery, and Session History](#ssh-disconnects-tmux-recovery-and-session-history)
- [Unattended Permission Blocks and a JSON Allowlist](#unattended-permission-blocks-and-a-json-allowlist)
- [Repeated Fast Failures and the Watchdog Circuit Breaker](#repeated-fast-failures-and-the-watchdog-circuit-breaker)

## HTTP 403 Forbidden, Account Restrictions, and US KYC

I save the full error, timestamp, and request ID, then check the account and organization in use. For a 403, I investigate resource permissions, organization settings, and the proxy path. For an account suspension or verification notice, I follow the notice. [Official troubleshooting](https://code.claude.com/docs/en/troubleshooting) · [API errors](https://platform.claude.com/docs/en/api/errors)

```bash
cd "$repo_dir" || exit 1
bash setup.sh
claude auth status
readlink /etc/localtime
date '+%Y-%m-%d %H:%M:%S %Z %z'
curl -fsS --max-time 10 https://ipinfo.io/json | python3 -m json.tool
```

`setup.sh` reports the IP, city, operator/ASN, and both time zones. It also attempts to install missing tmux, Node.js, and Claude Code dependencies. I check whether `org` matches the actual connection and compare the IP's `timezone` with the system setting. Geolocation databases can be inaccurate, so I record differences and check the hosting location and macOS time settings. ASN and time-zone checks help identify environment changes. The official account page determines whether verification is required.

When a local proxy, remote terminal, and browser are all involved, I inspect their proxy settings and the account signed in on each. This command prints only whether each environment variable is set, which helps spot leftover configuration.

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

I compare this output on my local and remote Macs, then inspect browser proxy extensions, system proxy settings, and account pages. Terminal curl and a browser can use different configurations. Once the route and credentials are clear, I reproduce the failure once in the chosen remote environment and keep the result for the administrator or support team.

For a US KYC or identity-verification prompt, I start from the official Claude page and use my own genuine information. The page specifies the required documents. The official guidance includes a valid government-issued photo ID, and some flows request a live selfie. Network and time-zone findings can help support investigate, while account review remains with the provider. [Identity verification](https://support.claude.com/en/articles/14328960-identity-verification-on-claude)

## HTTP 429 Rate Limit, Five-Hour Usage Windows, and Long Tasks

I first open the account's Usage page and check the current window and reset time. Most subscriptions have a five-hour session allowance starting with the first message and resetting in full at the end of that window. Weekly limits can also apply. The account page has the applicable limits, and usage is shared across Claude clients. [Usage limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)

For an API 429, I inspect the rate, spending-limit, and organization details in the error. I honor `retry-after` when present and address an exhausted spending limit before retrying. I bound retries to keep several layers of automation from multiplying them. [API 429 and retries](https://platform.claude.com/docs/en/api/errors)

I split a large `TASK.md` into independently verifiable phases. Each gets an objective, permitted files, test commands, and a stopping condition. This creates a uniquely named task directory inside the project, saves the original requirements, and writes the first phase.

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

After reviewing the files in `task_dir`, I run one phase at a time. If `claude-batch` already exists, I attach and check its work first. Once that work is finished, I stop the session before reusing its name.

```bash
bash "$repo_dir/watchdog.sh" "$project_dir" claude-batch "@$task_dir/01-plan.md"
tmux attach -t '=claude-batch'
```

I review phase one before preparing implementation and testing phases. When the allowance is exhausted, I stop the corresponding automated job and wait until the Usage page shows availability. The current script executes a batch once. Before rerunning it, I check the logs, `git diff`, and generated files to see where the previous attempt stopped.

## SSH Disconnects, tmux Recovery, and Session History

After reconnecting over SSH, I look for the original session. tmux preserves terminal processes on the server, and the host itself needs to stay running. After a reboot or host sleep, I check the process state too.

```bash
tmux list-sessions
tmux list-panes -a -F '#{session_name} #{pane_id} #{pane_current_path} #{pane_current_command}'
tmux attach -t '=claude-work'
```

To detach, press `Ctrl+B`, release the keys, then press `D`. If Claude has exited, I return to the original project directory and choose one of these commands. `--continue` restores the latest session for that directory; `--resume` opens the picker. [Session recovery](https://code.claude.com/docs/en/sessions)

```bash
cd "$project_dir" || exit 1
claude --continue
```

```bash
cd "$project_dir" || exit 1
claude --resume
```

To locate history files, I list `.jsonl` files under the default `~/.claude/projects/` directory by modification time. This also respects `CLAUDE_CONFIG_DIR`. Filenames usually contain the session ID, which can be passed to `claude --resume`. I preserve the files and use the picker to check the project and conversation. [Transcript storage](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored)

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

## Unattended Permission Blocks and a JSON Allowlist

When a job appears stuck, I attach to tmux and read the last screen. An interactive session may be waiting for approval; a `-p` batch may deny an unapproved tool call immediately. I check the project configuration, open an interactive session with `claude`, and run `/permissions` to inspect the effective rules.

This is my starting configuration for file operations in `src`, `tests`, and `docs`, plus three exact test commands. `Edit` path rules also cover the built-in Write tool. Adjust the directories for your project and retain existing restrictions. [Permission rules](https://code.claude.com/docs/en/permissions)

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

I back up the local settings before editing, merge the example into `.claude/settings.local.json`, and validate the JSON. The file uses strict JSON, so comments and trailing commas cause syntax errors. [Settings files](https://code.claude.com/docs/en/settings)

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

Test commands execute project code, so I review `package.json` and the test entry points first. Application permission rules have limits when scripts access files indirectly. For OS-level isolation, I also use a sandbox or dedicated system user. [File-rule boundaries](https://code.claude.com/docs/en/permissions#what-read-and-edit-rules-cover)

I consider `--dangerously-skip-permissions` only on a dedicated, recoverable remote Mac mini, with an unprivileged user, narrowly scoped credentials, and trusted tasks. I remove personal data, production secrets, and shared mounts, and keep a recoverable code baseline. Dedicated hardware still needs those boundaries configured. The flag skips permission prompts. [Permission modes](https://code.claude.com/docs/en/permissions#permission-modes)

```bash
cd "$project_dir" || exit 1
claude --dangerously-skip-permissions -p "Read TASK.md, complete only the approved scope, run the specified tests, and stop with a summary."
```

This runs Claude directly. The current `watchdog.sh` treats its entire third argument as prompt text, so I run the command above separately when using this mode.

## Repeated Fast Failures and the Watchdog Circuit Breaker

When I see “连续失败 3/3” or “触发安全熔断,” I read the logs first. In the current interactive watchdog, three consecutive abnormal runs lasting under 15 seconds each trip the breaker, with 20 seconds between retries. Exit codes `0` and `130` end the loop. A run lasting at least 15 seconds resets the fast-failure count. Batch mode exits its loop after one execution. [Current script](./watchdog.sh)

```bash
claude doctor
bash -c 'shopt -s nullglob; logs=("$HOME"/.claude/logs/watchdog_*.log); if ((${#logs[@]})); then tail -n 50 "${logs[@]}"; else echo "No watchdog logs found."; fi'
tmux list-sessions
```

With matching logs present, `tail -n 50 ~/.claude/logs/watchdog_*.log` also works. The version above handles missing files under macOS's default zsh. Watchdog logs mainly record starts, exit codes, and retries. For the underlying API or program error, I also inspect the terminal output retained in tmux.

```bash
tmux capture-pane -p -S -200 -t '=claude-work:'
curl -I --connect-timeout 5 --max-time 15 https://api.anthropic.com
claude auth status
```

curl checks DNS, TLS, and the HTTP response. I still verify authentication and an actual request through Claude. I fix PATH, configuration, login, or network issues first, and handle 429s using the usage checks above. Then, from **another SSH terminal**, I stop the old session and confirm it has disappeared before restarting it.

```bash
bash "$repo_dir/stop.sh" claude-work
tmux list-sessions
```

If `claude-work` is still listed, I investigate the failed stop first. When all sessions have ended, `tmux list-sessions` reports that the server is no longer running. Once network and account checks pass, I restart with these commands.

```bash
bash "$repo_dir/watchdog.sh" "$project_dir" claude-work
tmux attach -t '=claude-work'
```

I verify one small task before resuming a long job. `watchdog.sh` reuses an existing session, so after a breaker trip I stop the old session to allow a fresh runner to start.

---

I've also turned the remote-host procurement and operations setup into my own overseas dedicated physical Mac mini hosting service. The actual configurations are available here. [WindFlame](https://windflame.org/?ref=TBMW#register)

For script errors, open an Issue or add me on WeChat at `agent2199`. Include **【CC工作站】** in the request, along with a redacted error and steps to reproduce it.

<div align="left">
  <img src="./wechat.png" alt="WeChat QR code" width="240" />
</div>
