# dotfiles-codex

这是一个用于管理个人 Codex 与 Pi 全局提示词、Skills 和配置模板的仓库。

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

检查模式仅读取现有状态；发现缺失、冲突、内容漂移或仓库中已删除 Skill 遗留的受管链接时返回非零退出码。

安装器会将目标状态收敛到仓库当前状态：

- 内容和链接未变化时直接保持现有文件。
- 同名真实文件、目录或其他来源的软链接会先备份为唯一的 `.bak.<timestamp>` 路径。
- 仓库中已删除 Skill 所遗留的受管软链接会被清理。
- 其他来源的 Skill 和软链接保持不变。
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

部署前会生成完整临时配置，变化的目标文件会备份为唯一的 `.bak.<timestamp>` 路径。部署也会将 `agents/AGENTS.md` 安装为 Pi 的全局上下文文件。`models.json` 和 `mcp.json` 中主机已有的 `baseUrl`、API key、请求头、环境变量和令牌按主机值保留；同步范围包括仓库中的非敏感字段，并排除 `auth.json`、`trust.json`、`models-store.json` 与 sessions。Windows 版本不设置 Unix 文件权限，并会将 MCP 配置中的 WSL `/mnt/<盘符>/...` 可执行文件路径转换为 Windows 路径。

## 验证

验证 Skill 契约：

```bash
python3 script/validate-skills.py
```

验证 Shell 脚本语法：

```bash
bash -n script/install.sh script/deploy-pi.sh
```
