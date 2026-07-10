# 仓库工作约定

## 文件职责

- `codex/AGENTS.md` 只维护跨仓库生效的个人全局指令。
- `skills/*/SKILL.md` 只维护可复用任务流程，不重复全局原则。
- `skills/*/agents/openai.yaml` 维护界面元数据和显式调用策略，必须与对应 `SKILL.md` 一致。
- `codex/config.toml.example` 只提供当前有效的机械配置示例。
- `script/install.sh` 和 `script/install.ps1` 必须产生一致的安装结果。
- `script/validate-skills.py` 是 Skill 结构、元数据和调用策略的仓库内权威校验器。
- `.github/workflows/check.yml` 只调用仓库唯一检查入口，不复制检查逻辑。

## 修改要求

- 所有文档、注释和面向用户的 Skill 元数据使用中文。
- 删除旧入口和过时说明，不保留并行实现或兼容包装层。
- 安装器必须幂等：目标状态未变化时不得创建备份或重写文件。
- 安装器的检查模式必须只读，以非零退出码报告任何安装漂移。
- 安装器不得静默覆盖其他来源的同名 Skill；冲突项必须先备份。
- 只清理由本仓库管理且源目录已经删除的陈旧软链接。
- 每个 Skill 必须显式声明 `allow_implicit_invocation: true` 或 `false`，不得依赖产品默认值表达调用边界。

## 验证

完成修改后运行唯一检查入口：

```bash
./script/check.sh
```

检查必须覆盖 Skill 结构和负向契约、Shell 和 PowerShell 静态检查，以及两个安装器在临时 `HOME` 下的只读漂移检查、首次安装、重复安装、冲突备份和陈旧链接清理。
