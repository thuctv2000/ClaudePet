#!/usr/bin/env node
// claudepet-channel.mjs — a Claude Code *channel* MCP server that bridges the
// running ClaudePet menu-bar app to a live Claude Code session.
//
// Channels are Anthropic's research-preview transport for pushing messages
// INTO a running session (docs: code.claude.com/docs/en/channels). A channel
// is a plain stdio MCP server that Claude Code spawns as a subprocess and that
// (a) declares the `claude/channel` capability so Claude Code registers a
// notification listener, and (b) emits `notifications/claude/channel` events
// whose `content` is injected into the session as `<channel source=...>text
// </channel>`. This one is two-way: it also exposes a `reply` tool so Claude
// can send text back to the pet.
//
// Transport pet<->server (deliberately dead simple, no websockets):
//   * on startup this server POSTs /channel/hello to the pet (port+token read
//     from ~/.petmacos/config.json) announcing its channelId + cwd,
//   * then it LONG-POLLS GET /channel/poll?channelId=..&since=.. — the pet
//     holds the request open until it has a message typed from a session card
//     (or ~25s elapse), and returns any queued messages,
//   * each returned message is emitted as a channel notification into the
//     session,
//   * when Claude calls the `reply` tool, this server POSTs /channel/reply so
//     the pet can show the reply on the conversation card.
//
// Because Claude Code spawns ONE instance of this server per session, one
// running server == one session. The server does not learn its own session_id
// from MCP, so the pet associates a channel with a session by matching cwd
// (this process's cwd is the session's cwd). That is good enough for the v1
// "one session under test" model.
//
// Hand-rolled MCP (newline-delimited JSON-RPC 2.0 over stdio) so the script has
// ZERO npm dependencies and runs on a bare Node install. stdout carries ONLY
// protocol messages; everything else goes to stderr.

import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';

const CONFIG_PATH = join(homedir(), '.petmacos', 'config.json');
const CHANNEL_ID = randomBytes(8).toString('hex');
const CWD = process.cwd();
const SERVER_NAME = 'claudepet';

function log(...args) {
  process.stderr.write(`[claudepet-channel] ${args.join(' ')}\n`);
}

// ---------------------------------------------------------------------------
// Pet HTTP client (loopback, token-gated). Config is read fresh on demand so a
// pet restart (new port/token) is tolerated on the next request.
// ---------------------------------------------------------------------------
function readPetConfig() {
  try {
    const raw = readFileSync(CONFIG_PATH, 'utf8');
    const cfg = JSON.parse(raw);
    if (cfg && cfg.port && cfg.token) return { port: cfg.port, token: cfg.token };
  } catch {
    /* not running / unreadable */
  }
  return null;
}

function petRequest(method, path, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const cfg = readPetConfig();
    if (!cfg) return reject(new Error('pet not running (no config.json)'));
    const payload = body == null ? undefined : Buffer.from(JSON.stringify(body));
    const req = http.request(
      {
        host: '127.0.0.1',
        port: cfg.port,
        path,
        method,
        headers: {
          'X-Pet-Token': cfg.token,
          ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {}),
        },
        timeout: timeoutMs,
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode, body: data }));
      },
    );
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// MCP wire (newline-delimited JSON-RPC 2.0 over stdio).
// ---------------------------------------------------------------------------
function sendMessage(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}
function sendResult(id, result) {
  sendMessage({ jsonrpc: '2.0', id, result });
}
function sendError(id, code, message) {
  sendMessage({ jsonrpc: '2.0', id, error: { code, message } });
}
function sendNotification(method, params) {
  sendMessage({ jsonrpc: '2.0', method, params });
}

// Push one message from the pet into the session as a channel event.
function emitChannelEvent(text) {
  log(`emit channel event (${text.length} chars): ${text.slice(0, 60)}`);
  sendNotification('notifications/claude/channel', {
    content: text,
    meta: { channel_id: CHANNEL_ID },
  });
}

const REPLY_TOOL = {
  name: 'reply',
  description:
    'Send a short message back to the ClaudePet desktop app, which shows it on ' +
    'the conversation card for the human. Use this to answer a message that ' +
    'arrived via <channel source="claudepet">.',
  inputSchema: {
    type: 'object',
    properties: {
      text: { type: 'string', description: 'The message to show back on the pet card.' },
    },
    required: ['text'],
  },
};

let initialized = false;

async function handleMessage(msg) {
  // Notifications (no id) — nothing to answer.
  if (msg.id === undefined || msg.id === null) {
    if (msg.method === 'notifications/initialized') {
      initialized = true;
      startPolling();
    }
    return;
  }

  switch (msg.method) {
    case 'initialize': {
      const clientVersion = msg.params?.protocolVersion || '2025-06-18';
      sendResult(msg.id, {
        protocolVersion: clientVersion,
        capabilities: {
          // Presence of claude/channel is what registers the notification
          // listener in Claude Code; tools:{} exposes the reply tool.
          experimental: { 'claude/channel': {} },
          tools: {},
        },
        serverInfo: { name: SERVER_NAME, version: '0.1.0' },
        instructions:
          'Messages from the human arrive as <channel source="claudepet">…</channel>. ' +
          'They are chat: read the message and, when a reply is warranted, call the ' +
          'reply tool with your answer so it shows up on the pet.',
      });
      return;
    }
    case 'tools/list':
      sendResult(msg.id, { tools: [REPLY_TOOL] });
      return;
    case 'tools/call': {
      const name = msg.params?.name;
      if (name === 'reply') {
        const text = String(msg.params?.arguments?.text ?? '');
        try {
          await petRequest('POST', '/channel/reply', { channelId: CHANNEL_ID, cwd: CWD, text }, 5000);
          sendResult(msg.id, { content: [{ type: 'text', text: 'sent to pet' }] });
        } catch (e) {
          sendResult(msg.id, {
            content: [{ type: 'text', text: `could not reach pet: ${e.message}` }],
            isError: true,
          });
        }
        return;
      }
      sendError(msg.id, -32601, `unknown tool: ${name}`);
      return;
    }
    case 'ping':
      sendResult(msg.id, {});
      return;
    default:
      sendError(msg.id, -32601, `method not found: ${msg.method}`);
      return;
  }
}

// ---------------------------------------------------------------------------
// Long-poll loop: announce (hello) then poll the pet for messages forever.
// ---------------------------------------------------------------------------
let polling = false;
let since = 0;

async function startPolling() {
  if (polling) return;
  polling = true;
  try {
    await petRequest('POST', '/channel/hello', { channelId: CHANNEL_ID, cwd: CWD }, 5000);
    log(`hello ok, channelId=${CHANNEL_ID} cwd=${CWD}`);
  } catch (e) {
    log(`hello failed: ${e.message}`);
  }
  pollLoop();
}

async function pollLoop() {
  while (polling) {
    try {
      const res = await petRequest(
        'GET',
        `/channel/poll?channelId=${CHANNEL_ID}&since=${since}`,
        null,
        35000,
      );
      if (res.status !== 200) {
        await sleep(2000);
        continue;
      }
      const data = JSON.parse(res.body || '{}');
      if (Array.isArray(data.messages) && data.messages.length) {
        for (const m of data.messages) {
          emitChannelEvent(String(m.text ?? ''));
          if (typeof m.seq === 'number') since = Math.max(since, m.seq);
        }
      } else if (typeof data.now === 'number') {
        since = Math.max(since, data.now);
      }
    } catch (e) {
      // Pet unreachable or timeout — back off briefly and retry.
      await sleep(2000);
    }
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// stdin reader: split on newlines, parse each complete JSON message.
// ---------------------------------------------------------------------------
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let idx;
  while ((idx = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      log('bad json line dropped');
      continue;
    }
    handleMessage(msg).catch((e) => log(`handler error: ${e.message}`));
  }
});
process.stdin.on('end', () => {
  polling = false;
  process.exit(0);
});

log(`starting (config=${CONFIG_PATH})`);
// A checksum of the path so duplicate logs from multiple sessions are tellable
// apart in stderr; not used on the wire.
log(`instance=${createHash('sha1').update(CHANNEL_ID).digest('hex').slice(0, 6)}`);
