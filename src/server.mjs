import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, extname, isAbsolute, join, normalize, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const publicDir = join(here, '..', 'public');
const host = process.env.CLOUDPC_AGENT_HOST || '127.0.0.1';
const port = Number(process.env.CLOUDPC_AGENT_PORT || 8787);
const copilot = process.env.COPILOT_BIN || 'copilot';
const maxBodyBytes = readPositiveInteger('CLOUDPC_AGENT_MAX_BODY_BYTES', 1024 * 1024);
const maxSessions = readPositiveInteger('CLOUDPC_AGENT_MAX_SESSIONS', 100);

class HttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function readPositiveInteger(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

function expandHome(input) {
  if (!input || input === '~') return homedir();
  if (input.startsWith('~/') || input.startsWith('~\\')) {
    return join(homedir(), input.slice(2));
  }
  return input;
}

const defaultCwd = expandHome(process.env.CLOUDPC_AGENT_CWD);
const powershell = process.env.CLOUDPC_POWERSHELL_BIN || [
  join(process.env.ProgramFiles || '', 'PowerShell', '7', 'pwsh.exe'),
  join(
    process.env.SystemRoot || 'C:\\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe'
  ),
].find(candidate => candidate && existsSync(candidate)) || 'powershell.exe';
const sessions = new Map();
const terminal = {
  child: null,
  status: 'stopped',
  events: [],
  clients: new Set(),
  seq: 0,
};

function json(res, status, body) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    let bytes = 0;
    let settled = false;
    const contentLength = Number(req.headers['content-length'] || 0);
    if (Number.isFinite(contentLength) && contentLength > maxBodyBytes) {
      req.resume();
      reject(new HttpError(413, 'request too large'));
      return;
    }
    req.setEncoding('utf8');
    req.on('data', chunk => {
      if (settled) return;
      bytes += Buffer.byteLength(chunk, 'utf8');
      if (bytes > maxBodyBytes) {
        settled = true;
        reject(new HttpError(413, 'request too large'));
        return;
      }
      body += chunk;
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new HttpError(400, 'invalid JSON'));
      }
    });
    req.on('error', error => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function createSession(input = {}) {
  if (sessions.size >= maxSessions) {
    throw new HttpError(
      503,
      `session limit reached (${maxSessions}); delete an existing session and retry`
    );
  }
  const cwd = typeof input.cwd === 'string' && input.cwd.trim()
    ? input.cwd.trim()
    : defaultCwd;
  if (!existsSync(cwd) || !statSync(cwd).isDirectory()) {
    throw new HttpError(400, `working directory not found: ${cwd}`);
  }
  const session = {
    id: randomUUID(),
    name: String(input.name || 'New engineering task').slice(0, 80),
    cwd,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    status: 'idle',
    turns: 0,
    events: [],
    clients: new Set(),
    child: null,
    seq: 0,
  };
  sessions.set(session.id, session);
  pushEvent(session, 'session', { status: 'idle', text: 'Session ready' });
  return session;
}

function summary(session) {
  return {
    id: session.id,
    name: session.name,
    cwd: session.cwd,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    status: session.status,
    turns: session.turns,
  };
}

function pushEvent(session, kind, data) {
  const event = {
    seq: ++session.seq,
    at: Date.now(),
    kind,
    data,
  };
  session.events.push(event);
  if (session.events.length > 2000) session.events.splice(0, 500);
  session.updatedAt = event.at;
  const frame = `data: ${JSON.stringify(event)}\n\n`;
  broadcast(session.clients, frame);
}

function pushTerminalEvent(kind, text) {
  const event = {
    seq: ++terminal.seq,
    at: Date.now(),
    kind,
    text: String(text || ''),
  };
  terminal.events.push(event);
  if (terminal.events.length > 1500) terminal.events.splice(0, 300);
  const frame = `data: ${JSON.stringify(event)}\n\n`;
  broadcast(terminal.clients, frame);
}

function broadcast(clients, frame) {
  for (const client of clients) {
    client.send(frame);
  }
}

function openEventStream(req, res, events, clients) {
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    'connection': 'keep-alive',
    'x-accel-buffering': 'no',
  });

  const maxQueuedBytes = 16 * 1024 * 1024;
  const client = {
    closed: false,
    queue: [],
    queuedBytes: 0,
    waitingForDrain: false,
    send(frame) {
      if (this.closed) return;
      const bytes = Buffer.byteLength(frame, 'utf8');
      if (this.queuedBytes + bytes > maxQueuedBytes) {
        this.close();
        return;
      }
      this.queue.push(frame);
      this.queuedBytes += bytes;
      this.flush();
    },
    flush() {
      if (this.closed || this.waitingForDrain) return;
      while (this.queue.length > 0) {
        const frame = this.queue.shift();
        this.queuedBytes -= Buffer.byteLength(frame, 'utf8');
        if (!res.write(frame)) {
          this.waitingForDrain = true;
          res.once('drain', () => {
            this.waitingForDrain = false;
            this.flush();
          });
          return;
        }
      }
    },
    close() {
      if (this.closed) return;
      this.closed = true;
      this.queue = [];
      this.queuedBytes = 0;
      clients.delete(this);
      if (!res.destroyed && !res.writableEnded) res.end();
    },
  };

  let heartbeat;
  const cleanup = () => {
    if (heartbeat) clearInterval(heartbeat);
    client.close();
  };
  res.on('close', cleanup);
  res.on('error', cleanup);
  req.on('aborted', cleanup);

  clients.add(client);
  client.send('retry: 1500\n\n');
  for (const event of events) {
    client.send(`data: ${JSON.stringify(event)}\n\n`);
    if (client.closed) return;
  }
  heartbeat = setInterval(() => {
    if (res.destroyed || res.writableEnded) {
      cleanup();
      return;
    }
    client.send(': ping\n\n');
  }, 15000);
  heartbeat.unref();
}

function terminalSummary() {
  return {
    status: terminal.status,
    cwd: defaultCwd,
    events: terminal.events,
  };
}

function startTerminal() {
  if (terminal.child && !terminal.child.killed) return terminal.child;

  const child = spawn(powershell, [
    '-NoLogo',
    '-NoProfile',
    '-NoExit',
    '-Command',
    '-',
  ], {
    cwd: defaultCwd,
    windowsHide: true,
    env: {
      ...process.env,
      NO_COLOR: '1',
    },
  });

  terminal.child = child;
  terminal.status = 'running';
  pushTerminalEvent('status', 'PowerShell connected');

  let finalized = false;
  const finalize = (status, text) => {
    if (finalized || terminal.child !== child) return;
    finalized = true;
    terminal.child = null;
    terminal.status = status;
    pushTerminalEvent('status', text);
  };
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => pushTerminalEvent('output', chunk));
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => pushTerminalEvent('error', chunk));
  child.stdin.on('error', error => {
    pushTerminalEvent('error', `${error.message}\n`);
  });
  child.on('error', error => {
    pushTerminalEvent('error', `${error.message}\n`);
    finalize('stopped', 'PowerShell failed to start');
  });
  child.on('close', code => {
    finalize('stopped', `PowerShell exited with code ${code}`);
  });

  const escapedCwd = defaultCwd.replace(/'/g, "''");
  child.stdin.write(
    "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(); " +
    "$OutputEncoding = [Console]::OutputEncoding; " +
    `Set-Location '${escapedCwd}'; ` +
    "Write-Output ('Connected to ' + $env:COMPUTERNAME); " +
    "Write-Output ('Working directory: ' + (Get-Location).Path)\r\n"
  );
  return child;
}

function stopTerminal() {
  const child = terminal.child;
  terminal.child = null;
  terminal.status = 'stopped';
  if (child && !child.killed) child.kill();
}

function extractText(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map(item => extractText(item?.text ?? item?.content ?? item)).filter(Boolean).join('');
  }
  if (!value || typeof value !== 'object') return '';
  return extractText(value.text ?? value.content ?? value.message ?? value.delta ?? '');
}

function classifyCopilotEvent(raw) {
  const type = String(raw?.type || raw?.event || raw?.kind || 'event');
  const data = raw?.data ?? raw;
  const text = extractText(
    data?.deltaContent ?? data?.content ?? data?.message ?? data?.delta ??
    data?.text ?? raw?.content
  );

  if (/assistant\.message_delta/i.test(type)) {
    return { kind: 'assistant', data: { type, text, append: true, raw } };
  }
  if (/assistant\.message$/i.test(type)) {
    return { kind: 'assistant', data: { type, text, final: true, raw } };
  }
  if (/^session\.(mcp|skills|tools|start|usage|model)/i.test(type)) {
    return null;
  }
  if (/assistant.*message|message.*assistant/i.test(type)) {
    return null;
  }
  if (/tool\.execution_start|tool.*start/i.test(type)) {
    const tool = data?.toolName || data?.name || data?.tool?.name || 'tool';
    return { kind: 'activity', data: { type, text: `Using ${tool}`, raw } };
  }
  if (/tool\.execution_complete|tool.*complete/i.test(type)) {
    return null;
  }
  if (/permission/i.test(type)) {
    return { kind: 'activity', data: { type, text: text || 'Permission required', raw } };
  }
  if (/plan|reason/i.test(type)) {
    return text ? { kind: 'activity', data: { type, text, raw } } : null;
  }
  if (/error|fail/i.test(type)) {
    return { kind: 'error', data: { type, text: text || type, raw } };
  }
  return null;
}

function runPrompt(session, prompt) {
  if (session.child) throw new HttpError(409, 'session is already running');
  session.status = 'running';
  session.turns += 1;
  if (session.turns === 1 && session.name === 'New engineering task') {
    session.name = prompt.replace(/\s+/g, ' ').trim().slice(0, 56) ||
      session.name;
  }
  pushEvent(session, 'user', { text: prompt });
  pushEvent(session, 'session', { status: 'running', text: 'Copilot is working' });

  const args = [
    '--prompt', prompt,
    '--session-id', session.id,
    '-C', session.cwd,
    '--output-format', 'json',
    '--stream', 'on',
    '--allow-all-tools',
    '--no-ask-user',
    '--no-remote',
    '--no-remote-export',
    '--no-color',
  ];
  const child = spawn(copilot, args, {
    cwd: session.cwd,
    windowsHide: true,
    env: {
      ...process.env,
      NO_COLOR: '1',
    },
  });
  session.child = child;

  let finalized = false;
  const finalize = (status, text) => {
    if (finalized || session.child !== child) return;
    finalized = true;
    session.child = null;
    session.status = status;
    pushEvent(session, 'session', { status, text });
  };
  let stdoutBuffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdoutBuffer += chunk;
    let newline;
    while ((newline = stdoutBuffer.indexOf('\n')) >= 0) {
      const line = stdoutBuffer.slice(0, newline).trim();
      stdoutBuffer = stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      try {
        const classified = classifyCopilotEvent(JSON.parse(line));
        if (classified) pushEvent(session, classified.kind, classified.data);
      } catch {
        pushEvent(session, 'assistant', { text: line });
      }
    }
  });

  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => {
    const text = chunk.trim();
    if (text) pushEvent(session, 'activity', { type: 'stderr', text });
  });

  child.on('error', error => {
    pushEvent(session, 'error', { text: error.message });
    finalize('failed', 'Copilot failed to start');
  });

  child.on('close', code => {
    if (finalized) return;
    if (stdoutBuffer.trim()) {
      try {
        const classified = classifyCopilotEvent(JSON.parse(stdoutBuffer.trim()));
        if (classified) pushEvent(session, classified.kind, classified.data);
      } catch {
        pushEvent(session, 'assistant', { text: stdoutBuffer.trim() });
      }
    }
    finalize(
      code === 0 ? 'idle' : 'failed',
      code === 0 ? 'Turn complete' : `Copilot exited with code ${code}`
    );
  });
}

function serveStatic(req, res) {
  const requestPath = req.url === '/' ? '/index.html' : req.url.split('?')[0];
  const safePath = normalize(requestPath).replace(/^([/\\])+/, '');
  const filePath = join(publicDir, safePath);
  const relativePath = relative(publicDir, filePath);
  if (
    relativePath.startsWith('..') ||
    isAbsolute(relativePath) ||
    !existsSync(filePath) ||
    !statSync(filePath).isFile()
  ) {
    return false;
  }
  const contentTypes = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
  };
  res.writeHead(200, {
    'content-type': contentTypes[extname(filePath)] || 'application/octet-stream',
    'cache-control': 'no-store',
  });
  res.end(readFileSync(filePath));
  return true;
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && url.pathname === '/api/health') {
      json(res, 200, {
        ok: true,
        name: 'cloudpc-tunnel',
        uptimeSeconds: Math.floor(process.uptime()),
        sessions: sessions.size,
        maxSessions,
        runningSessions: [...sessions.values()].filter(
          session => session.status === 'running'
        ).length,
        terminalStatus: terminal.status,
      });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/sessions') {
      json(res, 200, {
        sessions: [...sessions.values()].map(summary).sort((a, b) => b.updatedAt - a.updatedAt),
      });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/terminal') {
      startTerminal();
      json(res, 200, terminalSummary());
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/terminal/events') {
      startTerminal();
      openEventStream(req, res, terminal.events, terminal.clients);
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/terminal/input') {
      const body = await readBody(req);
      const input = String(body.input || '').trimEnd();
      if (!input) {
        json(res, 400, { error: 'terminal input is required' });
        return;
      }
      if (input.length > 8192) {
        json(res, 400, { error: 'terminal input is too long' });
        return;
      }
      const child = startTerminal();
      if (!child.stdin.writable) {
        json(res, 503, { error: 'PowerShell input stream is not available' });
        return;
      }
      pushTerminalEvent('input', input);
      child.stdin.write(`${input}\r\n`, error => {
        if (error) pushTerminalEvent('error', `${error.message}\n`);
      });
      json(res, 202, { ok: true, status: terminal.status });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/terminal/restart') {
      stopTerminal();
      terminal.events = [];
      terminal.seq = 0;
      startTerminal();
      json(res, 202, terminalSummary());
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/sessions') {
      const session = createSession(await readBody(req));
      json(res, 201, summary(session));
      return;
    }

    if (parts[0] === 'api' && parts[1] === 'sessions' && parts[2]) {
      const session = sessions.get(parts[2]);
      if (!session) {
        json(res, 404, { error: 'session not found' });
        return;
      }

      if (req.method === 'GET' && parts.length === 3) {
        json(res, 200, { ...summary(session), events: session.events });
        return;
      }

      if (req.method === 'GET' && parts[3] === 'events') {
        openEventStream(req, res, session.events, session.clients);
        return;
      }

      if (req.method === 'POST' && parts[3] === 'messages') {
        const body = await readBody(req);
        const prompt = String(body.prompt || '').trim();
        if (!prompt) {
          json(res, 400, { error: 'prompt is required' });
          return;
        }
        runPrompt(session, prompt);
        json(res, 202, summary(session));
        return;
      }

      if (req.method === 'POST' && parts[3] === 'abort') {
        if (session.child) {
          session.child.kill();
          pushEvent(session, 'activity', { type: 'abort', text: 'Abort requested' });
        }
        json(res, 202, summary(session));
        return;
      }

      if (req.method === 'DELETE' && parts.length === 3) {
        if (session.child) session.child.kill();
        for (const client of session.clients) client.close();
        sessions.delete(session.id);
        json(res, 200, { ok: true });
        return;
      }
    }

    if (req.method === 'GET' && serveStatic(req, res)) return;
    json(res, 404, { error: 'not found' });
  } catch (error) {
    if (!res.headersSent && !res.destroyed) {
      json(res, error.statusCode || 500, {
        error: error.message || String(error),
      });
    }
  }
});

server.requestTimeout = 30000;
server.headersTimeout = 10000;
server.keepAliveTimeout = 5000;
server.on('clientError', (error, socket) => {
  if (socket.writable) {
    socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  }
});
server.on('error', error => {
  console.error(`cloudpc-tunnel server error: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, host, () => {
  console.log(`cloudpc-tunnel listening on http://${host}:${port}`);
  console.log(`cwd=${defaultCwd}`);
  console.log(`copilot=${copilot}`);
});

let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`received ${signal}; shutting down`);

  stopTerminal();
  for (const session of sessions.values()) {
    if (session.child && !session.child.killed) session.child.kill();
    for (const client of session.clients) client.close();
    session.clients.clear();
  }
  for (const client of terminal.clients) client.close();
  terminal.clients.clear();

  const forceExit = setTimeout(() => process.exit(1), 5000);
  forceExit.unref();
  if (server.listening) {
    server.close(() => {
      clearTimeout(forceExit);
      process.exit(0);
    });
  } else {
    clearTimeout(forceExit);
    process.exit(process.exitCode || 0);
  }
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
