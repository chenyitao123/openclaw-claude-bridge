# OpenClaw ↔ Claude Code 双向桥接

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**让 Claude Code 成为 OpenClaw 的自动化执行引擎**——任务文件队列驱动，无人值守执行，微信通知汇报。

## 能做什么

```
你（微信）→ OpenClaw → 写任务文件 → task-watcher 自动捡起 → Claude Code 执行 → 微信通知结果
```

- 🔄 **双通道**：交互式（Claude Code 对话中「检查任务」）+ 自动化（守护进程 5 秒轮询）
- 📱 **微信通知**：任务完成/失败/超时实时推送到微信
- 🛡️ **安全执行**：来源标记校验 + 轮次/超时限制 + 错误隔离
- 🔌 **零侵入**：基于文件队列，不修改 Claude Code 或 OpenClaw 核心

## 架构

```
OpenClaw Gateway ──→ pending/*.md ──→ Task Watcher ──→ claude --print
                                           │
微信 ←── openclaw message send ←──────────┘
```

详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## 快速开始

### 前置条件

- OpenClaw ≥ 2026.5.12（含 `openclaw-weixin` 插件）
- Claude Code ≥ 2.1
- Linux（推荐 WSL2）
- systemd user 实例

### 一键安装

```bash
git clone https://github.com/YOUR_USERNAME/openclaw-claude-bridge.git
cd openclaw-claude-bridge
bash setup.sh
```

`setup.sh` 会引导你填写：
- OpenClaw Gateway token
- DeepSeek API key（或其他 Anthropic 兼容后端）
- 微信通道账号 ID 和目标用户

### 手动安装

```bash
# 1. 创建任务队列
mkdir -p ~/.openclaw/workspace/tasks/{pending,completed,failed,processed}

# 2. 部署 MCP 服务器
cp configs/mcp.json.template ~/.mcp.json
# 编辑 ~/.mcp.json，替换路径

# 3. 部署 Claude Code Skill
mkdir -p ~/.claude/skills
cp skills/openclaw.md ~/.claude/skills/

# 4. 配置 Claude Code 设置
# 参考 configs/settings.json.template
# 参考 configs/settings.local.json.template

# 5. 安装 systemd 服务
cp configs/systemd/task-watcher.service ~/.config/systemd/user/
cp scripts/task-watcher.sh ~/bin/
chmod +x ~/bin/task-watcher.sh
systemctl --user daemon-reload
systemctl --user enable --now task-watcher.service
```

## 使用方式

### 方式一：自动化（无人值守）

直接通过 OpenClaw 或其他方式写入任务文件：

```bash
cat > ~/.openclaw/workspace/tasks/pending/hello.md << 'EOF'
# task-source: openclaw
## 打个招呼

请向微信发送一条消息：「你好，自动化桥接测试成功！」
EOF
```

3-8 秒内，task-watcher 会自动捡起、执行、微信通知。

### 方式二：交互式（Claude Code 对话中）

在 Claude Code 中输入：**「检查任务」**

## 安全模型

| 层级 | 措施 |
|------|------|
| 来源校验 | 任务必须含 `# task-source: openclaw` 标记 |
| 执行边界 | `--max-turns 50` + `timeout 600` |
| 错误隔离 | 失败任务入 `failed/`，不影响后续 |
| 并发保护 | 交互式会话运行时自动暂停自动化执行 |

## 文件说明

```
.
├── README.md
├── setup.sh                          # 交互式安装脚本
├── scripts/
│   ├── task-watcher.sh               # 守护进程脚本
│   └── mcp-task-bridge.js            # MCP 服务器（list/get/complete）
├── skills/
│   └── openclaw.md                   # Claude Code Skill
├── configs/
│   ├── openclaw.json.template        # OpenClaw 网关配置模板
│   ├── settings.json.template        # Claude Code 全局设置模板
│   ├── settings.local.json.template  # Claude Code 项目设置模板
│   ├── mcp.json.template            # MCP 服务器注册
│   └── systemd/
│       ├── openclaw-gateway.service  # 网关 systemd unit
│       └── task-watcher.service      # 守护进程 systemd unit
└── docs/
    └── ARCHITECTURE.md               # 全链路架构文档
```

## 常见问题

**Q: 为什么开着 Claude Code 时自动化任务不执行？**
A: 这是并发保护机制。两个 Claude Code 实例会竞争 API 额度。关闭终端后 5 秒内恢复。

**Q: 微信消息有时收不到？**
A: `notify_wechat` 内置了 3 次重试 + 投递队列确认机制。仍失败的消息会写入死信日志。

**Q: 如何查看历史执行记录？**
A: `ls ~/.openclaw/workspace/tasks/processed/`，每条任务独立保留。

## License

MIT
