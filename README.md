# dotfiles-codex

这是一个用于管理个人 Codex 全局指令、Skills 和配置模板的仓库。

## 目录结构

- `AGENTS.md`：仅适用于本仓库的维护与验证约定
- `codex/AGENTS.md`：Codex 全局指令文件
- `codex/config.toml.example`：当前有效的全局配置模板
- `skills/`：使用 Git 管理的个人全局 Skills
- `script/install.sh`：macOS、Linux 和 WSL 安装入口
- `script/install.ps1`：Windows PowerShell 安装入口
- `script/check.sh`：本仓库唯一检查入口

## 管理范围

| 仓库源文件 | 安装目标 | 行为 |
| --- | --- | --- |
| `skills/<name>/` | `$HOME/.agents/skills/<name>` | 创建指向仓库目录的软链接 |
| `codex/AGENTS.md` | `$HOME/.codex/AGENTS.md` | 复制为全局指令文件 |

`codex/config.toml.example` 不自动安装。配置可能包含用户环境和认证相关差异，应按需合并到 `$HOME/.codex/config.toml`。

## 安装方式

macOS、Linux 或 WSL 执行：

```bash
./script/install.sh
```

Windows PowerShell 执行：

```powershell
.\script\install.ps1
```

安装器会将目标状态收敛到仓库当前状态：

- 内容和链接未变化时不重写文件、不创建备份。
- 同名真实文件、目录或其他来源的软链接会先备份为唯一的 `.bak.<timestamp>` 路径。
- 仓库中已删除 Skill 所遗留的受管软链接会被清理。
- 其他来源的 Skill 和软链接不会被删除。

## Skill 适用范围

- 本仓库 `skills/` 中的 Skill 安装到用户目录，适用于所有仓库。
- 仅适用于单个项目的 Skill 应放入该项目的 `.agents/skills`。
- 需要面向其他用户分发，或需要同时打包 MCP、连接器和展示资源时，再将 Skill 封装为 Plugin。

## 验证

```bash
./script/check.sh
```

检查入口会验证 Skill 结构、Shell 和 PowerShell 静态质量，并在临时 `HOME` 下验证两个安装器的首次安装、重复安装、冲突备份和陈旧链接清理行为。
