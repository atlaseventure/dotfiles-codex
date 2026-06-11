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
3. Read recent commit history before choosing `scope`. Start with recent commits that touch the same files or directories, such as `git log --oneline -n 10 -- <path>` or `git log --stat -n 10 -- <path>`. If the path history is too sparse, inspect a short slice of recent repo history and look for the established scope naming used for the same feature or module.
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

Choose a short English `scope` that reflects the affected area, such as `build`, `ride`, `login`, `network`, `ui`, or `repo`.

Pick `scope` in this order:

1. Reuse the scope from recent relevant commits when the current change continues the same feature, module, or workflow.
2. If multiple recent commits exist, prefer the scope that appears consistently across the touched paths rather than inventing a new synonym.
3. Only infer a new narrow scope from filenames and diff content when recent history does not provide a clear precedent.
4. If no specific module is clear even after checking history, use `repo`.

Write `message` in concise Chinese by default. It should summarize the main change, not the mechanical action. Prefer forms like:

- `docs(build): 新增本地构建说明文档`
- `fix(login): 修复短信验证码重复发送问题`
- `refactor(network): 整理请求错误处理逻辑`

## Guardrails

- If there are no changes to commit, say so instead of creating an empty commit.
- If the worktree contains unrelated changes and the user asked to commit "current workspace content", include them unless there is clear evidence they should be separated.
- Do not choose `scope` from filenames alone when recent commit history already shows an established name for the same area.
- If recent history shows inconsistent scopes for what appears to be the same area, prefer the most recent repeated scope and keep naming stable within the same feature line.
- Keep the message stable and plain; avoid mixing Chinese and English unless required by established project conventions.
- Use non-interactive git commands only.
