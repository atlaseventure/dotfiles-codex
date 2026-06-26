# dotfiles-codex

这是一个用于管理个人自用 Codex skills 的仓库。

## 目录结构

- `skills/`：使用 Git 管理的自定义 skills
- `script/link-agent-skills.sh`：将仓库中的 skills 软链接到用户目录
- `script/link-agent-skills.ps1`：Windows PowerShell 版本的链接脚本
- `codex/AGENTS.md`：Codex 全局指令文件
- `codex/config.toml.example`：脱敏后的配置模板

## 安装方式

macOS / Linux 执行：

```sh
./script/link-agent-skills.sh
```

Windows PowerShell 执行：

```powershell
.\script\link-agent-skills.ps1
```

脚本会将仓库中的 skills 链接到 `$HOME/.agents/skills`，并将 `codex/AGENTS.md` 复制到 `$HOME/.codex/AGENTS.md`。

如果目标位置已经存在同名真实目录或已有 `$HOME/.codex/AGENTS.md`，脚本会先将其备份为带时间戳的 `.bak.*`，再创建软链接或复制新文件。
