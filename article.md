# 我写了个 Claude Code 挂机脚本，发微信就能自动干活

兄弟们，事情是这样的。

## 起因

前段时间用 OpenClaw + Claude Code 搭了个工作流，确实好用，但有个痛点：

每次写完任务，还得打开终端 → 进入 Claude Code → 手动输入「检查任务」→ 等结果。白天还好，半夜想跑个脚本？明天再说吧。

最烦的是，有时候忘了检查，任务躺在 pending 里吃灰，过两天才想起来——「哦对，还有个事儿没跑」。

作为一个懒人，我忍不了。

## 思路

琢磨了一下，核心就两步：

1. **怎么让 Claude Code 自动执行**，不用人守着
2. **怎么把结果通知到微信**，不用打开终端看

第一点，Claude Code 有个 `--print` 模式，可以 headless 运行，完美。调度可以用 systemd 定时器或者守护进程轮询，我选了轮询——因为任务什么时候来不确定，5 秒扫一次不费资源。

第二点，OpenClaw 自带微信通道，`openclaw message send` 一条命令就能发消息。但问题是这玩意儿是 fire-and-forget 的，返回成功不代表微信真收到了。于是加了个投递确认机制——发完等 5 秒，检查投递队列有没有新失败，有就重试。

整体思路：

```
写任务文件 → 守护进程自动捡起 → Claude Code 执行 → 微信通知结果
```

## 实现

整个方案的文件结构就这些：

```
openclaw-claude-bridge/
├── setup.sh                      # 一键配置
├── scripts/
│   ├── task-watcher.sh           # 守护进程核心
│   └── mcp-task-bridge.js        # MCP 服务器
├── skills/
│   └── openclaw.md               # Claude Code Skill
├── configs/                      # 各类配置模板
└── docs/
    └── ARCHITECTURE.md           # 全链路文档
```

### 守护进程（task-watcher.sh）

核心逻辑很简单，一个 while true 循环：

```bash
while true; do
  for task in pending/*.md; do
    # 1. 原子 mv，防重复
    # 2. 检查是否包含 # task-source: openclaw 标记
    # 3. 检测是否已有 Claude Code 在跑（并发保护）
    # 4. timeout 600 claude --print 执行
    # 5. 成功 → processed/，失败 → failed/
    # 6. 微信通知（含投递确认）
  done
  sleep 5
done
```

几个安全措施我觉得很重要：

- **任务来源标记**：没带 `# task-source: openclaw` 的任务直接拦截，微信告警。防止脏数据进去
- **并发保护**：`pgrep -f claude` 检测是否已有 Claude Code 实例，有就退回 pending。避免你跟 Claude Code 聊天的时候，后台又起一个把 API 额度吃光
- **超时限制**：`timeout 600`，10 分钟不结束就杀。配合 `--max-turns 50`，防止死循环
- **投递确认**：微信通知不是「发了就当到了」，而是发完等 5 秒，检查 `delivery-queue/failed` 有没有新条目

### 微信通知的坑

这个值得单独说一下。

`openclaw message send` 返回 `✅ Sent` 的时候，你以为是发出去了，其实它只是告诉你 Gateway 收到了。真正的投递是微信插件异步做的——如果插件这时候抢不到 session 文件锁，消息就丢了，你完全不知道。

我翻了投递队列，确实发现两条历史死信，错误都是 `session file locked timeout 60000ms`。

解决方案：

```bash
notify_wechat() {
  # 1. 快照当前失败队列文件数
  # 2. openclaw message send --json
  # 3. sleep 5（等异步投递）
  # 4. 检查失败队列数量是否增加
  # 5. 增加 → 重试，没增加 → 确认投递
  # 6. 最多重试 3 次
}
```

每次重试间隔递增（3s → 6s → 12s，第二次开始 5s → 10s），给锁竞争留出窗口。

顺带一提，Claude Code 里的 Skill 文件也要写清楚——微信通知是 Bash 命令，不是 MCP 工具，不要让 Claude Code 去搜 MCP wechat 工具，直接 `Bash(openclaw message send)` 就行。这个教训是 Claude Code 把「优先 MCP」理解成了全局偏好，遇事就去搜 MCP，搜不到就报不可用，不会 fallback 到写好的 bash 命令。

### 双通道并行

这套方案其实支持两个通道同时跑：

| | 自动化（Watcher） | 交互式（Skill） |
|---|---|---|
| 触发方式 | 写入文件即触发 | 在 Claude Code 里说「检查任务」 |
| 适用场景 | 定时、批量、无人值守 | 需要上下文判断的复杂任务 |
| 权限 | bypassPermissions | 正常审批流程 |

两个通道共享同一个 `pending/` 目录，不冲突。你可以大部分任务走自动化，偶尔手动干预用交互式。

## 部署

一行命令：

```bash
bash setup.sh
```

脚本会问你要 DeepSeek API key、Gateway token、微信账号，其他全自动。

或者手动走五步：

```bash
# 1. 创建任务队列目录
mkdir -p ~/.openclaw/workspace/tasks/{pending,completed,failed,processed}

# 2. 配置 MCP
cp configs/mcp.json.template ~/.mcp.json

# 3. 部署 Skill
cp skills/openclaw.md ~/.claude/skills/

# 4. 配置 Claude Code（API key、model、权限白名单）

# 5. 安装守护进程
cp scripts/task-watcher.sh ~/bin/
cp configs/systemd/task-watcher.service ~/.config/systemd/user/
systemctl --user enable --now task-watcher.service
```

## 效果

写个测试任务看看：

```bash
cat > ~/.openclaw/workspace/tasks/pending/hello.md << 'EOF'
# task-source: openclaw
## 测试

用中文给微信发一条消息介绍你自己，说清楚你是谁、能做什么。
EOF
```

8 秒后微信收到：

> 👋 你好！我是 Claude Code，通过 OpenClaw 桥接自动执行的。我可以写代码、查资料、分析数据、生成报告。这条消息是守护进程自动触发执行的，全程没有打开终端 🎉

## 最后

项目已开源在 GitHub：

**🔗 [github.com/chenyitao123/openclaw-claude-bridge](https://github.com/chenyitao123/openclaw-claude-bridge)**

MIT 协议，随便用。如果你也在用 OpenClaw + Claude Code，不妨试一下，能省不少事。

有问题提 Issue，好用的话给个 ⭐。

---

*折腾完感觉 Claude Code 的可玩性比想象中高很多。下一步想试试把 task-watcher 的轮询改成 inotify 事件驱动，彻底消灭 5 秒延迟。搞定了再写一篇。*
