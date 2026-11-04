// 端到端验证：真实 Flutter Web 产物 + 真实 Chrome + 注入的假手柄。
// 用法：node tool/check_web_gamepad_page.mjs（需先执行 flutter build web --release）
//
// 目的：验证网页端「手柄线性扳机 → 哇音踏板」卡片确实能从浏览器 Gamepad API
// 读到扳机模拟量并显示「已连接：<手柄名>」与原始读数。
// 浏览器会把 navigator.getGamepads() 标准化后再交给页面，注入的假手柄因此可以
// 复现真实手柄（标准映射，button 6 = L2、button 7 = R2）的行为。
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const WEB_ROOT = path.join(root, 'build', 'web');
const PORT = 8767;
const DEVTOOLS_PORT = 9334;
const CHROME = '/usr/bin/google-chrome';

if (!fs.existsSync(path.join(WEB_ROOT, 'index.html'))) {
  console.error('缺少 build/web，请先执行 flutter build web --release');
  process.exit(2);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.wasm': 'application/wasm',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.csv': 'text/csv',
  '.symbols': 'text/plain'
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  let rel = decodeURIComponent(url.pathname);
  if (rel.endsWith('/')) rel += 'index.html';
  const file = path.join(WEB_ROOT, rel);
  if (!file.startsWith(WEB_ROOT) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise(r => server.listen(PORT, '127.0.0.1', r));

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'guitarbook-chrome-gamepad-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  '--no-sandbox',
  '--disable-gpu',
  '--disable-dev-shm-usage',
  '--window-size=1400,2200',
  '--use-fake-device-for-media-stream',
  '--use-fake-ui-for-media-stream',
  `--remote-debugging-port=${DEVTOOLS_PORT}`,
  `--user-data-dir=${profile}`,
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

const results = [];
function check (name, ok, detail) {
  results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
  console.log((ok ? 'PASS  ' : 'FAIL  ') + name + (detail ? '   [' + detail + ']' : ''));
}

let exitCode = 1;
try {
  await waitDevtools();
  const target = await (await fetch(`http://127.0.0.1:${DEVTOOLS_PORT}/json/new?about:blank`, { method: 'PUT' })).json();
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
  const evaluate = async (expression, awaitPromise) => {
    const out = await send('Runtime.evaluate', { expression, awaitPromise: !!awaitPromise, returnByValue: true });
    if (out.result && out.result.exceptionDetails) {
      throw new Error(out.result.exceptionDetails.text + ' ' + ((out.result.exceptionDetails.exception || {}).description || ''));
    }
    return out.result && out.result.result ? out.result.result.value : undefined;
  };
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  await send('Page.enable');
  await send('Runtime.enable');

  // 注入假手柄：标准映射，button 6 = L2、button 7 = R2（右扳机模拟量可调）。
  await send('Page.addScriptToEvaluateOnNewDocument', {
    source: `
      window.__gpErrors = [];
      window.__gpState = { connected: true, right: 0.5, left: 0 };
      const makeButtons = () => {
        const list = [];
        for (let i = 0; i < 8; i++) list.push({ pressed: false, touched: false, value: 0 });
        list[6] = { pressed: window.__gpState.left > 0, touched: false, value: window.__gpState.left };
        list[7] = { pressed: window.__gpState.right > 0, touched: false, value: window.__gpState.right };
        return list;
      };
      const fakePad = {
        get id() { return 'Flydigi Apex 5 (Vendor: 0e6f Product: 0205)'; },
        get index() { return 0; },
        get connected() { return window.__gpState.connected; },
        get mapping() { return 'standard'; },
        get timestamp() { return Date.now(); },
        get axes() { return [0, 0, 0, 0]; },
        get buttons() { return makeButtons(); }
      };
      const getGamepads = function () {
        try {
          return window.__gpState.connected ? [fakePad] : [];
        } catch (e) {
          window.__gpErrors.push(String(e));
          return [];
        }
      };
      try {
        Object.defineProperty(Navigator.prototype, 'getGamepads', {
          configurable: true,
          writable: true,
          value: getGamepads
        });
      } catch (e) {
        window.__gpErrors.push('defineProperty: ' + String(e));
        try { Object.defineProperty(navigator, 'getGamepads', { configurable: true, value: getGamepads }); }
        catch (e2) { window.__gpErrors.push('instance defineProperty: ' + String(e2)); }
      }
    `
  });

  const waitFlutter = async () => {
    await evaluate(`new Promise(resolve => {
      const started = Date.now();
      const timer = setInterval(() => {
        const glass = document.querySelector('flt-glass-pane, flutter-view, flt-scene-host');
        if (glass || Date.now() - started > 30000) { clearInterval(timer); resolve(true); }
      }, 200);
    })`, true);
    await sleep(2500);
    await evaluate(`(() => {
      const ph = document.querySelector('flt-semantics-placeholder');
      if (ph) { ph.click(); return 'clicked'; }
      return document.querySelector('flt-semantics-host') ? 'already-on' : 'no-placeholder';
    })()`);
    await sleep(1500);
  };

  const findCandidates = (label) => evaluate(`(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    const nodes = host.querySelectorAll('flt-semantics, [role], [aria-label]');
    const cands = [];
    for (const n of nodes) {
      const al = (n.getAttribute('aria-label') || '');
      const txt = (n.textContent || '').trim();
      if (!al.includes(${JSON.stringify(label)}) && !txt.includes(${JSON.stringify(label)})) continue;
      const r = n.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) continue;
      cands.push({
        tag: n.tagName.toLowerCase(),
        role: n.getAttribute('role') || '',
        al: al.slice(0, 60),
        txt: txt.slice(0, 60),
        x: r.x + r.width / 2, y: r.y + r.height / 2,
        area: Math.round(r.width * r.height),
        inView: r.top >= 0 && r.bottom <= window.innerHeight
      });
    }
    cands.sort((a, b) => (a.role === 'button' ? 0 : 1) - (b.role === 'button' ? 0 : 1) || a.area - b.area);
    return cands;
  })()`);

  // 找出语义树里所有匹配正则的标签（带位置），用于诊断与滚动定位。
  const findLabels = (pattern) => evaluate(`(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    const re = new RegExp(${JSON.stringify(pattern)});
    const out = [];
    for (const n of host.querySelectorAll('*')) {
      const al = (n.getAttribute && n.getAttribute('aria-label')) || '';
      const txt = (n.textContent || '').trim();
      const s = al || txt;
      if (!s || !re.test(s)) continue;
      const r = n.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) continue;
      out.push({
        al: al.slice(0, 60), txt: txt.slice(0, 60),
        x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2),
        inView: r.top >= 0 && r.bottom <= window.innerHeight
      });
    }
    return out.slice(0, 12);
  })()`);

  // 诊断：抓语义树里匹配正则的节点（含 aria-label、文本内容与尺寸）。
  const dumpSemantics = async (pattern) => {
    const out = await evaluate(`(() => {
      const host = document.querySelector('flt-semantics-host') || document.body;
      const re = new RegExp(${JSON.stringify(pattern)});
      const out = [];
      for (const n of host.querySelectorAll('*')) {
        const al = (n.getAttribute && n.getAttribute('aria-label')) || '';
        const txt = (n.textContent || '').trim();
        if (!re.test(al) && !re.test(txt)) continue;
        const r = n.getBoundingClientRect();
        out.push({
          tag: n.tagName.toLowerCase(), role: n.getAttribute('role') || '',
          al: al.slice(0, 90), txt: txt.slice(0, 90),
          w: Math.round(r.width), h: Math.round(r.height), y: Math.round(r.y)
        });
      }
      return out.slice(0, 40);
    })()`);
    console.log('语义诊断[' + pattern + ']：' + JSON.stringify(out));
    return out;
  };

  // 滚动 Flutter 画布：效果器与手柄卡片都在即兴工作台页面下方，需要滚进视口。
  // 注意：语义节点上的 scrollIntoView 对 Flutter 画布无效，只能走输入事件。
  const scrollBy = async (deltaY) => {
    await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 700, y: 1200, deltaX: 0, deltaY });
    await sleep(220);
  };

  // 把目标文案的语义节点滚进视口：目标可能在下方（工作台底部），也可能在上方（回滚后）。
  const scrollToLabel = async (label, maxSteps = 40) => {
    for (let i = 0; i <= maxSteps; i++) {
      const cands = await findCandidates(label);
      const vh = (await evaluate('window.innerHeight')) || 2200;
      if (cands && cands.length) {
        const t = cands[0];
        if (t.y > 0 && t.y < vh - 20) return true;
        await scrollBy(t.y >= vh - 20 ? 600 : -600);
      } else {
        await scrollBy(600);
      }
    }
    const cands = await findCandidates(label);
    return !!(cands && cands.length && cands[0].inView);
  };

  const realClick = async (label) => {
    let cands = await findCandidates(label);
    console.log('--- 候选「' + label + '」--- ' + JSON.stringify(cands.slice(0, 3)));
    if (!cands || !cands.length) return false;
    if (!cands[0].inView) {
      await scrollToLabel(label);
      cands = await findCandidates(label);
      if (!cands || !cands.length) return false;
    }
    const t = cands[0];
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: t.x, y: t.y, button: 'none', clickCount: 0 });
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: t.x, y: t.y, button: 'left', clickCount: 1 });
    await sleep(80);
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: t.x, y: t.y, button: 'left', clickCount: 1 });
    await sleep(1200);
    return true;
  };

  // 反复下滚，直到目标文案的语义节点完全进入视口（仅向下）。
  const scrollUntilVisible = async (label, maxSteps = 40) => {
    for (let i = 0; i <= maxSteps; i++) {
      const cands = await findCandidates(label);
      if (cands && cands.length && cands[0].inView) return true;
      await scrollBy(600);
    }
    const cands = await findCandidates(label);
    return !!(cands && cands.length && cands[0].inView);
  };

  const pageHas = (text) => async () => {
    const has = await evaluate(`(() => {
      const host = document.querySelector('flt-semantics-host') || document.body;
      for (const n of host.querySelectorAll('*')) {
        const al = n.getAttribute && n.getAttribute('aria-label');
        if (al && al.includes(${JSON.stringify(text)})) return true;
        const txt = (n.textContent || '').trim();
        if (txt && txt.includes(${JSON.stringify(text)})) return true;
      }
      return false;
    })()`);
    return !!has;
  };

  const pageText = () => evaluate(`(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    const out = [];
    for (const n of host.querySelectorAll('*')) {
      const al = n.getAttribute && n.getAttribute('aria-label');
      if (al) out.push(al);
    }
    return out;
  })()`);

  console.log('\n===== 阶段 A：进入即兴工作台并添加哇音 =====');
  await send('Page.navigate', { url: `http://127.0.0.1:${PORT}/index.html` });
  await waitFlutter();
  await realClick('即兴工作台');
  check('A：进入「即兴工作台」页', await pageHas('鼓机音量')(), '');
  const effectsInView = await scrollUntilVisible('效果链 · 0/8');
  check('A：滚到工作台下方的效果器区', effectsInView && await pageHas('效果链 · 0/8')(), '');
  await sleep(3000);

  await scrollToLabel('哇音');
  await realClick('哇音');
  await sleep(800);
  const chainLabels = await dumpSemantics('效果链|哇音|自动|手动');
  check('A：添加「哇音 Wah」到效果链',
    chainLabels.some(t => /效果链 · 1\/8/.test((t.al || '') + ' ' + (t.txt || ''))),
    JSON.stringify(chainLabels.slice(0, 3)));

  console.log('\n===== 阶段 B：启用手柄踏板并读取 Gamepad API =====');
  await scrollToLabel('启用手柄踏板');
  const clickedSwitch = await realClick('启用手柄踏板');
  check('B：点击「启用手柄踏板」开关', clickedSwitch, '');
  await sleep(1500);

  const injectedOk = await evaluate(`(() => {
    try {
      const pads = navigator.getGamepads();
      return { count: pads.length, id: pads.length ? pads[0].id : '', errs: window.__gpErrors || [] };
    } catch (e) {
      return { count: -1, id: '', errs: [String(e)] };
    }
  })()`);
  console.log('注入状态：' + JSON.stringify(injectedOk));
  check('B：页面里的 navigator.getGamepads() 返回假手柄',
    injectedOk.count === 1 && injectedOk.id.indexOf('Flydigi Apex 5') >= 0, JSON.stringify(injectedOk));

  check('B：卡片显示「已连接：Flydigi Apex 5」', await pageHas('已连接：Flydigi Apex 5')(), '');
  check('B：卡片显示原始读数 128（0.5 × 255）', await pageHas('原始读数 128')(), '');
  check('B：卡片显示量程 0–255', await pageHas('量程 0–255')(), '');

  console.log('\n===== 阶段 C：扳机变化会刷新读数 =====');
  await evaluate(`window.__gpState.right = 0.9; true`);
  await sleep(1200);
  const rawText = (await pageText()).filter(t => t.indexOf('原始读数') >= 0);
  console.log('读数文案：' + JSON.stringify(rawText.slice(0, 3)));
  check('C：踩下扳机后原始读数更新为 230', await pageHas('原始读数 230')(), JSON.stringify(rawText.slice(0, 2)));

  await evaluate(`window.__gpState.right = 0.0; true`);
  await sleep(1200);
  check('C：松开扳机后原始读数回到 0', await pageHas('原始读数 0')(), '');

  console.log('\n===== 阶段 D：手柄断开后给出重新查找提示 =====');
  await evaluate(`window.__gpState.connected = false; true`);
  await sleep(1500);
  const statusLabels = (await pageText()).filter(t => /手柄|扳机|查找|断开/.test(t));
  console.log('断开后的状态文案：' + JSON.stringify(statusLabels.slice(0, 4)));
  check('D：断开后显示「手柄已断开，正在重新查找…」', await pageHas('手柄已断开')(), '');

  const gpErrors = await evaluate(`JSON.stringify(window.__gpErrors || [])`);
  check('D：注入脚本无异常', gpErrors === '[]', gpErrors);

  const failed = results.filter(r => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} passed`);
  exitCode = failed === 0 ? 0 : 1;
  ws.close();
} catch (e) {
  console.error('端到端验证失败：', e && (e.stack || e.message));
} finally {
  cleanup();
}
process.exit(exitCode);
