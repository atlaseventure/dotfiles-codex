# dotfiles-codex

这是一个用于管理个人 Codex 全局提示词、Skills 和配置模板的仓库。

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

## 验证

验证 Skill 契约：

```bash
python3 script/validate-skills.py
```

验证 Shell 脚本语法：

```bash
bash -n script/install.sh
```
