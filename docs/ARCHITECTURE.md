# OpenClaw ↔ Claude Code 全链路架构

## 架构全景

```
┌─────────────────────────────────────────────────────────────────┐
│                       OpenClaw Gateway                          │
│                    (Port 18789, systemd)                        │
│                                                                 │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────┐            │
│  │ WeChat   │  │ Cron Jobs    │  │ Delivery Queue │            │
│  │ Plugin   │  │ (memory      │  │ failed/        │            │
│  │ (weixin) │  │  dreaming)   │  │ (dead letters) │            │
│  └────┬─────┘  └──────────────┘  └────────────────┘            │
│       │                                                          │
└───────┼──────────────────────────────────────────────────────────┘
        │
        │ openclaw message send
        ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Claude Code (交互式)                          │
│                                                                 │
│  ┌──────────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│  │ Skill        │  │ MCP task-bridge │  │ Permissions      │   │
│  │ openclaw.md  │  │ (stdio server)  │  │ settings.local   │   │
│  └──────────────┘  └────────┬────────┘  └──────────────────┘   │
│                              │                                    │
└──────────────────────────────┼────────────────────────────────────┘
                               │
                               │ MCP protocol (stdio)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Task Bridge (MCP Server)                      │
│                    scripts/mcp-task-bridge.js                    │
│                                                                 │
│  list_tasks ←── pending/*.md                                    │
│  get_task   ←── cat pending/xxx.md                              │
│  complete   ──→ mv pending/xxx.md → completed/xxx.md            │
└─────────────────────────────────────────────────────────────────┘
                               │
                               │ 文件系统
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Task Queue (文件队列)                         │
│         ~/.openclaw/workspace/tasks/                            │
│                                                                 │
│  pending/    ← OpenClaw / 手动写入新任务                         │
│  completed/  ← Claude Code complete_task 归档                   │
│  processed/  ← task-watcher 执行记录                             │
│  failed/     ← 拦截 / 超时 / 失败的任务                          │
└─────────────────────────────────────────────────────────────────┘
                               ▲
                               │ 每 5 秒轮询
┌──────────────────────────────┼──────────────────────────────────┐
│                    Task Watcher (守护进程)                       │
│                    scripts/task-watcher.sh                       │
│                    systemd: task-watcher.service                 │
│                                                                 │
│  1. 发现 pending/*.md                                           │
│  2. 校验 # task-source: openclaw                                │
│  3. 并发检测 (pgrep claude)                                      │
│  4. timeout 600 claude --print --max-turns 50                   │
│  5. 结果 → processed/ 或 failed/                                │
│  6. notify_wechat (重试 + 投递确认)                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 组件清单

### 进程

| 组件 | 类型 | 说明 |
|------|------|------|
| `openclaw-gateway.service` | systemd user | OpenClaw 核心网关，端口 18789 |
| `task-watcher.service` | systemd user | 任务轮询 + Claude Code headless 执行 |
| `mcp-task-bridge.js` | MCP stdio | Claude Code 启动时 spawn，暴露 3 个工具 |

### 文件

| 文件 | 用途 |
|------|------|
| `~/.openclaw/openclaw.json` | OpenClaw 主配置（网关 / 模型 / 插件 / 频道） |
| `~/.mcp.json` | Claude Code MCP 服务器注册 |
| `~/.claude/settings.json` | Claude Code 全局设置（API key / model / gateway） |
| `~/.claude/settings.local.json` | Claude Code 项目权限 + MCP 启用 |
| `~/.claude/skills/openclaw.md` | Skill：任务接收 + 微信通知 |
| `~/bin/task-watcher.sh` | 守护脚本 |
| `~/bridge/mcp-task-bridge.js` | MCP 服务器（list / get / complete） |

### 目录

```
~/.openclaw/workspace/tasks/
├── pending/       ← 任务入口
├── completed/     ← MCP complete_task 归档
├── processed/     ← task-watcher 执行记录
└── failed/        ← 拦截 / 超时 / 失败

~/.openclaw/delivery-queue/
└── failed/        ← 消息投递死信
```

---

## 数据流

### 自动化任务

```
写入 pending/xxx.md
  │ < 5 秒
  ▼
watcher 发现 → mv 到 processing → 校验标记
  │
  ├─ 无标记 → failed/ → 微信通知拦截 → END
  │
  ├─ 并发检测 (pgrep claude)
  │   └─ 已有实例 → 退回 pending → sleep 10 → END
  │
  └─ timeout 600 claude --print --max-turns 50
       │
       ├─ exit 0   → processed/ ✅
       ├─ exit 124 → failed/ + 微信通知超时
       └─ exit ≠0  → failed/ + 微信通知失败
```

### 微信通知（投递确认）

```
notify_wechat "消息"
  ├─ 快照 delivery-queue/failed
  ├─ openclaw message send --json
  │   └─ 失败 → 重试 (3次, 3s/6s/12s)
  ├─ sleep 5（等投递）
  ├─ 检查 delivery-queue/failed 新条目
  │   ├─ 无 → ✅ 确认
  │   └─ 有 → 重试 (3次, 5s/10s)
  └─ 全败 → dead-letter.log
```

### 交互式终

```
用户说「检查任务」
  → Skill 触发
    → MCP list_tasks（优先）
    → 文件系统直读（fallback）
    → MCP get_task
    → 执行
    → MCP complete_task
```

---

## 安全模型

| 层级 | 措施 | 说明 |
|------|------|------|
| 来源校验 | `grep "# task-source: openclaw"` | 无标记任务直接拦截 |
| 执行边界 | `--max-turns 50` | 防止死循环 |
| 时间限制 | `timeout 600`（10 分钟） | 防止任务卡死 |
| 错误隔离 | 失败 → `failed/` | 不影响后续任务 |
| 并发保护 | `pgrep -f claude` | 交互式会话运行时自动暂停 |
| 通知可靠 | 3 次重试 + 投递队列检查 | 消息不静默丢失 |

---

## 设计决策

### 为什么用文件队列而不是 MCP 做自动化？

- **解耦**：OpenClaw 不需要知道 Claude Code 是否在运行
- **持久化**：任务不丢失，Claude Code 重启后继续执行
- **可观测**：每步都有文件记录，出问题可追溯

### 为什么用双通道（MCP + watcher）？

- MCP：交互式，手动触发，带上下文
- Watcher：全自动，headless 模式，无人值守

两者共享同一个 pending/ 目录，不冲突。

### 为什么 watcher 要检测 claude 进程？

避免两个 Claude Code 实例同时消费 API 额度。交互式会话运行时自动化暂停，关闭终端后 5 秒内恢复。

---

## 已知限制

1. `openclaw message send` 返回成功只表示 Gateway 入队，实际微信投递是异步的
2. 交互式 Claude Code 运行时，自动化任务不执行（设计如此）
3. 仅支持 Linux（WSL2 可用），依赖 systemd user 实例
4. `claude --print` 的 headless 行为可能受 Claude Code 版本影响
