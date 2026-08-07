# Pi 派发机制

- Pi 子代理由 `pi-subagents` 提供。单个子代理通过 `subagent` 工具调用；当前只允许使用 `default` 角色，调用时显式指定 `agent: "default"`。不要使用 `scout`、`worker` 或其他非 `default` 角色。
- 多个独立子代理通过 `workflowScript` 调用 `runs.all` 并行运行；稳定的单个子代理调用使用 `runs.run`。不要用 Codex 的 `spawn_agent`、`send_message`、`wait_agent`、`close_agent`、`fork_turns` 或 `FINAL_ANSWER` 术语替代 Pi API。
- 当前仓库的 Pi 配置最多允许 6 个子代理并行运行：`parallel.maxTasks`、`parallel.concurrency` 和 `globalConcurrencyLimit` 均为 6。不要把主代理加到这个子代理数量中，也不要依赖未配置的额外并发。
- 使用 `context: "fresh"` 让探子以干净上下文开始；只有确实需要继承主代理历史时才使用 `context: "fork"`。这与 Codex 的 `fork_turns` 无关。
- 需要当前任务在本轮拿到异步结果时，使用 `subagent_wait({ id: "..." })` 等待指定运行；长期交互场景可使用 `nonBlocking: true` 注册完成订阅。不要用 `wait_agent`。
- Pi 会自动管理子代理的生命周期和结果回传。正常完成不发送手工终态消息，也不要求子代理使用 `FINAL_ANSWER`；子代理的普通最终输出会作为 `subagent` 结果返回。
- 多个并行子代理返回后，主代理负责汇总结果、复核关键证据、做方案取舍和执行最终修改。不要把多个子代理的未核验结论直接当作事实。
- 子代理运行遇到需要主代理决策的阻塞时，按运行时注入的协调指令使用 `contact_supervisor`；仅在有实质阻塞、决策请求或重要异常进展时发送，不发送例行状态。
- 当前 `default` 角色只负责只读探索、检索和核验，不得委托代码修改；需要修改代码时由主代理负责，除非用户明确放宽角色限制。
- 子代理不得自行再次调用 `subagent`，除非该 agent 定义明确允许 `subagent` 工具且嵌套深度配置允许；当前仓库的 `maxSubagentDepth = 1` 默认禁止继续嵌套派发。
- Pi 子代理角色定义来自内置或项目级 `agents/<name>.md` 文件，正文是该角色的 system prompt；当前项目可使用 `.pi/agents/<name>.md` 覆盖同名内置角色。
- `inheritProjectContext: true` 的角色会继承 Pi 发现的 `AGENTS.md` 等项目上下文；关闭它的角色不会继承这些上下文。全局 Pi 提示词不是 Codex 的 `~/.codex/AGENTS.md`。
- `systemPromptMode: replace` 使用角色自身 prompt 替换 Pi 的基础 system prompt；`append` 则追加到基础 prompt。Skills 是否进入子代理由 `inheritSkills`、agent 定义和运行参数决定，不要假设所有子代理都能读取主代理的 Skills。
- 子代理结果只是线索，可能遗漏或出错。主代理应按出处抽查关键结论，把“看到的事实”和“推断”分开；存疑处必须明确标注，并负责最终验证。
