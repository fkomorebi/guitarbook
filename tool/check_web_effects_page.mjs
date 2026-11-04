// 端到端验证：真实 Flutter Web 产物 + 真实 Chrome + 假麦克风设备。
// 用法：node tool/check_web_effects_page.mjs（需先执行 flutter build web --release）
//
// 阶段 A（用户从首页点进「即兴工作台」，滚到页面下方的效果器区再点「开始监听」）：
//   AudioContext running → getUserMedia 约束 → AudioWorkletNode → 电平回报 → 添加内置单块。
// 阶段 B（刷新页面后用 DOM click 进入即兴工作台，刻意不产生用户激活）：
//   进入工作台只做设备检测，不开麦；随后真实点击「开始监听」按钮 → 音频链路跑通。
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const WEB_ROOT = path.join(root, 'build', 'web');
const PORT = 8766;
const DEVTOOLS_PORT = 9333;
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

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'guitarbook-chrome-page-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  '--no-sandbox',
  '--disable-gpu',
  '--disable-dev-shm-usage',
  // 某些桌面环境给 Chrome 配了系统代理，会把 127.0.0.1 也送去代理，页面永远加载不完。
  '--no-proxy-server',
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

  // 截图存档（用于人工核对画布上的真实渲染，语义树不暴露的文本也能看到）。
  const capture = async (file) => {
    const out = await send('Page.captureScreenshot', { format: 'png' });
    if (!out || !out.result || !out.result.data) {
      console.log('截图失败：' + file);
      return false;
    }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.from(out.result.data, 'base64'));
    console.log('截图已保存：' + file);
    return true;
  };

  await send('Page.enable');
  await send('Runtime.enable');

  // 探针：记录 AudioContext / getUserMedia / AudioWorkletNode / meter；
  // 并把 navigator.userActivation.hasBeenActive 改成「只有真实 pointerdown 之后才为真」，
  // 用于制造「没有用户激活」的场景（DOM click 不算用户激活）。
  await send('Page.addScriptToEvaluateOnNewDocument', {
    source: `
      window.__probe = { contexts: [], nodes: [], gum: [], gumSettings: [], meters: [], errors: [], workletErrors: [], mstpCount: 0 };
      window.__realActivation = false;
      window.addEventListener('pointerdown', () => { window.__realActivation = true; }, true);
      window.addEventListener('error', e => window.__probe.errors.push(String(e.message)));
      window.addEventListener('unhandledrejection', e => window.__probe.errors.push('unhandled: ' + String(e.reason)));
      try {
        const UA = navigator.userActivation;
        if (UA) {
          Object.defineProperty(UA, 'hasBeenActive', {
            configurable: true,
            get() { return window.__realActivation ? true : false; }
          });
        }
      } catch (e) {}
      const OrigAC = window.AudioContext;
      function PatchedAC(...args) {
        const ctx = new OrigAC(...args);
        window.__probe.contexts.push(ctx);
        return ctx;
      }
      PatchedAC.prototype = OrigAC.prototype;
      Object.setPrototypeOf(PatchedAC, OrigAC);
      window.AudioContext = PatchedAC;
      const OrigWN = window.AudioWorkletNode;
      function PatchedWN(ctx, name, options) {
        const node = new OrigWN(ctx, name, options);
        window.__probe.nodes.push({ name, ctx });
        node.port.addEventListener('message', e => {
          const d = e.data || {};
          if (d.type === 'meter') window.__probe.meters.push(d);
          else window.__probe.workletErrors.push(d);
        });
        return node;
      }
      PatchedWN.prototype = OrigWN.prototype;
      Object.setPrototypeOf(PatchedWN, OrigWN);
      window.AudioWorkletNode = PatchedWN;
      const md = navigator.mediaDevices;
      if (md && md.getUserMedia) {
        const orig = md.getUserMedia.bind(md);
        md.getUserMedia = async (c) => {
          window.__probe.gum.push(JSON.stringify(c));
          const s = await orig(c);
          try {
            const t = s.getAudioTracks()[0];
            const st = t ? t.getSettings() : null;
            window.__probe.gumSettings.push(st ? {
              sampleRate: st.sampleRate,
              channelCount: st.channelCount,
              latency: st.latency
            } : null);
          } catch (e) {}
          return s;
        };
      }
      // 记录低延迟采集（MediaStreamTrackProcessor）是否被真正使用。
      const OrigMSTP = window.MediaStreamTrackProcessor;
      if (OrigMSTP) {
        function PatchedMSTP(init) {
          const p = new OrigMSTP(init);
          window.__probe.mstpCount += 1;
          return p;
        }
        PatchedMSTP.prototype = OrigMSTP.prototype;
        Object.setPrototypeOf(PatchedMSTP, OrigMSTP);
        window.MediaStreamTrackProcessor = PatchedMSTP;
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
        al: al.slice(0, 40),
        txt: txt.slice(0, 40),
        x: r.x + r.width / 2, y: r.y + r.height / 2,
        area: Math.round(r.width * r.height),
        inView: r.top >= 0 && r.bottom <= window.innerHeight
      });
    }
    cands.sort((a, b) => (a.role === 'button' ? 0 : 1) - (b.role === 'button' ? 0 : 1) || a.area - b.area);
    return cands;
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

  // 诊断：直接看语义 DOM 里「效果链」计数字段的原文（区分渲染缺失与文案变化）。
  const chainHtml = async () => {
    const out = await evaluate(`(() => {
      const host = document.querySelector('flt-semantics-host') || document.body;
      const html = host.innerHTML || '';
      const i = html.indexOf('效果链');
      const txt = host.textContent || '';
      const j = txt.indexOf('效果链');
      return {
        inHtml: i >= 0,
        htmlSnippet: i >= 0 ? html.slice(Math.max(0, i - 60), i + 120) : null,
        textSnippet: j >= 0 ? txt.slice(Math.max(0, j - 20), j + 40) : null
      };
    })()`);
    console.log('效果链字段诊断：' + JSON.stringify(out));
    return out;
  };

  // 滚动 Flutter 画布：效果器在即兴工作台页面底部，需要先把区域滚进视口。
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

  // 真实鼠标点击（会产生用户激活）
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

  // DOM click（不产生用户激活）
  const domClick = async (label) => evaluate(`(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    for (const n of host.querySelectorAll('flt-semantics[role="button"], [role="button"]')) {
      const al = (n.getAttribute('aria-label') || '');
      const txt = (n.textContent || '').trim();
      if (al.includes(${JSON.stringify(label)}) || txt.includes(${JSON.stringify(label)})) { n.click(); return true; }
    }
    return false;
  })()`);

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

  const readProbe = () => evaluate(`(() => {
    const p = window.__probe;
    const ctx = p.contexts[p.contexts.length - 1];
    return {
      contexts: p.contexts.length,
      states: p.contexts.map(c => c.state),
      state: ctx ? ctx.state : null,
      sampleRate: ctx ? ctx.sampleRate : null,
      baseLatency: ctx ? ctx.baseLatency : null,
      outputLatency: ctx ? ctx.outputLatency : null,
      gum: p.gum,
      nodes: p.nodes.map(n => n.name),
      meterCount: p.meters.length,
      maxInput: p.meters.reduce((a, m) => Math.max(a, Number(m.input) || 0), 0),
      maxOutput: p.meters.reduce((a, m) => Math.max(a, Number(m.output) || 0), 0),
      workletErrors: p.workletErrors.slice(0, 5),
      errors: p.errors.slice(0, 5),
      mstpCount: p.mstpCount || 0,
      mstpSupported: typeof window.MediaStreamTrackProcessor === 'function',
      gumSettings: p.gumSettings || []
    };
  })()`);

  const checkAudioChain = (prefix, probe) => {
    check(prefix + '：创建了 AudioContext', probe.contexts >= 1, 'contexts=' + probe.contexts);
    check(prefix + '：AudioContext 处于 running', probe.state === 'running', 'state=' + probe.state);
    check(prefix + '：调用了 getUserMedia', probe.gum.length >= 1, (probe.gum[0] || ''));
    const gumObj = probe.gum.length ? JSON.parse(probe.gum[0]) : {};
    const audio = gumObj.audio || {};
    check(prefix + '：getUserMedia 关闭 AGC/降噪/回声消除且单声道',
      audio.echoCancellation === false && audio.noiseSuppression === false &&
      audio.autoGainControl === false && audio.channelCount === 1,
      JSON.stringify(audio));
    check(prefix + '：创建了 AudioWorkletNode("guitarbook-effects")',
      probe.nodes.includes('guitarbook-effects'), JSON.stringify(probe.nodes));
    check(prefix + '：worklet 回报了电平（meter）', probe.meterCount >= 1, 'count=' + probe.meterCount);
    check(prefix + '：输入电平曾 > 0（假麦克风有信号）', probe.maxInput > 0, 'maxInput=' + probe.maxInput);
    check(prefix + '：输出电平曾 > 0（音频到达 destination）', probe.maxOutput > 0, 'maxOutput=' + probe.maxOutput);
    const ratio = probe.maxInput ? probe.maxOutput / probe.maxInput : 0;
    check(prefix + '：输出 = 输入 × 输出音量 50%', Math.abs(ratio - 0.5) < 1e-6, 'ratio=' + ratio);
    check(prefix + '：页面无未捕获异常', probe.errors.length === 0, JSON.stringify(probe.errors));
    check(prefix + '：worklet 未上报 error', probe.workletErrors.length === 0, JSON.stringify(probe.workletErrors));
    if (probe.mstpSupported) {
      // 低延迟采集只在「采集采样率 == 上下文采样率」时启用；
      // 采样率不同必须回退兼容路径，否则播放速率会错。
      const track = (probe.gumSettings || [])[0] || {};
      const sameRate = !track.sampleRate || track.sampleRate === probe.sampleRate;
      if (sameRate) {
        check(prefix + '：使用低延迟采集（MediaStreamTrackProcessor）',
          probe.mstpCount >= 1, 'mstpCount=' + probe.mstpCount);
      } else {
        check(prefix + '：采集采样率与上下文不同，已回退兼容采集路径',
          probe.mstpCount === 0,
          'track=' + track.sampleRate + ' ctx=' + probe.sampleRate);
      }
    }
  };

  // 导航并等待页面可交互；在受限沙箱里 Chrome 可能根本连不上 127.0.0.1，
  // 甚至 Page.navigate 本身都不返回，所以整体加 20 秒超时并给出可执行的报错。
  const navigate = async (url) => {
    const timer = new Promise((_, reject) => {
      setTimeout(() => reject(new Error('页面在 20 秒内没有加载完成：' + url +
        '（若在受限沙箱内运行，Chrome 可能无法访问 127.0.0.1；改用常规桌面会话或 file:// 探针）')), 20000);
    });
    const load = (async () => {
      const nav = await send('Page.navigate', { url });
      if (nav.errorText) throw new Error('页面导航失败：' + nav.errorText);
      const started = Date.now();
      while (Date.now() - started < 19000) {
        await sleep(250);
        try {
          const ready = await evaluate('document.readyState');
          if (ready === 'complete' || ready === 'interactive') return;
        } catch {}
      }
    })();
    try { await Promise.race([load, timer]); }
    catch (err) { load.catch(() => {}); throw err; }
  };

  // ---------- 阶段 A：从首页进入即兴工作台 → 滚到效果器区 → 真实点击「开始监听」 ----------
  console.log('\n===== 阶段 A：首页进入即兴工作台 → 点击「开始监听」 =====');
  await navigate(`http://127.0.0.1:${PORT}/index.html`);
  await waitFlutter();
  await realClick('即兴工作台');
  check('A：进入「即兴工作台」页', await pageHas('鼓机音量')(), '');
  const effectsInView = await scrollUntilVisible('效果链 · 0/8');
  check('A：滚到工作台下方的效果器区', effectsInView && await pageHas('效果链 · 0/8')(), '');
  await chainHtml();
  await realClick('开始监听');
  await sleep(4000);
  let probeA = await readProbe();
  console.log('探针 A：' + JSON.stringify(probeA));
  checkAudioChain('A', probeA);
  check('A：页面显示「正在监听」', await pageHas('正在监听')(), '');

  // 添加一块过载，验证 Dart → worklet → status → UI 的往返
  await scrollToLabel('过载');
  await realClick('过载');
  await sleep(800);
  await chainHtml();
  const chainLabels = await dumpSemantics('效果链|过载|驱动|音色|信号链');
  // 效果板的无障碍标签会写出当前串联顺序，计数文案也可能被合并进父节点。
  const chainAdded = chainLabels.some(t => /信号链：吉他输入 → 过载 Overdrive/.test(t.al || '')) ||
    chainLabels.some(t => /效果链 · 1\/8/.test((t.al || '') + ' ' + (t.txt || '')));
  check('A：从效果库添加「过载」并写入效果链', chainAdded,
    JSON.stringify(chainLabels.slice(0, 3)));
  const knobLabels = await evaluate(`(() => {
    const host = document.querySelector('flt-semantics-host') || document.body;
    const out = new Set();
    for (const n of host.querySelectorAll('*')) {
      const al = (n.getAttribute && n.getAttribute('aria-label')) || '';
      if (al) out.add(al);
    }
    return Array.from(out).filter(t => /驱动|音色/.test(t)).slice(0, 8);
  })()`);
  check('A：过载旋钮参数已渲染', (knobLabels || []).length >= 2, JSON.stringify(knobLabels));

  // 截图存档：确认「效果链 · N/8」计数在画布上真实可见（语义树可能不暴露该文本）。
  await capture(path.join(root, '.tmp', 'effects_after_overdrive.png'));

  // 诊断面板：确认页面写出了当前采集链路（低延迟插入式流或兼容路径）。
  await scrollToLabel('声卡设置与延迟诊断');
  await realClick('声卡设置与延迟诊断');
  await sleep(1500);
  const hasMstpText = await pageHas('采集链路：低延迟插入式流')();
  const hasFallbackText = await pageHas('采集链路：兼容路径')();
  check('A：诊断面板显示采集链路', hasMstpText || hasFallbackText,
    'mstp=' + hasMstpText + ' fallback=' + hasFallbackText);

  // ---------- 阶段 B：无用户激活进入工作台 → 只做设备检测 → 真实点击「开始监听」 ----------
  console.log('\n===== 阶段 B：无用户激活进入即兴工作台 → 点击「开始监听」 =====');
  await send('Page.reload');
  await waitFlutter();
  const domClicked = await domClick('即兴工作台');
  check('B：用 DOM click 进入即兴工作台（不产生用户激活）', domClicked, '');
  await sleep(4000);
  const probeB0 = await readProbe();
  check('B：检测阶段未打开麦克风、未开始处理',
    probeB0.gum.length === 0 && probeB0.meterCount === 0 && probeB0.contexts === 0,
    'gum=' + probeB0.gum.length + ' meters=' + probeB0.meterCount + ' contexts=' + probeB0.contexts);
  // 效果器面板在工作台底部：先滚进视口，再断言面板文案确实提示「尚未开始监听」。
  await scrollToLabel('开始监听');
  const statusNodes = await dumpSemantics('尚未开始监听|可用性以设备实际打开结果为准|正在检查效果器|检测通过');
  check('B：进入工作台只做设备检测，提示尚未开始监听',
    statusNodes.some(t => /尚未开始监听/.test((t.al || '') + ' ' + (t.txt || ''))),
    JSON.stringify(statusNodes.slice(0, 3)));

  await realClick('开始监听');
  await sleep(5000);
  const probeB = await readProbe();
  console.log('探针 B：' + JSON.stringify(probeB));
  checkAudioChain('B', probeB);

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
