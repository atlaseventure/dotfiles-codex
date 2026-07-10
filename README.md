# dotfiles-codex

这是一个用于管理个人 Codex 全局指令、Skills 和配置模板的仓库。

## 目录结构

- `AGENTS.md`：仅适用于本仓库的维护与验证约定
- `codex/AGENTS.md`：Codex 全局指令文件
- `codex/config.toml.example`：当前有效的全局配置模板
- `skills/`：使用 Git 管理的个人全局 Skills
- `script/install.sh`：macOS、Linux 和 WSL 安装入口
- `script/install.ps1`：Windows PowerShell 安装入口
- `script/validate-skills.py`：仓库内 Skill 契约校验器
- `script/check.sh`：本仓库唯一检查入口

## 提示词编排

| 层次 | 权威来源 | 职责 |
| --- | --- | --- |
| 用户全局 | `codex/AGENTS.md` | 跨仓库生效的沟通方式、执行边界和通用工程原则 |
| 项目级 | 项目根目录或子目录的 `AGENTS.md` | 当前仓库或目录的架构、命令、验证和评审规则 |
| 可复用流程 | `skills/*/SKILL.md` | 有明确触发条件、需要按需加载的任务工作流 |
| 调用策略 | `skills/*/agents/openai.yaml` | Skill 展示信息、默认提示词和是否允许隐式调用 |
| 机械配置 | `codex/config.toml.example` | 模型、sandbox 和 feature 等配置示例 |

当前用户要求和作用域更近的项目指令优先于个人全局默认。一个概念只保留一个权威来源，不把项目规则复制进全局提示词，也不把全局原则重复写入 Skill。

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

只读检查当前账户的安装状态：

```bash
./script/install.sh --check
```

```powershell
.\script\install.ps1 -Check
```

检查模式不会创建目录、备份、文件或软链接；存在缺失、冲突、内容漂移或本仓库遗留的陈旧链接时返回非零退出码。

安装器会将目标状态收敛到仓库当前状态：

- 内容和链接未变化时不重写文件、不创建备份。
- 同名真实文件、目录或其他来源的软链接会先备份为唯一的 `.bak.<timestamp>` 路径。
- 仓库中已删除 Skill 所遗留的受管软链接会被清理。
- 其他来源的 Skill 和软链接不会被删除。

## Skill 适用范围

- 本仓库 `skills/` 中的 Skill 安装到用户目录，适用于所有仓库。
- 仅适用于单个项目的 Skill 应放入该项目的 `.agents/skills`。
- 需要面向其他用户分发，或需要同时打包 MCP、连接器和展示资源时，再将 Skill 封装为 Plugin。

## 已管理的 Skills

| Skill | 调用方式 | 用途 |
| --- | --- | --- |
| `commit-worktree` | 可隐式调用 | 验证并提交当前任务相关修改 |
| `root-cause-review` | 仅显式调用 | 复盘修复是否建立了正确不变量并解决根因 |
| `capture-project-knowledge` | 仅显式调用 | 将经过验证的稳定认知写回职责正确的项目文档 |

## 验证

```bash
./script/check.sh
```

检查入口会使用仓库内校验器验证全部 Skill 及其调用策略，执行 Shell 和 PowerShell 静态检查，并在临时 `HOME` 下验证两个安装器的只读漂移检查、首次安装、重复安装、冲突备份和陈旧链接清理行为。CI 在 Linux 和 Windows 上调用同一个入口。
