# dotfiles-codex

管理个人 Codex、Claude Code 全局提示词、共享 Skills 和 Codex 配置模板。

## 安装方式

macOS、Linux 或 WSL 执行：

```bash
./scripts/install.sh
```

Windows 启用开发者模式或使用管理员权限，在 PowerShell 7 执行：

```powershell
pwsh -NoProfile -File .\scripts\install.ps1
```

安装器将全局提示词分别复制到 `~/.codex/AGENTS.md` 和 `~/.claude/CLAUDE.md`，并将当前平台支持的 Skills 软链接到 `~/.agents/skills` 和 `~/.claude/skills`。

重复安装会保留未变化的文件和链接；冲突项先备份为 `.bak.<timestamp>`，仓库中已删除 Skill 的受管链接会被清理，其他 Skills 保持不变。

只读检查当前账户的安装状态，发现缺失、冲突、内容变化或陈旧受管链接时返回非零退出码：

```bash
./scripts/install.sh --check
```

```powershell
pwsh -NoProfile -File .\scripts\install.ps1 -Check
```

## 验证

验证 Skill 契约：

```bash
python3 scripts/validate-skills.py skills
```

验证 Shell 脚本语法：

```bash
bash -n scripts/install.sh
```
