[中文](./README.md) | [English](./README_EN.md)

[![ShellCheck](https://github.com/0xMetalee/awesome-claude-code-remote/actions/workflows/shellcheck.yml/badge.svg?branch=main)](https://github.com/0xMetalee/awesome-claude-code-remote/actions/workflows/shellcheck.yml)

# Keeping Claude Code Running — Remote Isolation and 24/7 Unattended Work on macOS (Year-End 2026 Edition)

I'm a developer in China who spends most days shipping code. Over the past six months, I've used Claude Code (CC) heavily for production work and lost three or four primary accounts to bans. The subscription money was gone, too. Getting a suspension notice halfway through a late-night coding session gets old fast.

After burning time on proxies, virtual cards, and shared accounts, I went all in. **I asked a friend on the US West Coast to buy a brand-new Mac mini locally and host it there, with an account set up locally and a real US credit card attached. From my computer in China, I connect to that machine over Tailscale and SSH.**

In my own testing, **physical device isolation, a local network and real credit card, and an unattended workstation running around the clock** have been the most reliable setup I've found. This guide and repository share the lessons I learned from account restrictions, along with the **IP auditing scripts and sleep-prevention watchdog** I use to keep that remote workstation running. If you have access to hardware overseas, you can build the same setup yourself. We also offer a hosted option for people who want the infrastructure handled for them. Feedback from fellow developers is welcome.

---

## Contents

- [1. The Problems I Hit Running CC Locally from China](#1-the-problems-i-hit-running-cc-locally-from-china)
- [2. My Hard-Learned Account Rules for 2026](#2-my-hard-learned-account-rules-for-2026)
- [3. Deployment and Unattended Operation](#3-deployment-and-unattended-operation)
  - [3.1 Connect over Tailscale](#31-connect-over-tailscale)
  - [3.2 Audit Your Egress IP and Time Zone with setup.sh](#32-audit-your-egress-ip-and-time-zone-with-setupsh)
  - [3.3 Run Persistent Tasks with watchdog.sh](#33-run-persistent-tasks-with-watchdogsh)
  - [3.4 Handle Permission Prompts Before Leaving a Task Unattended](#34-handle-permission-prompts-before-leaving-a-task-unattended)
  - [3.5 Stop a Session and Release Sleep Assertions with stop.sh](#35-stop-a-session-and-release-sleep-assertions-with-stopsh)
- [4. Everyday Troubleshooting](#4-everyday-troubleshooting)
- [Full troubleshooting guide (English)](./TROUBLESHOOTING_EN.md) · [排错指南（中文）](./TROUBLESHOOTING.md)
- [5. FAQ](#5-faq)
- [6. A Fully Managed Dedicated Workstation](#6-a-fully-managed-dedicated-workstation)
- [7. Feedback and Contact](#7-feedback-and-contact)

---

## 1. The Problems I Hit Running CC Locally from China

I used to run `claude` through a proxy on my everyday MacBook. Three problems kept coming up.

1. **Account restrictions were hard to predict.** Proxy exits could jump from the US West Coast to Japan overnight. Shared data-center ASNs and virtual-card chargebacks added more risk. In my experience, that combination triggered account reviews and US identity checks I couldn't complete.
2. **Closing the lid interrupted long jobs.** Refactoring dozens of files or running a full test suite can take an hour or two. Sleep or a Wi-Fi change could disconnect SSH and the terminal, interrupting the session and its working context.
3. **A highly privileged agent on my personal laptop felt risky.** Automated code changes and test runs need terminal access. Giving an agent broad permissions on a machine full of private keys, company source code, and personal files made me uncomfortable.

So I moved the whole environment. **My computer in China serves as the screen and keyboard. The repositories, runtime, and Claude Code all live on a dedicated physical Mac mini on the US West Coast, where the requests to Anthropic originate.**

---

## 2. My Hard-Learned Account Rules for 2026

My experience this year suggests that account risk involves **network ASNs, payment-card characteristics, device fingerprints, and request patterns** as well as IP addresses. Comparing the accounts I lost with the setup that has worked for me, these are the rules I now follow.

* **One machine and one account per person.** Shared commercial endpoints and shared accounts with concurrent IPs and device fingerprints have been especially troublesome. My preferred setup is **one dedicated physical machine overseas and one account**, with all work happening on that remote Mac.
* **Use a legitimate payment method.** I've seen virtual cards rejected or blocked by Stripe, with account restrictions following. For a DIY setup, **use a real personal credit card from a supported region** and keep its billing address consistent with the region where the remote machine is hosted.
* **Avoid cheap, pre-made accounts.** Bargain accounts sold on marketplaces such as Taobao or Xianyu may have been funded using stolen cards. A chargeback a month or two later can take the account down. If someone helps with a subscription, **use a person you trust or a reputable provider**.
* **Take it easy during the first 72 hours.** I treat the first three days of a new subscription as an observation period. I stick to normal interactive development—roughly a dozen or so exchanges a day—before trying unattended overnight batches.
* **Put a circuit breaker in the script.** A network failure or crash should never turn into a tight retry loop. Repeated automated requests can look like abusive traffic. The watchdog below therefore includes **a circuit breaker for repeated rapid failures**.

---

## 3. Deployment and Unattended Operation

Once you have a macOS machine hosted overseas, use the following steps to set up the unattended environment.

### 3.1 Connect over Tailscale

I use Tailscale to create an encrypted private network and reach the remote Mac over SSH or screen sharing. This keeps the SSH port off the public internet and has given me low connection latency from China.

```bash
brew install --cask tailscale
# Sign in to your Tailscale account and authorize the device after installation.
# From home or work, connect over SSH or screen sharing (VNC) using its 100.x.x.x address.
```

### 3.2 Audit Your Egress IP and Time Zone with setup.sh

I run this script whenever I provision a machine or change its network. It checks the egress IP's ASN and compares **the system time zone with the time zone reported for that IP**. I treat a mismatch as a risk signal. It also installs missing `tmux`, `Node.js`, and `claude` dependencies when the required package managers are available.

```bash
git clone https://github.com/0xMetalee/awesome-claude-code-remote.git && cd awesome-claude-code-remote
bash setup.sh
```

### 3.3 Run Persistent Tasks with watchdog.sh

This is the watchdog I use for persistent sessions. It starts `caffeinate -disu` to prevent sleep and runs the workload inside `tmux`. In interactive mode, an abnormal exit—anything other than `0` or the manual `Ctrl+C` exit code `130`—triggers a 20-second wait before restarting, using `--continue` when session history is available. **Three consecutive runs that each fail in under 15 seconds trip the circuit breaker and stop further restarts.** Batch mode exits its watchdog loop when the command finishes.

```bash
# Mode A: Start a persistent interactive session.
bash watchdog.sh ~/projects/your-repo claude-work

# Mode B: Hand off a task list before bed. @TASK.md is supported; the loop exits when the batch finishes.
bash watchdog.sh ~/projects/your-repo claude-batch @TASK.md
```

Useful commands for taking over a background session follow.

* **Detach and leave the job running.** Press `Ctrl + B`, release both keys, then press `D`. You can disconnect your client and leave the remote session running.
* **Reconnect to the session.** Run `tmux attach -t claude-work`.
* **Check the watchdog and circuit breaker.** Run `tail -f ~/.claude/logs/watchdog_claude-work.log`.

### 3.4 Handle Permission Prompts Before Leaving a Task Unattended

Claude Code can pause for approval before editing files or running commands. If you haven't configured permissions for an overnight run, it can sit at the first prompt until morning.

There are two approaches in my workflow.

1. **Set an explicit allowlist.** In the project's `.claude/settings.local.json`, allow the operations the task needs, such as `Bash(npm test:*)` and `Edit`. This is my recommended starting point.
2. **Use full permissions in an isolated environment.** My code runs on a **dedicated, isolated physical Mac mini on the US West Coast**, away from the personal data on my everyday computer. For overnight refactors there, I use `--dangerously-skip-permissions`.

   ```bash
   claude --dangerously-skip-permissions -p "Read TASK.md, implement the core modules, and run all unit tests. Create a Git commit after the tests pass."
   ```

### 3.5 Stop a Session and Release Sleep Assertions with stop.sh

Run this from another terminal on the host Mac. The script sends `Ctrl+C`, waits two seconds, closes the selected session, and removes `~/.claude/logs/.runner_<session-name>.sh`. It keeps the sleep-prevention process running while other tmux sessions or processes remain. After the final session ends, it stops the current user's `caffeinate -disu` process and releases its sleep assertions. You can run it again to clean up a runner left behind by a session that already stopped.

```bash
# Stop the default claude-work session.
bash stop.sh

# Stop a named session.
bash stop.sh claude-batch
```

---

## 4. Everyday Troubleshooting

**For 403, 429, SSH disconnects, permission blocks, and watchdog failures, follow the full troubleshooting guide.** [English guide](./TROUBLESHOOTING_EN.md) · [中文指南](./TROUBLESHOOTING.md)

These built-in commands help when a background job encounters a network interruption or expired authentication.

```bash
# Check authentication, configuration syntax, and environment health.
claude doctor

# Continue the most recent session in the current directory.
claude --continue

# Browse previous sessions and choose one to resume.
claude --resume
```

---

## 5. FAQ

**Can I use Claude Code remotely from China this way? What should I watch out for?**

> Writing code with the official CLI is an ordinary development use case. The account problems I've encountered have involved stolen-card payments, shared endpoints, and account reselling. **If you're unsure about your network, subscription setup, or remote isolation, reach out on WeChat. I'm happy to walk through what I've learned from my own mistakes.**

**Can I sign in to the same account on my phone and computer?**

> The same account can officially be used across devices, but avoid sending concurrent requests from multiple devices—for example, a remote machine running a heavy batch while you also chat in a local browser. The risk system can flag that as account sharing or scripted abuse.

**Can I recover an account after a US identity-verification check?**

> I wouldn't count on it. Friends and I have tried several times, and without local US identity and address documentation, we had little success. That's why I focus on the machine and network setup before something goes wrong.

---

## 6. A Fully Managed Dedicated Workstation

After my friend on the US West Coast helped me put together the physical machine, local account setup, and real-card subscription, other developers who had lost accounts asked for the same help. With procurement, hosting, and local subscription payments in place, we opened the service to others through WindFlame, starting at **$179 per month**. [WindFlame dedicated workstations](https://windflame.org/?ref=TBMW#register)

* **A dedicated physical machine for each customer.** A local friend purchases a **brand-new Mac mini** and arranges deployment after an order, with US and South Korean locations available. Each customer gets a dedicated host, avoiding the shared-neighbor problems of oversubscribed virtual machines.
* **Optional local credit-card subscription setup.** If you can't handle US card payments yourself, a plan with an official account includes a subscription paid with a real local card, addressing the virtual-card rejection problems described above.
* **A complete macOS desktop and SSH access.** The base environment comes installed. Connect over Tailscale, run this repository's `watchdog.sh` over SSH, or use screen sharing for a browser and Xcode builds.

We currently offer three configurations. Choose the one that matches your workload. [Register and check availability](https://windflame.org/?ref=TBMW#register)

| Plan | Monthly price | Included | Best suited to |
| :--- | :--- | :--- | :--- |
| **Basic — Dedicated Hardware** | **$179 / month** | Exclusive use of a brand-new physical Mac mini, power, and basic network support *(AI account excluded)* | Developers who already have a legitimate payment method and a stable account, and need a dedicated host overseas |
| **Standard — 5x Productivity** | **$419 / month** | Exclusive use of a brand-new physical Mac mini, an **official Claude 5x (Max) account**, and basic network support | Independent developers who code, refactor, and run scripts frequently and want the account and environment setup handled |
| **Premium — 10x Heavy Use** | **$539 / month** | Exclusive use of a brand-new physical Mac mini, an **official Claude 10x (Ultra) account**, and basic network support | Power users and studios running long unattended agent jobs, large-context projects, and high-volume workloads |

---

## 7. Feedback and Contact

I write code in China while friends on the US West Coast handle hardware procurement and operations. The time difference helps us cover both ends.

If you hit an error in the scripts, have ideas for account resilience or automation, or want us to set up a dedicated physical Mac mini workstation, get in touch. Issues and PRs are welcome. Scan the QR code below to add me on WeChat, or search for **agent2199**. Include **【CC工作站】** in your friend request so I can recognize it.

<div align="left">
  <img src="./wechat.png" alt="WeChat QR code" width="240" />
</div>
