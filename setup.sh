#!/bin/bash
# ============================================================
# OpenClaw ↔ Claude Code 双向桥接 · 一键配置脚本
# ============================================================
set -e

echo ""
echo "🔧 OpenClaw ↔ Claude Code 双向桥接 配置向导"
echo "============================================"
echo ""

# ---------- 收集信息 ----------
read -p "你的用户名（系统用户，如 chenyitao）: " SYSUSER
SYSUSER=${SYSUSER:-$USER}

read -p "OpenClaw Gateway Token（从 ~/.openclaw/openclaw.json gateway.auth.token 获取）: " GW_TOKEN

read -p "DeepSeek API Key（或其他 Anthropic 兼容后端的 key）: " API_KEY

read -p "API Base URL [https://api.deepseek.com/anthropic]: " API_BASE
API_BASE=${API_BASE:-https://api.deepseek.com/anthropic}

read -p "主模型 [deepseek-v4-pro[1m]]: " PRIMARY_MODEL
PRIMARY_MODEL=${PRIMARY_MODEL:-deepseek-v4-pro[1m]}

read -p "微信通道账号 ID: " WX_ACCOUNT

read -p "微信目标 ID（如 o9cq8...@im.wechat）: " WX_TARGET

NODE_BIN="/home/${SYSUSER}/.openclaw/tools/node-v22.22.0/bin/node"
OPENCLAW_DIST="/home/${SYSUSER}/.openclaw/tools/node-v22.22.0/lib/node_modules/openclaw/dist/index.js"
NODE_PATH="/home/${SYSUSER}/.openclaw/tools/node-v22.22.0/lib/node_modules/openclaw/node_modules"
WS_DIR="/home/${SYSUSER}/.openclaw/workspace"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "📁 创建目录..."

mkdir -p "/home/${SYSUSER}/.openclaw/workspace/tasks"/{pending,completed,failed,processed}
mkdir -p "/home/${SYSUSER}/.claude/skills"
mkdir -p "/home/${SYSUSER}/bin"
mkdir -p "/home/${SYSUSER}/.config/systemd/user"

echo "✅ 目录创建完成"

# ---------- MCP 配置 ----------
echo ""
echo "🔌 配置 MCP task-bridge..."

cat > "/home/${SYSUSER}/.mcp.json" << EOFMCP
{
  "mcpServers": {
    "task-bridge": {
      "type": "stdio",
      "command": "${NODE_BIN}",
      "args": ["${SCRIPT_DIR}/scripts/mcp-task-bridge.js"],
      "env": {
        "NODE_PATH": "${NODE_PATH}"
      }
    }
  }
}
EOFMCP
echo "✅ ~/.mcp.json"

# ---------- Claude Code 全局设置 ----------
echo ""
echo "⚙️  配置 Claude Code 全局设置..."

cat > "/home/${SYSUSER}/.claude/settings.json" << EOFCFG
{
  "env": {
    "ANTHROPIC_BASE_URL": "${API_BASE}",
    "ANTHROPIC_AUTH_TOKEN": "${API_KEY}",
    "ANTHROPIC_MODEL": "${PRIMARY_MODEL}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${PRIMARY_MODEL}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${PRIMARY_MODEL}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
    "OPENCLAW_GATEWAY_URL": "http://localhost:18789",
    "OPENCLAW_GATEWAY_TOKEN": "${GW_TOKEN}"
  }
}
EOFCFG
echo "✅ ~/.claude/settings.json"

# ---------- Claude Code 项目设置 ----------
echo ""
echo "🔐 配置 Claude Code 权限..."

cat > "/home/${SYSUSER}/.claude/settings.local.json" << EOFPERM
{
  "enableAllProjectMcpServers": true,
  "enabledMcpjsonServers": ["task-bridge"],
  "permissions": {
    "allow": [
      "Bash(openclaw message *)",
      "Bash(openclaw channel *)",
      "Bash(openclaw channels *)",
      "Bash(openclaw agent *)",
      "Bash(openclaw agents *)",
      "Bash(openclaw --version)",
      "Bash(openclaw --help)",
      "Bash(systemctl --user status openclaw-gateway)",
      "Bash(systemctl --user status task-watcher)",
      "Bash(systemctl --user restart task-watcher)",
      "Bash(systemctl --user list-units --type=service)",
      "Bash(journalctl --user -u openclaw-gateway *)",
      "Bash(chmod +x ~/bin/task-watcher.sh)",
      "mcp__task-bridge__list_tasks",
      "mcp__task-bridge__get_task",
      "mcp__task-bridge__complete_task",
      "Bash(claude --version)",
      "Bash(python3 -m json.tool)"
    ]
  }
}
EOFPERM
echo "✅ ~/.claude/settings.local.json"

# ---------- Claude Code Skill ----------
echo ""
echo "📝 部署 Claude Code Skill..."

cp "${SCRIPT_DIR}/skills/openclaw.md" "/home/${SYSUSER}/.claude/skills/openclaw.md"
echo "✅ ~/.claude/skills/openclaw.md"

# ---------- Task Watcher ----------
echo ""
echo "🤖 部署 Task Watcher 守护进程..."

# 定制微信配置
sed -e "s/WECHAT_ACCOUNT=\"your-wechat-account-id\"/WECHAT_ACCOUNT=\"${WX_ACCOUNT}\"/" \
    -e "s/WECHAT_TARGET=\"your-wechat-target@im.wechat\"/WECHAT_TARGET=\"${WX_TARGET}\"/" \
    "${SCRIPT_DIR}/scripts/task-watcher.sh" > "/home/${SYSUSER}/bin/task-watcher.sh"
chmod +x "/home/${SYSUSER}/bin/task-watcher.sh"
echo "✅ ~/bin/task-watcher.sh"

# ---------- systemd 服务 ----------
echo ""
echo "⚡ 安装 systemd 服务..."

# Gateway service
sed "s|<path-to-node>|${NODE_BIN}|g; s|<path-to-openclaw-dist>|${OPENCLAW_DIST}|g" \
    "${SCRIPT_DIR}/configs/systemd/openclaw-gateway.service" \
    > "/home/${SYSUSER}/.config/systemd/user/openclaw-gateway.service"

# Task watcher service
cp "${SCRIPT_DIR}/configs/systemd/task-watcher.service" \
   "/home/${SYSUSER}/.config/systemd/user/task-watcher.service"

systemctl --user daemon-reload
echo "✅ systemd units 已安装"

# ---------- 启动服务 ----------
echo ""
echo "🚀 启动服务..."

systemctl --user enable --now openclaw-gateway.service 2>/dev/null || \
    echo "⚠️  openclaw-gateway 启动失败（可能已运行），请手动检查"
systemctl --user enable --now task-watcher.service 2>/dev/null || \
    echo "⚠️  task-watcher 启动失败，请手动检查"

# ---------- 验证 ----------
echo ""
echo "🧪 验证安装..."

ERRORS=0

# 检查服务状态
if systemctl --user is-active openclaw-gateway > /dev/null 2>&1; then
    echo "✅ openclaw-gateway 运行中"
else
    echo "⚠️  openclaw-gateway 未运行"
    ((ERRORS++))
fi

if systemctl --user is-active task-watcher > /dev/null 2>&1; then
    echo "✅ task-watcher 运行中"
else
    echo "⚠️  task-watcher 未运行"
    ((ERRORS++))
fi

# 检查 MCP 配置
[[ -f "/home/${SYSUSER}/.mcp.json" ]] && echo "✅ .mcp.json" || { echo "❌ .mcp.json 缺失"; ((ERRORS++)); }
[[ -f "/home/${SYSUSER}/.claude/skills/openclaw.md" ]] && echo "✅ skill" || { echo "❌ skill 缺失"; ((ERRORS++)); }
[[ -f "/home/${SYSUSER}/bin/task-watcher.sh" ]] && echo "✅ task-watcher.sh" || { echo "❌ task-watcher.sh 缺失"; ((ERRORS++)); }
[[ -d "/home/${SYSUSER}/.openclaw/workspace/tasks/pending" ]] && echo "✅ 任务队列" || { echo "❌ 任务队列缺失"; ((ERRORS++)); }

echo ""
echo "========================================"
if [ $ERRORS -eq 0 ]; then
    echo "🎉 配置完成！双向桥接已就绪。"
    echo ""
    echo "📋 下一步:"
    echo "   1. 重启 Claude Code"
    echo "   2. 在对话中说「检查任务」测试交互式通道"
    echo "   3. 手动写入一个任务到 pending/ 测试自动化通道:"
    echo ""
    echo "      cat > ~/.openclaw/workspace/tasks/pending/hello.md << 'EOF'"
    echo "      # task-source: openclaw"
    echo "      ## 测试"
    echo "      发送微信：「桥接测试成功！」"
    echo "      EOF"
else
    echo "⚠️  发现 ${ERRORS} 个问题，请检查上述输出。"
fi
