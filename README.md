# dotfiles-codex

这是一个用于管理个人 Codex 与 Pi 全局提示词、Skills 和配置模板的仓库。

## 目录结构

- `agents/AGENTS.md`：Codex 与 Pi 共用的全局提示词
- `codex/config.toml.example`：当前有效的全局配置模板
- `codex/agents/default.toml`：Codex 通用探索型子代理配置
- `pi/`：Pi 全局设置、模型、MCP、子代理和 Magic Context 配置
- `skills/`：使用 Git 管理的个人全局 Skills
- `script/install.sh`：macOS、Linux 和 WSL 安装入口
- `script/deploy-pi.sh`：将仓库中的非敏感 Pi 配置部署到 Unix 主机
- `script/deploy-pi.ps1`：使用 PowerShell 7 将仓库中的非敏感 Pi 配置部署到 Windows 主机
- `script/install.ps1`：Windows PowerShell 安装入口
- `script/validate-skills.py`：仓库内 Skill 契约校验器
- `script/check.sh`：本仓库唯一检查入口

## 提示词编排

| 层次 | 权威来源 | 职责 |
| --- | --- | --- |
| 用户全局 | `agents/AGENTS.md` | Codex 与 Pi 共用的跨仓库沟通方式、执行边界和通用工程原则 |
| 项目级 | 项目根目录或子目录的 `AGENTS.md` | 当前仓库或目录的架构、命令、验证和评审规则 |
| 可复用流程 | `skills/*/SKILL.md` | 有明确触发条件、需要按需加载的任务工作流 |
| 调用策略 | `skills/*/agents/openai.yaml` | Skill 展示信息、默认提示词和是否允许隐式调用 |
| 机械配置 | `codex/config.toml.example` | 模型、sandbox 和 feature 等配置示例 |

当前用户要求和作用域更近的项目指令优先于个人全局默认。一个概念只保留一个权威来源，不把项目规则复制进全局提示词，也不把全局原则重复写入 Skill。

## 管理范围

| 仓库源文件 | 安装目标 | 行为 |
| --- | --- | --- |
| `skills/<name>/` | `$HOME/.agents/skills/<name>` | 创建指向仓库目录的软链接 |
| `agents/AGENTS.md` | `$HOME/.codex/AGENTS.md` | 复制到 Codex 全局提示词位置 |
| `agents/AGENTS.md` | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/AGENTS.md` | 复制到 Pi 全局提示词位置 |
| `pi/settings.json` | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json` | 全局 Pi 设置；`lastChangelogVersion` 保留主机值，不同步 |
| `pi/extensions/subagent/config.json` | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/subagent/config.json` | Pi 子代理并发与嵌套深度；整文件由仓库管理 |
| `pi/models.json` | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json` | 模型元数据；`baseUrl`、`apiKey` 和请求头保留主机值 |
| `pi/mcp.json` | `${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/mcp.json` | MCP 服务定义；环境变量、请求头和令牌保留主机值 |
| `pi/cortexkit/magic-context.jsonc` | `${XDG_CONFIG_HOME:-$HOME/.config}/cortexkit/magic-context.jsonc` | Magic Context 用户配置 |
| `codex/agents/default.toml` | `$HOME/.codex/agents/default.toml` | Codex 默认探索型子代理；由安装器备份后覆盖 |

`codex/config.toml.example` 不自动安装。配置可能包含用户环境和认证相关差异，应按需合并到 `$HOME/.codex/config.toml`。`codex/agents/default.toml` 由安装器部署。

## 安装方式

macOS、Linux 或 WSL 执行：

```bash
./script/install.sh
```

Windows PowerShell 7 执行：

```powershell
pwsh -NoProfile -File .\script\install.ps1
```

只读检查当前账户的安装状态：

```bash
./script/install.sh --check
```

```powershell
pwsh -NoProfile -File .\script\install.ps1 -Check
```

检查模式不会创建目录、备份、文件或软链接；存在缺失、冲突、内容漂移或本仓库遗留的陈旧链接时返回非零退出码。

安装器会将目标状态收敛到仓库当前状态：

- 内容和链接未变化时不重写文件、不创建备份。
- 同名真实文件、目录或其他来源的软链接会先备份为唯一的 `.bak.<timestamp>` 路径。
- 仓库中已删除 Skill 所遗留的受管软链接会被清理。
- 其他来源的 Skill 和软链接不会被删除。
- 每个 Skill 在 `agents/openai.yaml` 中声明 `platform` 元数据；安装器按当前系统动态选择可安装的 Skill。
- `ida-mcp-workspace` 的 `platform.windows` 为 `false`，因此仅在 Unix 安装入口中安装。

## Pi 配置

Pi 配置同步和部署按主机使用对应的脚本：Unix 或 WSL 使用 `deploy-pi.sh`，Windows 原生环境使用 PowerShell 7 的 `deploy-pi.ps1`。默认目标为 `$HOME/.pi/agent`；可通过 `PI_CODING_AGENT_DIR` 覆盖 Pi 配置和全局提示词目录，通过 `XDG_CONFIG_HOME` 覆盖 Magic Context 的用户配置目录。

部署配置：

```bash
./script/deploy-pi.sh
```

Windows PowerShell 7 执行：

```powershell
pwsh -NoProfile -File .\script\deploy-pi.ps1
```

只读检查目标状态：

```bash
./script/deploy-pi.sh --check
```

```powershell
pwsh -NoProfile -File .\script\deploy-pi.ps1 -Check
```

部署前会生成完整临时配置，变化的目标文件会备份为唯一的 `.bak.<timestamp>` 路径。部署也会将 `agents/AGENTS.md` 安装为 Pi 的全局上下文文件。`models.json` 和 `mcp.json` 中主机已有的 `baseUrl`、API key、请求头、环境变量和令牌不会被仓库覆盖；`auth.json`、`trust.json`、`models-store.json` 与 sessions 从不纳入同步。Windows 版本不设置 Unix 文件权限，并会将 MCP 配置中的 WSL `/mnt/<盘符>/...` 可执行文件路径转换为 Windows 路径。

## Skill 适用范围

- 本仓库 `skills/` 中的 Skill 安装到用户目录，适用于所有仓库。
- 仅适用于单个项目的 Skill 应放入该项目的 `.agents/skills`。
- 需要面向其他用户分发，或需要同时打包 MCP、连接器和展示资源时，再将 Skill 封装为 Plugin。

## 已管理的 Skills

| Skill | 调用方式 | 用途 |
| --- | --- | --- |
| `commit-worktree` | 可隐式调用 | 验证并提交当前任务相关修改 |
| `audit-task-issues` | 仅显式调用 | 审计当前任务中的问题、绕过行为、遗留风险与修复方案 |
| `ida-mcp-workspace` | 可隐式调用 | 按 SHA-256 准备、校验和复用 IDA MCP 分析对象 |
| `root-cause-review` | 仅显式调用 | 复盘修复是否建立了正确不变量并解决根因 |
| `capture-project-knowledge` | 仅显式调用 | 将经过验证的稳定认知写回职责正确的项目文档 |
| `refactor-codebase-structure` | 仅显式调用 | 系统化拆分大文件、抽取复用组件并整理目录结构 |

## 验证

```bash
./script/check.sh
```

`script/check.sh` 会使用仓库内校验器验证全部 Skill 及其调用策略，执行 Shell 和 PowerShell 7 静态检查，并在临时 `HOME` 下验证 Pi 配置部署以及两个安装器的只读漂移检查、首次安装、重复安装、冲突备份和陈旧链接清理行为。CI 在 Linux 和 Windows 上调用同一个入口。
