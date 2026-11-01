// 浏览器端验证：真实 Chrome + 真实 AudioWorklet。
// 用法：node tool/check_web_effects_dsp.mjs
// 作用：起一个静态服务器托管仓库根目录，用 headless Chrome 打开
//       tool/web_effects_dsp_check.html，轮询页面里的断言结果并打印。
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const PORT = 8765;
const DEVTOOLS_PORT = 9222;
const CHROME = '/usr/bin/google-chrome';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png'
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  let rel = decodeURIComponent(url.pathname);
  if (rel.endsWith('/')) rel += 'index.html';
  const file = path.join(root, rel);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise(r => server.listen(PORT, '127.0.0.1', r));

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'guitarbook-chrome-dsp-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  '--no-sandbox',
  '--disable-gpu',
  '--disable-dev-shm-usage',
  `--remote-debugging-port=${DEVTOOLS_PORT}`,
  `--user-data-dir=${profile}`,
  '--autoplay-policy=no-user-gesture-required',
  'about:blank'
], { stdio: 'ignore' });

function cleanup () {
  try { chrome.kill('SIGKILL'); } catch {}
  try { server.close(); } catch {}
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
}
process.on('exit', cleanup);

async function waitDevtools () {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`http://127.0.0.1:${DEVTOOLS_PORT}/json/version`);
      if (res.ok) return;
    } catch {}
    await new Promise(r => setTimeout(r, 200));
  }
  throw new Error('Chrome DevTools 未就绪');
}

let exitCode = 1;
try {
  await waitDevtools();
  const target = await (await fetch(`http://127.0.0.1:${DEVTOOLS_PORT}/json/new?${encodeURIComponent(`http://127.0.0.1:${PORT}/tool/web_effects_dsp_check.html`)}`, { method: 'PUT' })).json();
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  ws.addEventListener('message', ev => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve);
    ws.addEventListener('error', reject);
  });
  const send = (method, params) => new Promise(resolve => {
    const myId = ++id;
    pending.set(myId, resolve);
    ws.send(JSON.stringify({ id: myId, method, params }));
  });

  const expression = `new Promise((resolve) => {
    const started = Date.now();
    const timer = setInterval(() => {
      const el = document.getElementById('results');
      const txt = el ? el.textContent : '';
      if (txt && /passed$/.test(txt.trim())) { clearInterval(timer); resolve(txt); }
      else if (Date.now() - started > 60000) { clearInterval(timer); resolve('TIMEOUT\\n' + txt); }
    }, 200);
  })`;
  const out = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  const text = out.result && out.result.result ? out.result.result.value : JSON.stringify(out);
  console.log(text);
  exitCode = /FAIL/.test(text) || /TIMEOUT/.test(text) ? 1 : 0;
  ws.close();
} catch (e) {
  console.error('浏览器验证失败：', e && e.message);
} finally {
  cleanup();
}
process.exit(exitCode);
