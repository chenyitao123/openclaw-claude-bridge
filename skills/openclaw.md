---
name: openclaw
description: 接收 OpenClaw 下发的任务 + 发微信通知 + 向 OpenClaw Agent 注入任务。关键词：检查任务、pending、待处理、有什么活、接任务、check任务
---

# OpenClaw ↔ Claude Code 双向链路

## 任务接收流程

当用户说「检查任务」「pending」「待处理」「有什么活」「接任务」时：

### 任务操作：优先 MCP

```bash
# Step 1: 列出待处理任务 → MCP list_tasks
# 如果 MCP 不可用，fallback 到文件系统直读：
ls ~/.openclaw/workspace/tasks/pending/
for f in ~/.openclaw/workspace/tasks/pending/*.md; do
  [ -f "$f" ] && echo "=== $(basename $f) ===" && cat "$f" && echo ""
done

# Step 2: 获取任务详情 → MCP get_task (filename: "xxx.md")

# Step 3: 执行任务...

# Step 4: 完成后归档 → MCP complete_task (filename: "xxx.md", summary: "已完成xxx")
# fallback: mv pending/xxx.md → completed/xxx.md
```

以上「优先 MCP」**仅适用于任务操作**（list_tasks / get_task / complete_task）。

任务来自 OpenClaw 写入的**文件队列**（`~/.openclaw/workspace/tasks/pending/`），不是内置 Cron/Task 系统。

## 任务执行规则

1. **读到任务就执行到底** — 除非任务明确需要用户确认，否则直接完成全流程
2. **完成后必须归档** — 用 MCP `complete_task` 或 `mv` 到 completed/
3. **任务要求通知时必发** — 用下面的 Bash 命令（`openclaw message send`），没有 MCP 备选
4. **重要产出写 memory** — 保存到 `~/.openclaw/workspace/memory/claude-code-outputs/` 下

---

## 方式一：发送微信通知

**这是 Bash 命令，不是 MCP 工具。直接用 Bash 工具执行，不要搜索 MCP wechat/微信 工具。**

消息发到你的微信：

```bash
openclaw message send \
  --channel openclaw-weixin \
  --account <your-wechat-account-id> \
  --target "<your-wechat-target>@im.wechat" \
  --message "<消息内容>"
```

没有 MCP 备选路径，bash 命令就是唯一路径。

## 方式二：注入 Agent 任务管线

任务进入 OpenClaw Agent 思考流程，Agent 处理后回复：

```bash
openclaw agent \
  --session-id <your-session-id> \
  --message "<任务描述>" \
  --deliver \
  --thinking high
```

## 选哪种？

| 场景 | 用哪个 |
|------|--------|
| 告知任务完成 / 简短通报 | 方式一 (`message send`) |
| 需要 Agent 分析、生成内容、多轮思考 | 方式二 (`agent --deliver`) |
| 进度更新 | 方式一 |
| 复杂任务编排 | 方式二 |

## 规则

- 方式一消息简洁，一行说清楚
- 方式二任务描述清晰完整，包含上下文
- 不要在循环中频繁发送消息
- 所有重要产出同步写入 `~/.openclaw/workspace/memory/claude-code-outputs/YYYY-MM-DD-<描述>.md`
