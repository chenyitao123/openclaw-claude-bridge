#!/usr/bin/env node
/**
 * Task Bridge MCP Server
 *
 * Claude Code 通过此 server 接收 OpenClaw 下发的任务。
 *
 * 工具：
 *   list_tasks    — 列出所有待处理任务
 *   get_task      — 获取指定任务内容
 *   complete_task — 标记任务完成
 *
 * 任务队列：~/.openclaw/workspace/tasks/pending/*.md
 * 完成归档：~/.openclaw/workspace/tasks/completed/*.md
 */

const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} = require('@modelcontextprotocol/sdk/types.js');
const fs = require('fs');
const path = require('path');
const os = require('os');

const TASKS_DIR = path.join(os.homedir(), '.openclaw/workspace/tasks');
const PENDING_DIR = path.join(TASKS_DIR, 'pending');
const COMPLETED_DIR = path.join(TASKS_DIR, 'completed');

// Ensure directories exist
[PENDING_DIR, COMPLETED_DIR].forEach(d => {
  if (!fs.existsSync(d)) fs.mkdirSync(d, { recursive: true });
});

const server = new Server(
  { name: 'task-bridge', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'list_tasks',
      description: '列出所有待处理的任务。返回任务文件名和标题摘要。',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'get_task',
      description: '获取指定任务文件的完整内容。获取后请按任务描述执行。',
      inputSchema: {
        type: 'object',
        properties: {
          filename: {
            type: 'string',
            description: '任务文件名（如 js-tutorial.md）',
          },
        },
        required: ['filename'],
      },
    },
    {
      name: 'complete_task',
      description: '标记任务为已完成。任务文件会从 pending/ 移动到 completed/。',
      inputSchema: {
        type: 'object',
        properties: {
          filename: {
            type: 'string',
            description: '任务文件名（如 js-tutorial.md）',
          },
          summary: {
            type: 'string',
            description: '简短的完成总结（1-2句话）',
          },
        },
        required: ['filename'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case 'list_tasks': {
      const files = fs.readdirSync(PENDING_DIR)
        .filter(f => f.endsWith('.md'))
        .sort();

      if (files.length === 0) {
        return {
          content: [{ type: 'text', text: '没有待处理的任务。' }],
        };
      }

      const tasks = files.map(f => {
        const content = fs.readFileSync(path.join(PENDING_DIR, f), 'utf-8');
        const firstLine = content.split('\n').find(l => l.startsWith('# ')) || f;
        const title = firstLine.replace(/^#\s+/, '');
        return `- **${f}** — ${title}`;
      });

      return {
        content: [{
          type: 'text',
          text: `待处理任务 (${files.length}):\n\n${tasks.join('\n')}\n\n用 get_task 获取任务详情后执行。`,
        }],
      };
    }

    case 'get_task': {
      const taskPath = path.join(PENDING_DIR, args.filename);
      if (!fs.existsSync(taskPath)) {
        return {
          content: [{ type: 'text', text: `任务 "${args.filename}" 不存在。` }],
          isError: true,
        };
      }
      const content = fs.readFileSync(taskPath, 'utf-8');
      return {
        content: [{
          type: 'text',
          text: `${args.filename}\n\n${content}\n\n---\n执行完毕后用 complete_task 标记完成。`,
        }],
      };
    }

    case 'complete_task': {
      const taskPath = path.join(PENDING_DIR, args.filename);
      if (!fs.existsSync(taskPath)) {
        return {
          content: [{ type: 'text', text: `任务 "${args.filename}" 不存在或已完成。` }],
          isError: true,
        };
      }

      const summary = args.summary || '已完成';
      let content = fs.readFileSync(taskPath, 'utf-8');
      const completedTime = new Date().toISOString();
      content = `> ${completedTime} | ${summary}\n\n${content}`;

      const destPath = path.join(COMPLETED_DIR, args.filename);
      fs.writeFileSync(destPath, content);
      fs.unlinkSync(taskPath);

      return {
        content: [{
          type: 'text',
          text: `任务 "${args.filename}" 已完成并归档。\n总结: ${summary}`,
        }],
      };
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
});

const transport = new StdioServerTransport();
server.connect(transport).catch(console.error);
