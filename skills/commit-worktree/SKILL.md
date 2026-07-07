---
name: commit-worktree
description: "Use when the user asks to commit the current workspace or worktree, submit local changes, or generate and apply a git commit for staged or unstaged edits. Follow the format type(scope): message, keep type and scope in English, and prefer Chinese for the message unless the user specifies otherwise."
---

# Commit Worktree

## Overview

Use this skill for requests such as "提交当前工作区内容", "帮我提交改动", "commit current changes", or any instruction to create a git commit from the current local worktree.

The default convention is `type(scope): message`:

- `type` must be English.
- `scope` must be English.
- `message` should prefer Chinese unless the user gives another requirement.

## Workflow

1. Inspect the current worktree with non-interactive git commands.
2. Identify what changed before writing the commit message. Prefer `git status --short`, `git diff --stat`, `git diff --cached --stat`, and targeted file reads when needed.
3. Identify the concrete subsystem from the diff intent and changed paths before choosing `scope`. Then read recent commit history for those paths, such as `git log --oneline -n 10 -- <path>` or `git log --stat -n 10 -- <path>`, to calibrate naming without overriding a clearer subsystem.
4. If the request implies committing the current workspace, stage the relevant tracked and untracked files needed for that commit.
5. Compose a commit message in `type(scope): message` format.
6. Run a normal `git commit -m` command. Do not amend, force-push, or rewrite history unless the user explicitly asks.
7. Report the commit message, commit hash, current branch, and whether the worktree is clean after the commit.

## Commit Message Rules

Choose `type` from the change intent. Common defaults:

- `feat`: new user-facing feature
- `fix`: bug fix or behavioral correction
- `docs`: documentation-only change
- `refactor`: internal restructuring without intended behavior change
- `test`: tests added or updated
- `build`: build system, dependencies, or packaging changes
- `ci`: CI workflow changes
- `chore`: routine maintenance that does not fit the above

Choose a short English `scope` that reflects the concrete affected area, such as `flash`, `boot`, `rootfs`, `runtime`, `toolchain`, `board`, `serial`, `docs`, `login`, `network`, or `ui`. Use broad scopes such as `repo` only when no narrower subsystem can be defended from the diff.

Pick `scope` in this order:

1. Identify the concrete subsystem from the diff intent and changed paths. Prefer the user-visible or operational domain over the broad directory name when the change has a clear behavior, such as `flash` for USB flashing and partition layout changes.
2. Reuse a recent relevant scope only when it is both specific and semantically correct for the current change.
3. Treat generic scopes such as `repo`, `build`, `core`, `common`, `misc`, and `project` as weak signals. Do not reuse them when the diff supports a clearer subsystem.
4. If multiple files are touched but all changes support one behavior, choose the behavior scope rather than the broad repository or tool scope.
5. If several specific subsystems are genuinely changed, choose the primary behavior being delivered. Use `repo` only when no narrower scope can be defended.

Write `message` in concise Chinese by default. It should summarize the main change, not the mechanical action. Prefer forms like:

- `docs(build): 新增本地构建说明文档`
- `fix(login): 修复短信验证码重复发送问题`
- `refactor(network): 整理请求错误处理逻辑`
- `fix(flash): 修复 A/B 分区 USB 烧录链`

## Guardrails

- If there are no changes to commit, say so instead of creating an empty commit.
- If the worktree contains unrelated changes and the user asked to commit "current workspace content", include them unless there is clear evidence they should be separated.
- Do not choose `scope` from filenames alone when the diff behavior points to a clearer subsystem.
- Do not let repeated generic history create scope lock-in. A repeated `repo` or `build` scope is not a reason to avoid a more precise current scope.
- If recent history shows inconsistent specific scopes for what appears to be the same area, prefer the most recent specific scope that matches the current diff behavior.
- Keep the message stable and plain; avoid mixing Chinese and English unless required by established project conventions.
- Use non-interactive git commands only.
