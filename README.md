# dotfiles-codex

Personal-use Codex skill repository.

## Layout

- `skills/`: custom skills tracked in git
- `script/link-agent-skills.sh`: symlink tracked skills into the user skill directory
- `codex/config.toml.example`: sanitized config template

## Scope

This repository tracks only user-authored skills and safe templates.

Do not commit runtime state such as:

- `~/.codex/auth.json`
- `~/.codex/sessions/`
- `~/.codex/log/`
- `~/.codex/logs_*.sqlite`
- `~/.codex/state_*.sqlite`
- `~/.codex/plugins/cache/`
- any `config.toml` containing secrets

## Install

Run:

```sh
./script/link-agent-skills.sh
```

The script links tracked skills into `$HOME/.agents/skills`.

If a target skill already exists as a real directory, the script moves it aside with a timestamped `.bak.*` suffix before creating the symlink.

## Current Skills

- `commit-worktree`
