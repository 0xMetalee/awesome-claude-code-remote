# Unattended refactoring task / 无人值守重构任务书

Copy this file to `TASK.md` in your project and replace every `<...>` placeholder.
把本文件复制到业务项目的 `TASK.md`，逐项填写；存在未填写项时停止，不猜测需求。

## Objective / 任务目标

- Refactor `<module/function>` to `<specific maintainability improvement>`.
- Preserve public APIs and observable behavior, including error handling.
- Deliver `<specific files/behavior>`; keep this task small enough for one review.
- Business context and current issue: `<context and reproduction steps>`.

## Preflight / 启动前检查

1. Read the repository's `AGENTS.md`, `CLAUDE.md`, contribution rules and relevant tests.
2. Run `git status --short`. Stop if unrelated changes exist; never discard them.
3. Confirm the working branch is `<dedicated task branch>`, not `main` or `master`.
4. Run baseline tests with `<exact test command>`. Record failures before editing.
5. Check that the required tools are permitted. If permission or credentials are missing,
   stop with a clear blocker; do not bypass the approval or retry repeatedly.

## Scope and constraints / 约束边界

- Allowed paths: `<explicit source paths>`, `<explicit test paths>`.
- Allowed behavior changes: none, unless explicitly listed here: `<none or approved changes>`.
- Do not upgrade dependencies, alter lockfiles, change secrets, migrate production data,
  deploy, publish, or push commits.
- Do not change tests merely to hide failures. No blanket exception handling or silent fallbacks.
- Do not read personal directories, production credentials, or unrelated repositories.
- Do not use destructive Git commands or remove someone else's work.
- Stop if scope becomes ambiguous, the baseline fails, access is denied, or usage limits are reached.

## Implementation plan / 执行顺序

1. Explain the existing behavior and name the tests that protect it.
2. Make the smallest refactor inside the allowed paths.
3. Add regression tests for `<normal case>`, `<boundary case>`, and `<failure case>`.
4. Run the acceptance checks below. Investigate failures only within the approved scope.
5. Review the final diff for accidental formatting changes, secrets and unrelated edits.

## Acceptance criteria / 单测验收标准

- [ ] Baseline command `<exact command>` passed before changes, or a blocker was reported.
- [ ] Unit tests `<exact command>` pass, with relevant test names and exit codes recorded.
- [ ] Lint / type checks `<exact commands, or explicitly N/A>` pass.
- [ ] Public API and error behavior remain compatible.
- [ ] No skipped or weakened tests, dependency upgrades, or out-of-scope changes.
- [ ] `git diff --check` passes.
- [ ] Test claims match commands actually run; unrun checks are explicitly marked.

## Git commit policy / Git Commit 规范

- Permission to create a local commit: `<yes/no; default no>`.
- If permission is `no`, leave changes for human review and propose a commit message.
- If permission is `yes`, commit only after every required check passes and the tool is authorized.
  Stage explicit approved paths, never `git add .`; inspect the staged diff before committing.
- Commit subject: `refactor(<scope>): <specific improvement>`; use `test(<scope>): ...`
  only when the change is solely tests. Follow the project's convention if different.
- Commit body: summarize the behavior preserved and the checks actually run.
- One focused commit; do not amend unrelated history. Never push, open a PR or merge automatically.
- If commit approval is unavailable, leave the verified diff and state that no commit was created.

## Morning handoff / 醒来验收

Report the following, then stop:

1. What changed and why, with a file list.
2. Test commands, results and exit codes; baseline vs. newly introduced failures.
3. Remaining risks, blockers and checks not run.
4. `git status --short`, diff summary, and commit SHA if a commit was explicitly authorized.
5. The next action for the human reviewer. Do not claim completion when acceptance failed.

## Running with watchdog.sh / 配合守护脚本

Run from the operations repository after filling this template in your business project:

```bash
repo_dir="$(pwd -P)"
printf 'Project directory: '
IFS= read -r project_dir
test -f "$repo_dir/watchdog.sh" && test -f "$project_dir/TASK.md" || exit 1
bash "$repo_dir/watchdog.sh" "$project_dir" claude-batch '@TASK.md'
tmux attach -t '=claude-batch'
```

Detach with Ctrl+B, then D. Batch mode runs `claude -p` once and exits its loop even
when that invocation fails; it does not automatically retry or wait for quota resets.
The third watchdog argument is task text or an `@file`, not a CLI permission flag.
Before leaving it unattended, verify a small task and inspect `/permissions` interactively.

批处理只执行一次，失败后先检查日志与产物，再决定是否重新执行。早上在业务项目查看
`git diff` 并复跑验收命令；在宿主机另一个终端用 `bash /实际脚本路径/stop.sh claude-batch`
清理旧会话。不要在仍运行的同名会话上重复派活。
