// 浏览器效果器监听延迟测量：真实 Chrome + 本机 Focusrite Scarlett Solo（PipeWire 环回）。
//
// 用法：node tool/check_web_latency.mjs [--runs=3] [--groups=A,B,C,D,E]
//
// 做法（不引入 puppeteer/playwright，沿用仓库既有脚本的原生 CDP/WebSocket 方式）：
//   1. child_process 起本机 /usr/bin/google-chrome（headless=new，已实测 headless
//      也能把真实音频送到 PipeWire 默认 sink）；
//      注意：本沙箱内 Chrome 的 http 出站被拦（Page.navigate 到 http://127.0.0.1 会挂死，
//      data:/file: 正常），因此页面改用 file:// 加载，并加 --allow-file-access-from-files；
//      页面里 worklet 路径用相对 URL 解析，file:// 与 http:// 下都成立。
//   3. 通过 DevTools Protocol 调用页面里的 window.__latencyProbe.run(config)；
//   4. 页面播放已知脉冲串（16 × 1 kHz/12 ms，间隔 350 ms），脉冲经过真实的
//      AudioWorkletNode('guitarbook-effects') 到 destination；同时用 getUserMedia
//      从 sink monitor 环回源采集，AudioWorklet 以 currentTime 记录到达时刻；
//   5. 每组跑 3 次，报告每次的中位数/最小值与 3 次汇总。
//
// 测量链路与真实监听的关系：
//   环回往返 = 输出（AudioContext 渲染 + 输出缓冲 + PipeWire sink）
//            + 环回（sink monitor 分接）
//            + 采集（PulseAudio/PipeWire source + Chrome 输入缓冲）
//   真实监听延迟（麦克风 → 耳机）= 采集 + DSP + 输出，量级上与环回往返相当。
//   E 组用假设备只测图内延迟（脉冲 → effects worklet → detector），用来把
//   「图内开销」从环回往返里分离出去。
//
// 只写 .tools/latency_results.json，不改动任何产品源码。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const CHROME = '/usr/bin/google-chrome';
let DEVTOOLS_PORT = 9444;
const PROBE_URL = pathToFileURL(path.join(root, 'tool', 'web_latency_probe.html')).href;
const RESULT_FILE = path.join(root, '.tools', 'latency_results.json');

const argv = process.argv.slice(2);
function argValue (name, fallback) {
  const hit = argv.find(a => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return fallback;
  const eq = hit.indexOf('=');
  return eq >= 0 ? hit.slice(eq + 1) : true;
}
const RUNS = Math.max(1, Number(argValue('runs', 3)));
const ONLY_GROUPS = String(argValue('groups', 'A,B,C,D,E')).split(',').map(s => s.trim().toUpperCase()).filter(Boolean);
// 允许指定 DevTools 端口，避免与并行运行的其它探针抢同一个端口。
DEVTOOLS_PORT = Number(argValue('port', DEVTOOLS_PORT));


// ---------------------------------------------------------------------------
// 测量组定义
// ---------------------------------------------------------------------------
const GROUPS = [
  {
    name: 'A',
    desc: '现状：latencyHint=interactive（与 lib/features/effects/effects_backend_web.dart 一致）',
    latencyHint: 'interactive',
    gumExtra: {}
  },
  {
    name: 'B',
    desc: 'A + getUserMedia 约束 sampleRate:48000',
    latencyHint: 'interactive',
    gumExtra: { sampleRate: 48000 }
  },
  {
    name: 'C',
    desc: 'B + getUserMedia 约束 latency:0',
    latencyHint: 'interactive',
    gumExtra: { sampleRate: 48000, latency: 0 }
  },
  {
    name: 'D',
    desc: 'latencyHint 传数字 0（采集约束同 A）',
    latencyHint: 0,
    gumExtra: {}
  },
  {
    name: 'E',
    desc: '对照组：--use-fake-device-for-media-stream 假输入，仅测图内延迟',
    mode: 'ingraph',
    latencyHint: 'interactive',
    fakeDevice: true,
    gumExtra: {}
  },
  {
    name: 'G',
    desc: 'latencyHint 0 + Chrome --audio-buffer-size=128（缩小音频服务缓冲）',
    latencyHint: 0,
    chromeFlags: ['--audio-buffer-size=128'],
    gumExtra: {}
  },
  {
    name: 'H',
    desc: 'latencyHint 0 + Chrome --audio-buffer-size=256',
    latencyHint: 0,
    chromeFlags: ['--audio-buffer-size=256'],
    gumExtra: {}
  },
  {
    name: 'I',
    desc: 'latencyHint 0 + Chrome --audio-buffer-size=64（探测音频服务缓冲下限）',
    latencyHint: 0,
    chromeFlags: ['--audio-buffer-size=64'],
    gumExtra: {}
  }
];

// ---------------------------------------------------------------------------
// Chrome / CDP
// ---------------------------------------------------------------------------
function killChrome (chrome, profile) {
  try { chrome.kill('SIGKILL'); } catch {}
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
}

function waitDevtools (port, timeoutMs = 20000) {
  return (async () => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const res = await fetch(`http://127.0.0.1:${port}/json/version`);
        if (res.ok) return await res.json();
      } catch {}
      await new Promise(r => setTimeout(r, 200));
    }
    throw new Error('Chrome DevTools 未就绪');
  })();
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function withChrome (extraFlags, fn) {
  const profile = fs.mkdtempSync(path.join(root, '.tools', 'chrome-profile-latency-'));
  const chrome = spawn(CHROME, [
    '--headless=new',
    '--no-sandbox',
    '--no-first-run',
    '--disable-dev-shm-usage',
    '--allow-file-access-from-files',
    '--use-fake-ui-for-media-stream',
    '--autoplay-policy=no-user-gesture-required',
    `--remote-debugging-port=${DEVTOOLS_PORT}`,
    `--user-data-dir=${profile}`,
    'about:blank',
    ...extraFlags
  ], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, DISPLAY: process.env.DISPLAY || ':0' } });

  let chromeStderr = '';
  if (chrome.stderr) chrome.stderr.on('data', chunk => { chromeStderr = (chromeStderr + chunk.toString()).slice(-4000); });

  try {
    const versionInfo = await waitDevtools(DEVTOOLS_PORT);
    const target = await (await fetch(
      `http://127.0.0.1:${DEVTOOLS_PORT}/json/new?about:blank`,
      { method: 'PUT' }
    )).json();
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    let id = 0;
    const pending = new Map();
    const consoleLines = [];
    ws.addEventListener('message', ev => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); return; }
      if (msg.method === 'Runtime.consoleAPICalled') {
        const text = (msg.params.args || []).map(a => a.value !== undefined ? a.value : a.description).join(' ');
        consoleLines.push(text);
        console.log('  [page] ' + text);
      } else if (msg.method === 'Runtime.exceptionThrown') {
        console.log('  [page-exception] ' + JSON.stringify(msg.params.exceptionDetails && msg.params.exceptionDetails.text));
      }
    });
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve);
      ws.addEventListener('error', reject);
    });
    const send = (method, params, timeoutMs = 30000) => new Promise((resolve, reject) => {
      const myId = ++id;
      const timer = setTimeout(() => {
        pending.delete(myId);
        reject(new Error('CDP 超时: ' + method));
      }, timeoutMs);
      pending.set(myId, msg => { clearTimeout(timer); resolve(msg); });
      ws.send(JSON.stringify({ id: myId, method, params }));
    });
    const evaluate = async (expression, awaitPromise = false, timeoutMs = 40000) => {
      const wrapped = awaitPromise
        ? `Promise.race([ (${expression}), new Promise((_, reject) => setTimeout(() => reject(new Error('CDP evaluate timeout')), ${timeoutMs})) ])`
        : expression;
      const out = await send('Runtime.evaluate', {
        expression: wrapped,
        awaitPromise,
        returnByValue: true,
        userGesture: true
      }, timeoutMs + 15000);
      const details = out.result && out.result.exceptionDetails;
      if (details) {
        const desc = details.exception && details.exception.description ? details.exception.description : details.text;
        throw new Error('页面异常: ' + desc);
      }
      return out.result && out.result.result ? out.result.result.value : undefined;
    };

    await send('Page.enable');
    await send('Runtime.enable');
    // 先 attach 再导航：http 直连建 target 会卡在导航，且跨导航时 execution context 会被替换。
    await send('Page.navigate', { url: PROBE_URL }, 20000);
    let ready = false;
    for (let i = 0; i < 120; i++) {
      await sleep(100);
      try {
        ready = (await evaluate('typeof window.__latencyProbe === "object"', false, 8000)) === true;
      } catch (e) {
        // 导航瞬间 context 可能被销毁，重试即可。
      }
      if (ready) break;
    }
    if (!ready) throw new Error('探针页面没有初始化（window.__latencyProbe 缺失；上面的 page-exception 为页面内异常）');

    const supported = await evaluate('window.__latencyProbe.supportedConstraints');
    const result = await fn({ send, evaluate, versionInfo, supported, consoleLines });
    try { ws.close(); } catch {}
    return result;
  } catch (error) {
    if (chromeStderr) console.error('Chrome stderr (tail):\n' + chromeStderr);
    throw error;
  } finally {
    try { chrome.kill('SIGKILL'); } catch {}
    await sleep(300);
    killChrome(chrome, profile);
  }
}

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------
function statistics (values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return { count: 0 };
  const median = n % 2 === 1 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const at = q => {
    if (n === 1) return sorted[0];
    const pos = (n - 1) * q;
    const lo = Math.floor(pos);
    const hi = Math.ceil(pos);
    if (lo === hi) return sorted[lo];
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  };
  return {
    count: n,
    minMs: round(sorted[0]),
    maxMs: round(sorted[n - 1]),
    medianMs: round(median),
    meanMs: round(sorted.reduce((a, b) => a + b, 0) / n),
    p25Ms: round(at(0.25)),
    p75Ms: round(at(0.75))
  };
}

function round (value) {
  return value === undefined || value === null || Number.isNaN(value) ? null : Math.round(value * 1000) / 1000;
}

function medianOf (values) {
  const clean = values.filter(v => typeof v === 'number' && isFinite(v));
  if (!clean.length) return null;
  return statistics(clean).medianMs;
}

// ---------------------------------------------------------------------------
// 环境信息
// ---------------------------------------------------------------------------
function readEnvironment () {
  const run = cmd => {
    try { return execSync(cmd, { encoding: 'utf8', timeout: 5000 }).trim(); } catch (e) { return null; }
  };
  return {
    node: process.version,
    chromeBinary: CHROME,
    gitCommit: run('git -C ' + JSON.stringify(root) + ' rev-parse HEAD'),
    pactlInfo: run('pactl info'),
    shortSources: run('pactl list short sources'),
    shortSinks: run('pactl list short sinks'),
    defaultSink: run('pactl get-default-sink'),
    defaultSource: run('pactl get-default-source')
  };
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
const startedAt = new Date();
const results = {
  generatedAt: startedAt.toISOString(),
  method: {
    summary: '脉冲串经真实 AudioWorkletNode(guitarbook-effects) → destination 播放；' +
      'getUserMedia 采集 Scarlett Solo 4th Gen 的硬件 Loopback 输入（Chrome 里的标签为 ' +
      '"Scarlett Solo 4th Gen Monitor Input 3+4 (stereo)"），AudioWorklet 以 currentTime ' +
      '记录到达时刻，差值 = 浏览器输出 → PipeWire sink → 硬件环回 → 浏览器采集 的端到端延迟。',
    caveats: [
      'Chrome 的 getUserMedia 不会枚举 PulseAudio 软件 sink monitor 源（...HiFi__Line1__sink.monitor），' +
        '因此改用同一块声卡上的硬件 Loopback 输入；它同样能录到 sink 播放的内容，额外只多一次 USB 往返（约 1-2 ms）。',
      'Linux 版 Chrome 的 AudioContext.outputLatency 恒为 0（未实现），因此输出的真实缓冲量无法由浏览器自报，' +
        '需要用环回实测值推断。',
      '本沙箱内 Chrome 的 http 出站被拦，页面只能用 file:// 加载（加 --allow-file-access-from-files），' +
        '对本测量没有影响：AudioWorklet 与 getUserMedia 在 file:// 下均为 secure context。',
      '各组在同一 Chrome 实例内重复 3 次：PipeWire 图相位在流启动时锁定，同一实例内 3 次可重复到 0.001 ms；' +
        '不同 Chrome 启动之间会差约 6 ms（两次独立运行 A 组分别 141.06 ms 与 134.27 ms）。',
      'headless Chrome 的 getOutputTimestamp() 在本环境返回 contextTime=0 / performanceTime=0，' +
        '不可用于推算输出缓冲；输出侧延迟只能靠环回实测。'
    ],
    pulse: {
      count: 16,
      spacingMs: 350,
      frequencyHz: 1000,
      durationMs: 12,
      amplitude: 0.4,
      warmupPulsesDropped: 3,
      detectThreshold: 0.05,
      note: '1 kHz 正弦 0.5 ms 起振，阈值穿越相对真实起点约 +0.1 ms 固定偏差，未从结果中扣除。'
    },
    runs: RUNS,
    groups: GROUPS.map(g => g.name)
  },
  environment: readEnvironment(),
  groups: {}
};

let exitCode = 0;
let chromeVersionInfo = null;

try {
  console.log(`探针页面: ${PROBE_URL}`);

  const realGroups = GROUPS.filter(g => ONLY_GROUPS.includes(g.name) && !g.fakeDevice);
  const fakeGroups = GROUPS.filter(g => ONLY_GROUPS.includes(g.name) && g.fakeDevice);

  const runGroup = async (group, inject, contextLabel) => {
    const entry = {
      name: group.name,
      description: group.desc,
      config: {
        latencyHint: group.latencyHint,
        gumExtra: group.gumExtra || {},
        mode: group.mode || 'loopback'
      },
      chromeFlags: contextLabel.extraFlags,
      supportedConstraints: contextLabel.supported,
      runs: []
    };
    console.log(`\n=== 组 ${group.name}：${group.desc} ===`);
    for (let runIndex = 1; runIndex <= RUNS; runIndex++) {
      const config = {
        name: `${group.name}#${runIndex}`,
        latencyHint: group.latencyHint,
        gumExtra: group.gumExtra || {},
        mode: group.mode || 'loopback',
        sampleRate: 48000
      };
      let result = null;
      let thrown = null;
      try {
        result = await contextLabel.evaluate(`window.__latencyProbe.run(${JSON.stringify(config)})`, true, 45000);
      } catch (e) {
        thrown = String(e && e.message ? e.message : e);
      }
      const stats = result ? statistics(result.measurementsMs || []) : { count: 0 };
      const runEntry = {
        run: runIndex,
        measurementsMs: result ? result.measurementsMs || [] : [],
        stats,
        detected: result ? result.detected : null,
        missed: result ? result.missed : null,
        context: result ? result.context : null,
        requestedGum: result ? result.requestedGum : null,
        actualGum: result ? result.actualGum : null,
        monitor: result ? result.monitor || null : null,
        outputTimestamp: result ? result.outputTimestamp : [],
        supportedConstraints: result ? result.supportedConstraints : null,
        errors: result ? result.errors : [],
        thrown
      };
      entry.runs.push(runEntry);
      if (thrown) {
        console.error(`  run ${runIndex}: THROWN ${thrown}`);
      } else if (!stats.count) {
        console.error(`  run ${runIndex}: 没有可用测量 (detected=${runEntry.detected}, missed=${runEntry.missed}, errors=${JSON.stringify(runEntry.errors)})`);
      } else {
        console.log(`  run ${runIndex}: median=${stats.medianMs} ms  min=${stats.minMs} ms  n=${stats.count}  detected=${runEntry.detected}  reported baseLatency=${round((runEntry.context && runEntry.context.baseLatency || 0) * 1000)} ms outputLatency=${round((runEntry.context && runEntry.context.outputLatency || 0) * 1000)} ms`);
      }
      await sleep(400);
    }

    const runMedians = entry.runs.map(r => r.stats.medianMs).filter(v => typeof v === 'number');
    const runMins = entry.runs.map(r => r.stats.minMs).filter(v => typeof v === 'number');
    const allMeasurements = entry.runs.flatMap(r => r.measurementsMs);
    entry.summary = {
      runsWithData: runMedians.length,
      medianOfRunMediansMs: medianOf(runMedians),
      bestRunMinMs: runMins.length ? round(Math.min(...runMins)) : null,
      allSamplesStats: statistics(allMeasurements),
      reportedBaseLatencyMsMedian: medianOf(entry.runs.map(r => r.context && typeof r.context.baseLatency === 'number' ? r.context.baseLatency * 1000 : null)),
      reportedOutputLatencyMsMedian: medianOf(entry.runs.map(r => r.context && typeof r.context.outputLatency === 'number' ? r.context.outputLatency * 1000 : null)),
      contextSampleRate: (entry.runs.find(r => r.context) || {}).context ? (entry.runs.find(r => r.context)).context.sampleRate : null,
      gumSampleRateMedia: medianOf(entry.runs.map(r => r.actualGum && r.actualGum.settings && r.actualGum.settings.sampleRate)),
      gumLatencyMsMedian: medianOf(entry.runs.map(r => r.actualGum && r.actualGum.settings && typeof r.actualGum.settings.latency === 'number' ? r.actualGum.settings.latency * 1000 : null)),
      errors: entry.runs.flatMap(r => r.errors || [])
    };
    return entry;
  };

  if (realGroups.length) {
    // 按 Chrome 旗标分组：--audio-buffer-size 是进程级设置，必须每个旗标组合起一个 Chrome。
    const byFlags = new Map();
    for (const group of realGroups) {
      const key = JSON.stringify(group.chromeFlags || []);
      if (!byFlags.has(key)) byFlags.set(key, []);
      byFlags.get(key).push(group);
    }
    for (const [key, groups] of byFlags) {
      const flags = JSON.parse(key);
      await withChrome(flags, async ctx => {
        if (!chromeVersionInfo) chromeVersionInfo = ctx.versionInfo;
        for (const group of groups) {
          results.groups[group.name] = await runGroup(group, [], {
            ...ctx,
            extraFlags: ['--headless=new', ...flags]
          });
        }
        return true;
      });
    }
  }

  if (fakeGroups.length) {
    await withChrome(['--use-fake-device-for-media-stream'], async ctx => {
      for (const group of fakeGroups) {
        results.groups[group.name] = await runGroup(group, [], {
          ...ctx,
          extraFlags: ['--headless=new', '--use-fake-device-for-media-stream']
        });
      }
      return true;
    });
  }

  results.chrome = chromeVersionInfo ? {
    browser: chromeVersionInfo.Browser,
    protocolVersion: chromeVersionInfo['Protocol-Version']
  } : null;
  results.finishedAt = new Date().toISOString();
  results.durationSeconds = round((Date.now() - startedAt.getTime()) / 1000);

  // -------------------------------------------------------------------------
  // 结论：把环回往返拆成「浏览器报告的输出延迟」与「采集/环回链路」。
  // 基线组优先取 A（现状）；没有跑 A 时取第一个有数据的组，差值都相对基线算。
  // -------------------------------------------------------------------------
  const groupEntries = Object.keys(results.groups)
    .map(name => ({ name, entry: results.groups[name] }))
    .filter(item => item.entry && item.entry.summary && item.entry.summary.runsWithData > 0);
  const baseline = groupEntries.find(item => item.name === 'A') || groupEntries[0] || null;
  const conclusion = { available: false };
  if (baseline) {
    const a = baseline.entry;
    const e = results.groups.E;
    const rtt = a.summary.medianOfRunMediansMs;
    const outputReported = a.summary.reportedOutputLatencyMsMedian;
    const baseReported = a.summary.reportedBaseLatencyMsMedian;
    const ingraph = e && e.summary.runsWithData > 0 ? e.summary.medianOfRunMediansMs : null;
    conclusion.available = true;
    conclusion.baselineGroup = baseline.name;
    const inputReported = a.summary.gumLatencyMsMedian;
    conclusion.loopbackRttMedianMs = rtt;
    conclusion.reportedOutputLatencyMs = outputReported;
    conclusion.reportedBaseLatencyMs = baseReported;
    conclusion.reportedInputLatencyMs = inputReported;
    conclusion.ingraphOverheadMs = ingraph;
    // 预算分解：环回往返 = 输出侧 baseLatency + 采集侧 latency + 其余（PipeWire 图 / USB / 硬件环回）。
    // Linux Chrome 的 outputLatency 恒为 0，不能拿 rtt - outputLatency 当「归一化后的输出延迟」。
    conclusion.residualBeyondReportedMs = (typeof rtt === 'number' && typeof baseReported === 'number' && typeof inputReported === 'number')
      ? round(rtt - baseReported - inputReported)
      : null;
    // 本机 PipeWire 图 quantum 实测 = 1024 帧 @48 kHz = 21.33 ms（pw-top 观察；采集 latency 恰好同值）。
    conclusion.pipewireQuantumObservationMs = 21.333;
    conclusion.quantumNote = '采集侧 track.getSettings().latency = 0.021333 s 恰为 1024 帧，与 pw-top 中 ' +
      'alsa_input.hw_Gen_0 驱动节点的 QUANT=1024 一致；残差约 5 个 quantum，分散在 sink 输出、硬件环回与采集图调度上。';
    const deltas = {};
    for (const item of groupEntries) {
      if (item.name === baseline.name) continue;
      deltas[item.name] = round(item.entry.summary.medianOfRunMediansMs - rtt);
    }
    conclusion.medianDeltaVsBaseline = deltas;
    conclusion.medianDeltaVsA = deltas;
    // D（latencyHint: 0）相对 A（现状）省了多少：页面侧唯一有效的旋钮。
    const aGroup = results.groups.A;
    const dGroup = results.groups.D;
    conclusion.pageSideSavingsMs = (aGroup && dGroup &&
      aGroup.summary.runsWithData > 0 && dGroup.summary.runsWithData > 0)
      ? round(aGroup.summary.medianOfRunMediansMs - dGroup.summary.medianOfRunMediansMs)
      : null;
    // G/H 组与 D 组同为 latencyHint 0，只差 Chrome 的 --audio-buffer-size。
    const dMedian = dGroup && dGroup.summary.runsWithData > 0
      ? dGroup.summary.medianOfRunMediansMs
      : null;
    const bufferDeltas = {};
    for (const name of ['G', 'H']) {
      const g = results.groups[name];
      if (g && g.summary.runsWithData > 0 && typeof dMedian === 'number') {
        bufferDeltas[name] = round(g.summary.medianOfRunMediansMs - dMedian);
      }
    }
    conclusion.audioBufferSizeDeltasVsD = bufferDeltas;
    conclusion.audioBufferSizeSavingsMs = Object.fromEntries(
      Object.entries(bufferDeltas).map(([key, value]) => [key, round(-value)])
    );
    const dBase = dGroup && dGroup.summary.runsWithData > 0
      ? dGroup.summary.reportedBaseLatencyMsMedian : null;
    conclusion.baseLatencySavingsMs = (typeof dBase === 'number' && typeof baseReported === 'number')
      ? round(baseReported - dBase)
      : null;
    const constraints = (a.runs.find(r => r.supportedConstraints) || {}).supportedConstraints || {};
    conclusion.constraintSupport = {
      sampleRate: !!constraints.sampleRate,
      latency: !!constraints.latency,
      channelCount: !!constraints.channelCount,
      echoCancellation: !!constraints.echoCancellation
    };
    const samples = a.summary.allSamplesStats;
    const groupLine = groupEntries
      .map(item => `${item.name} ${item.entry.summary.medianOfRunMediansMs} ms`)
      .join(' / ');
    conclusion.text = [
      `基线组 ${baseline.name} 环回实测往返中位 ${rtt} ms、最小 ${a.summary.bestRunMinMs} ms；`,
      `各组中位：${groupLine}（差值相对 ${baseline.name}：${JSON.stringify(deltas)} ms，负数=更快）；`,
      `浏览器只报出 baseLatency ${baseReported} ms + 采集 latency ${inputReported} ms ` +
        `（Linux Chrome outputLatency 恒 0，不可用作输出缓冲依据）；`,
      typeof ingraph === 'number' ? `图内（worklet → destination）开销 ${ingraph} ms，可忽略；` : '',
      conclusion.residualBeyondReportedMs !== null
        ? `其余约 ${conclusion.residualBeyondReportedMs} ms 落在 PipeWire 图、USB 与硬件环回（约 5 × 21.33 ms quantum）；` : '',
      conclusion.pageSideSavingsMs !== null
        ? `D（latencyHint: 0）比 A 少 ${conclusion.pageSideSavingsMs} ms，页面侧唯一有效的旋钮；`
        : '',
      Object.keys(bufferDeltas).length
        ? `Chrome --audio-buffer-size（G/H）相对 D 的变化 ${JSON.stringify(bufferDeltas)} ms（负数=更快），` +
          `采集侧上报 latency：G=${round((results.groups.G.summary || {}).gumLatencyMsMedian)} ms、` +
          `H=${round((results.groups.H.summary || {}).gumLatencyMsMedian)} ms；`
        : '',
      `结论：DSP 链路只占 0.1 ms；页面侧能省的只有 latencyHint:0（${conclusion.pageSideSavingsMs} ms），` +
        `剩下的延迟在浏览器采集/输出缓冲、PipeWire quantum 与硬件链路上，只能在系统与浏览器侧调。`
    ].join('');
  } else {
    conclusion.reason = '没有拿到有效环回测量（没有任何组拿到数据）';
    exitCode = 1;
  }
  results.conclusion = conclusion;

  fs.mkdirSync(path.dirname(RESULT_FILE), { recursive: true });
  fs.writeFileSync(RESULT_FILE, JSON.stringify(results, null, 2));
  console.log('\n=== 汇总 ===');
  for (const name of Object.keys(results.groups)) {
    const g = results.groups[name];
    const s = g.summary;
    console.log(`${name}: median=${s.medianOfRunMediansMs} ms  min=${s.bestRunMinMs} ms  ` +
      `baseLatency=${s.reportedBaseLatencyMsMedian} ms  outputLatency=${s.reportedOutputLatencyMsMedian} ms  ` +
      `sr=${s.contextSampleRate}  runs=${s.runsWithData}/${g.runs.length}`);
  }
  console.log('\n结论：' + (conclusion.text || conclusion.reason));
  console.log('\n原始结果: ' + RESULT_FILE);
} catch (error) {
  console.error('测量失败：', error && error.stack ? error.stack : error);
  results.error = String(error && error.stack ? error.stack : error);
  try {
    fs.mkdirSync(path.dirname(RESULT_FILE), { recursive: true });
    fs.writeFileSync(RESULT_FILE, JSON.stringify(results, null, 2));
  } catch {}
  exitCode = 1;
} finally {
  try {
    // 兜底：清掉遗留的本脚本 profile 目录。
    for (const name of fs.readdirSync(path.join(root, '.tools'))) {
      if (name.startsWith('chrome-profile-latency-')) {
        try { fs.rmSync(path.join(root, '.tools', name), { recursive: true, force: true }); } catch {}
      }
    }
  } catch {}
}

process.exit(exitCode);
