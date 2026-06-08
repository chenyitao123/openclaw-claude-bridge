#!/bin/bash
# ============================================================
# Task Watcher — 自动监听 pending 任务并交给 Claude Code 执行
# ============================================================
# 用法:
#   手动: bash task-watcher.sh
#   服务: systemctl --user start task-watcher
#
# 安全机制:
#   - 来源标记校验（# task-source: openclaw）
#   - 并发检测（避免和交互式 Claude Code 抢资源）
#   - timeout 600 + --max-turns 50
#   - 微信通知含投递确认（3次重试）
#   - 失败任务保留在 failed/ 目录
#   - 日志自动 rotate（3000 行上限）
# ============================================================

set -e

# ---- 配置（按需修改） ----
PENDING_DIR="$HOME/.openclaw/workspace/tasks/pending"
PROCESSED_DIR="$HOME/.openclaw/workspace/tasks/processed"
FAILED_DIR="$HOME/.openclaw/workspace/tasks/failed"
DELIVERY_FAILED_DIR="$HOME/.openclaw/delivery-queue/failed"
LOG_FILE="$HOME/.openclaw/workspace/tasks/watcher.log"
MAX_LOG_LINES=3000
TASK_TIMEOUT=600
MAX_TURNS=50
REQUIRED_MARKER="# task-source: openclaw"

# ---- 微信通知（按需修改） ----
WECHAT_CHANNEL="openclaw-weixin"
WECHAT_ACCOUNT="your-wechat-account-id"
WECHAT_TARGET="your-wechat-target@im.wechat"

# 确保必要目录存在
mkdir -p "$PENDING_DIR" "$PROCESSED_DIR" "$FAILED_DIR"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

notify_wechat() {
    local msg="$1"
    local max_retries=3
    local attempt=1
    local success=false

    while [ $attempt -le $max_retries ]; do
        # 快照失败队列
        local before_count
        before_count=$(ls "$DELIVERY_FAILED_DIR" 2>/dev/null | wc -l)

        # 发送
        local send_ts
        send_ts=$(date +%s)
        local result
        result=$(openclaw message send \
            --channel "$WECHAT_CHANNEL" \
            --account "$WECHAT_ACCOUNT" \
            --target "$WECHAT_TARGET" \
            --message "$msg" \
            --json 2>&1)
        local ret=$?

        if [ $ret -ne 0 ] || ! echo "$result" | grep -q '"messageId"'; then
            log "⚠️  发送失败 (attempt=$attempt, exit=$ret)"
            if [ $attempt -lt $max_retries ]; then
                sleep $((attempt * 3))
                attempt=$((attempt + 1))
                continue
            fi
            break
        fi

        local msg_id
        msg_id=$(echo "$result" | grep -o '"messageId": "[^"]*"' | cut -d'"' -f4)
        log "📤 已入队 (attempt=$attempt, id=$msg_id)"

        # 等待投递完成
        sleep 5

        # 检查失败队列是否有新条目
        local after_count
        after_count=$(ls "$DELIVERY_FAILED_DIR" 2>/dev/null | wc -l)
        local new_failures=""
        if [ "$after_count" -gt "$before_count" ]; then
            new_failures=$(find "$DELIVERY_FAILED_DIR" -name "*.json" -newermt "@$send_ts" 2>/dev/null)
        fi

        if [ -z "$new_failures" ]; then
            log "✅ 投递确认 (attempt=$attempt, id=$msg_id)"
            success=true
            break
        fi

        log "🔄 投递失败，准备重试 (attempt=$attempt)"
        if [ $attempt -lt $max_retries ]; then
            sleep $((attempt * 5))
            attempt=$((attempt + 1))
        else
            break
        fi
    done

    if $success; then
        return 0
    else
        log "❌ 微信通知最终失败，已重试 ${max_retries} 次"
        echo "[$(date '+%m-%d %H:%M:%S')] $msg" >> "$PROCESSED_DIR/../notify-dead-letter.log"
        return 1
    fi
}

rotate_log() {
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "🔄 日志已 rotate（保留最近 $MAX_LOG_LINES 行）"
    fi
}

log "🚀 任务监听器启动 (PID $$)"

while true; do
    for task in "$PENDING_DIR"/*.md; do
        [ -f "$task" ] || continue

        task_name=$(basename "$task")
        log "📋 发现任务: $task_name"

        # 原子移动，防止重复处理
        processing_path="$PROCESSED_DIR/.processing_$task_name"
        mv "$task" "$processing_path" || continue
        task_content=$(cat "$processing_path")

        # 来源校验
        if ! grep -qF "$REQUIRED_MARKER" "$processing_path"; then
            log "⛔ 拦截（无来源标记）: $task_name"
            mv "$processing_path" "$FAILED_DIR/${task_name%.md}_nomarker_$(date +%H%M%S).md"
            notify_wechat "⛔ 任务被拦截：${task_name}，原因：缺少「# task-source: openclaw」来源标记"
            continue
        fi

        # 并发检测
        if pgrep -f "claude" > /dev/null 2>&1; then
            log "⏸️  已有 Claude Code 实例运行，退回任务: $task_name"
            mv "$processing_path" "$PENDING_DIR/$task_name"
            sleep 10
            continue
        fi

        # 执行
        log "⚙️  执行中..."
        SECONDS=0

        cd "$HOME/.openclaw/workspace" && \
        timeout --kill-after=30 "$TASK_TIMEOUT" \
            claude --print \
                --max-turns "$MAX_TURNS" \
                --permission-mode bypassPermissions \
                -p "你是一个自动化任务执行器。请执行以下任务，完成后用 openclaw message send 汇报结果：

$task_content" \
                >> "$LOG_FILE" 2>&1

        exit_code=$?
        elapsed=$SECONDS

        final_name="${task_name%.md}_$(date +%H%M%S).md"

        if [ $exit_code -eq 0 ]; then
            log "✅ 完成: $task_name (耗时 ${elapsed}s)"
            mv "$processing_path" "$PROCESSED_DIR/$final_name"

        elif [ $exit_code -eq 124 ]; then
            log "⏰ 超时: $task_name (耗时 ${elapsed}s，超过 ${TASK_TIMEOUT}s 限制)"
            mv "$processing_path" "$FAILED_DIR/${task_name%.md}_timeout_$(date +%H%M%S).md"
            notify_wechat "⏰ 任务超时：${task_name}，执行超过 ${TASK_TIMEOUT} 秒被终止"

        else
            log "❌ 失败: $task_name (exit=$exit_code, 耗时 ${elapsed}s)"
            mv "$processing_path" "$FAILED_DIR/${task_name%.md}_exit${exit_code}_$(date +%H%M%S).md"
            notify_wechat "❌ 任务失败：${task_name}，exit=${exit_code}，耗时 ${elapsed} 秒"
        fi

        rotate_log
    done
    sleep 5
done
