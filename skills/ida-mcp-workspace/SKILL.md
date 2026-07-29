---
name: ida-mcp-workspace
description: 在使用 IDA MCP 前，按 SHA-256 准备、校验、复用和修复 Windows 分析对象。任何任务将对二进制调用 IDA MCP、打开或复用 IDB、通过 Windows idalib 分析程序，或针对数据库运行 IDAPython 时都必须使用。
---

# IDA MCP 工作区

## 工作流程

```bash
python3 <skill-dir>/scripts/prepare_ida_workspace.py <WSL源文件路径>
```
