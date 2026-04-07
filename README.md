# dotfiles-codex

这是一个用于管理个人自用 Codex skills 的仓库。

## 目录结构

- `skills/`：使用 Git 管理的自定义 skills
- `script/link-agent-skills.sh`：将仓库中的 skills 软链接到用户目录
- `codex/config.toml.example`：脱敏后的配置模板

## 安装方式

执行：

```sh
./script/link-agent-skills.sh
```

脚本会将仓库中的 skills 链接到 `$HOME/.agents/skills`。

如果目标位置已经存在同名真实目录，脚本会先将其备份为带时间戳的 `.bak.*`，再创建软链接。

