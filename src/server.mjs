import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const publicDir = join(here, '..', 'public');
const host = process.env.CLOUDPC_AGENT_HOST || '127.0.0.1';
const port = Number(process.env.CLOUDPC_AGENT_PORT || 8787);
const copilot = process.env.COPILOT_BIN || 'copilot';
const defaultCwd = process.env.CLOUDPC_AGENT_CWD || process.cwd();
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
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error('request too large'));
        req.destroy();
      }
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error('invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function createSession(input = {}) {
  const cwd = typeof input.cwd === 'string' && input.cwd.trim()
    ? input.cwd.trim()
    : defaultCwd;
  if (!existsSync(cwd) || !statSync(cwd).isDirectory()) {
    throw new Error(`working directory not found: ${cwd}`);
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
    seq: session.events.length + 1,
    at: Date.now(),
    kind,
    data,
  };
  session.events.push(event);
  if (session.events.length > 2000) session.events.splice(0, 500);
  session.updatedAt = event.at;
  const frame = `data: ${JSON.stringify(event)}\n\n`;
  for (const client of session.clients) client.write(frame);
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
  for (const client of terminal.clients) client.write(frame);
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

  const child = spawn('pwsh.exe', [
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

  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => pushTerminalEvent('output', chunk));
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => pushTerminalEvent('error', chunk));
  child.on('error', error => {
    pushTerminalEvent('error', `${error.message}\n`);
  });
  child.on('close', code => {
    if (terminal.child !== child) return;
    terminal.child = null;
    terminal.status = 'stopped';
    pushTerminalEvent('status', `PowerShell exited with code ${code}`);
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

process.on('exit', stopTerminal);

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
  if (session.child) throw new Error('session is already running');
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
  });

  child.on('close', code => {
    if (stdoutBuffer.trim()) {
      try {
        const classified = classifyCopilotEvent(JSON.parse(stdoutBuffer.trim()));
        if (classified) pushEvent(session, classified.kind, classified.data);
      } catch {
        pushEvent(session, 'assistant', { text: stdoutBuffer.trim() });
      }
    }
    session.child = null;
    session.status = code === 0 ? 'idle' : 'failed';
    pushEvent(session, 'session', {
      status: session.status,
      text: code === 0 ? 'Turn complete' : `Copilot exited with code ${code}`,
    });
  });
}

function serveStatic(req, res) {
  const requestPath = req.url === '/' ? '/index.html' : req.url.split('?')[0];
  const safePath = normalize(requestPath).replace(/^([/\\])+/, '');
  const filePath = join(publicDir, safePath);
  if (!filePath.startsWith(publicDir) || !existsSync(filePath) || !statSync(filePath).isFile()) {
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
      json(res, 200, { ok: true, name: 'cloudpc-agent', sessions: sessions.size });
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
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      });
      res.write('retry: 1500\n\n');
      for (const event of terminal.events) {
        res.write(`data: ${JSON.stringify(event)}\n\n`);
      }
      terminal.clients.add(res);
      const heartbeat = setInterval(() => res.write(': ping\n\n'), 15000);
      req.on('close', () => {
        clearInterval(heartbeat);
        terminal.clients.delete(res);
      });
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
      pushTerminalEvent('input', input);
      child.stdin.write(`${input}\r\n`);
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
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          'connection': 'keep-alive',
          'x-accel-buffering': 'no',
        });
        res.write('retry: 1500\n\n');
        for (const event of session.events) {
          res.write(`data: ${JSON.stringify(event)}\n\n`);
        }
        session.clients.add(res);
        const heartbeat = setInterval(() => res.write(': ping\n\n'), 15000);
        req.on('close', () => {
          clearInterval(heartbeat);
          session.clients.delete(res);
        });
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
        for (const client of session.clients) client.end();
        sessions.delete(session.id);
        json(res, 200, { ok: true });
        return;
      }
    }

    if (req.method === 'GET' && serveStatic(req, res)) return;
    json(res, 404, { error: 'not found' });
  } catch (error) {
    json(res, 500, { error: error.message });
  }
});

server.listen(port, host, () => {
  console.log(`cloudpc-agent listening on http://${host}:${port}`);
  console.log(`cwd=${defaultCwd}`);
  console.log(`copilot=${copilot}`);
});
