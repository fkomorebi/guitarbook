#!/usr/bin/env node
/*
 * guitarbook · MSTP 输入链路对照测量（独立 harness）
 *
 * 目的：比较两种「采集侧」输入链路在同一条测量链上的端到端延迟：
 *   A) loopback：getUserMedia → MediaStreamAudioSourceNode → AudioWorkletNode('latency-detector')
 *   B) mstp    ：getUserMedia → MediaStreamTrackProcessor → readable → port → AudioWorkletNode('latency-detector')
 * 播放侧两条路径完全一致（脉冲 → 'guitarbook-effects' → destination），所以差值就是
 * 「绕开 MediaStreamAudioSourceNode 的净收益」。
 *
 * 关键方法学：两条路径的「到达时刻」原本在不同域
 *   - loopback 用 AudioContext.currentTime（音频/渲染时钟）；
 *   - mstp     只有墙钟（performance.now() / AudioData.timestamp）。
 * 页面侧用 (performance.now(), ctx.currentTime) 的连续采样拟合一条线性映射
 *   audioMs = slope * wallMs + intercept
 * 把两边都换算到墙钟后再相减（结果里同时给出拟合残差）。
 *
 * 用法：
 *   node tool/check_web_latency_mstp.mjs [--runs=3] [--fake] [--modes=loopback,mstp]
 *     --fake   额外加 --use-fake-device-for-media-stream（假设备，不占真采集卡）
 *     --runs=N 每种模式重复次数（默认 3）
 * 两种模式在**同一个 Chrome 实例**里交替跑，避免进程级差异。
 *
 * 只用 node 内置模块（node v24 自带 fetch / WebSocket / child_process）。
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const CHROME = '/usr/bin/google-chrome';
const PROBE_URL = pathToFileURL(path.join(root, 'tool', 'web_latency_probe.html')).href;
const RESULT_FILE = path.join(root, '.tools', 'latency_mstp_results.json');

const argv = process.argv.slice(2);
function argValue (name, fallback) {
  const hit = argv.find(a => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return fallback;
  const eq = hit.indexOf('=');
  if (eq >= 0) return hit.slice(eq + 1);
  return 'true';
}
const RUNS = Math.max(1, Number(argValue('runs', 3)) || 3);
const USE_FAKE = argValue('fake', '') !== '' && argValue('fake', '') !== 'false';
const MODES = String(argValue('modes', 'loopback,mstp'))
  .split(',').map(s => s.trim()).filter(Boolean);
const DEVTOOLS_PORT = Number(argValue('port', 9456)) || 9456;
const SAMPLE_RATE = Number(argValue('sampleRate', 48000)) || 48000;
// 默认 'interactive'：与 lib/features/effects/effects_backend_web.dart 现状一致，
// 也与 tool/check_web_latency.mjs 的 A 组基线（134.271 ms）同口径。
// 可用 --latencyHint=0 复现 D 组（latencyHint 传数字 0）。
const LATENCY_HINT = argValue('latencyHint', 'interactive');
// 额外的 Chrome 启动参数，可重复给出，例如：
//   --chromeFlag=--audio-buffer-size=128
const CHROME_FLAGS = argv
  .filter(a => a.startsWith('--chromeFlag='))
  .map(a => a.slice('--chromeFlag='.length))
  .filter(Boolean);

const sleep = ms => new Promise(r => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------
function statistics (values) {
  const sorted = values.filter(v => typeof v === 'number' && isFinite(v)).slice().sort((a, b) => a - b);
  const n = sorted.length;
  if (!n) return { count: 0, medianMs: null, minMs: null, maxMs: null, meanMs: null, p25Ms: null, p75Ms: null };
  const median = n % 2 === 1 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const at = q => {
    if (n === 1) return sorted[0];
    const pos = (n - 1) * q;
    const lo = Math.floor(pos);
    const hi = Math.ceil(pos);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  };
  return {
    count: n,
    medianMs: round(median),
    minMs: round(sorted[0]),
    maxMs: round(sorted[n - 1]),
    meanMs: round(sorted.reduce((s, v) => s + v, 0) / n),
    p25Ms: round(at(0.25)),
    p75Ms: round(at(0.75))
  };
}

function round (value) {
  if (typeof value !== 'number' || !isFinite(value)) return null;
  return Math.round(value * 1000) / 1000;
}

function medianOf (values) {
  const clean = values.filter(v => typeof v === 'number' && isFinite(v));
  if (!clean.length) return null;
  return statistics(clean).medianMs;
}

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
      await sleep(200);
    }
    throw new Error('Chrome DevTools 未就绪');
  })();
}

async function withChrome (extraFlags, fn) {
  const profile = fs.mkdtempSync(path.join(root, '.tools', 'chrome-profile-latency-mstp-'));
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
        const text = (msg.params.args || []).map(a => (a.value !== undefined ? a.value : a.description)).join(' ');
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
    if (!ready) throw new Error('探针页面没有初始化（window.__latencyProbe 缺失）');

    const supported = await evaluate('window.__latencyProbe.supportedConstraints');
    const env = await evaluate('({ mstp: typeof MediaStreamTrackProcessor, audioData: typeof AudioData, ua: navigator.userAgent })');
    return await fn({ send, evaluate, versionInfo, supported, consoleLines, env });
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
// 单次测量
// ---------------------------------------------------------------------------
async function runOnce (evaluate, mode, runIndex) {
  const config = {
    name: `${mode}#${runIndex}`,
    mode,
    latencyHint: LATENCY_HINT === '0' ? 0 : LATENCY_HINT,
    sampleRate: SAMPLE_RATE,
    gumExtra: {},
    // 假设备没有名字带 monitor 的输入，冒烟测试时允许退到第一个 audioinput。
    allowFallbackDevice: USE_FAKE
  };
  let result = null;
  let thrown = null;
  try {
    result = await evaluate(`window.__latencyProbe.run(${JSON.stringify(config)})`, true, 60000);
  } catch (e) {
    thrown = String(e && e.message ? e.message : e);
  }
  const wc = (result && result.wallClock) || {};
  // 主指标：音频时钟口径（两条路径同域，直接可比）
  const appSideAudio = (result && result.measurementsMs) || [];
  // 交叉校验：wall-clock 口径（经线性映射换算）
  const appSide = wc.measurementsMs || [];
  const appSideQuantum = wc.measurementsMsQuantum || [];
  const captureSide = wc.captureMeasurementsMs || [];
  const captureS2 = (wc.perPulse || []).map(p => p.captureDeltaS2WallMs).filter(v => typeof v === 'number');
  const mapping = wc.mapping || null;
  return {
    mode,
    run: runIndex,
    thrown,
    // 页面原始字段（harness 直接读这个结构）
    measurementsMs: result ? result.measurementsMs || [] : [],
    detected: result ? result.detected : null,
    missed: result ? result.missed : null,
    context: result ? result.context : null,
    requested: result ? result.requested : null,
    requestedGum: result ? result.requestedGum : null,
    actualGum: result ? result.actualGum : null,
    monitor: result ? result.monitor || null : null,
    errors: result ? result.errors || [] : [],
    mstp: result ? result.mstp || null : null,
    outputTimestamp: result ? result.outputTimestamp || [] : [],
    // wall-clock 口径
    wallClock: {
      appSideAudioClockMs: appSideAudio,
      appSideMs: appSide,
      appSideQuantumMs: appSideQuantum,
      captureSideMs: captureSide,
      captureSideS2Ms: captureS2,
      perPulse: wc.perPulse || [],
      mapping
    },
    stats: {
      appSide: statistics(appSideAudio),
      appSideWall: statistics(appSide),
      appSideQuantum: statistics(appSideQuantum),
      captureSide: statistics(captureSide),
      captureSideS2: statistics(captureS2),
      raw: statistics(appSideAudio)
    }
  };
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
const startedAt = new Date().toISOString();
const results = {
  startedAt,
  finishedAt: null,
  probeUrl: PROBE_URL,
  chrome: null,
  env: null,
  runs: RUNS,
  modes: MODES,
  fakeDevice: USE_FAKE,
  sampleRate: SAMPLE_RATE,
  latencyHint: LATENCY_HINT,
  chromeFlags: CHROME_FLAGS,
  runs_detail: [],
  conclusion: null,
  error: null
};

let exitCode = 0;

try {
  console.log(`探针页面: ${PROBE_URL}`);
  console.log(`模式: ${MODES.join(' / ')}，每个模式 ${RUNS} 次（同一 Chrome 实例内交替）`);
  console.log(`latencyHint: ${LATENCY_HINT}，AudioContext sampleRate: ${SAMPLE_RATE}`);
  if (CHROME_FLAGS.length) console.log(`额外 Chrome 参数: ${CHROME_FLAGS.join(' ')}`);
  console.log(`假设备: ${USE_FAKE ? '是（--use-fake-device-for-media-stream，不占真采集卡）' : '否（真机采集）'}`);

  const flags = USE_FAKE ? ['--use-fake-device-for-media-stream'] : [];
  if (CHROME_FLAGS.length) flags.push(...CHROME_FLAGS);

  await withChrome(flags, async ctx => {
    results.chrome = ctx.versionInfo;
    results.env = ctx.env;
    console.log(`Chrome: ${ctx.versionInfo && ctx.versionInfo.Browser}`);
    console.log(`页面环境: MediaStreamTrackProcessor=${ctx.env.mstp}, AudioData=${ctx.env.audioData}`);
    if (ctx.env.mstp !== 'function') {
      console.log('!! 该浏览器没有 MediaStreamTrackProcessor，mstp 模式只能验证「不可用时的降级路径」。');
    }

    for (let runIndex = 1; runIndex <= RUNS; runIndex++) {
      for (const mode of MODES) {
        console.log(`\n--- run ${runIndex}/${RUNS} · mode=${mode} ---`);
        const entry = await runOnce(ctx.evaluate, mode, runIndex);
        results.runs_detail.push(entry);
        if (entry.thrown) {
          console.error(`  THROWN: ${entry.thrown}`);
        } else {
          const a = entry.stats.appSide;
          const aw = entry.stats.appSideWall;
          const c = entry.stats.captureSide;
          const c2 = entry.stats.captureSideS2;
          const res = entry.wallClock.mapping && entry.wallClock.mapping.residualMs;
          console.log(`  app-side(音频时钟，主指标) median=${a.medianMs} ms  min=${a.minMs} max=${a.maxMs} n=${a.count}`);
          console.log(`  app-side(墙钟交叉校验)     median=${aw.medianMs} ms  n=${aw.count}`);
          console.log(`  capture-side S1 median=${c.medianMs} ms  S2 median=${c2.medianMs} ms`);
          console.log(`  映射残差 rms=${res ? res.rms : 'n/a'} ms maxAbs=${res ? res.maxAbs : 'n/a'} ms  slope=${entry.wallClock.mapping ? round(entry.wallClock.mapping.slope) : 'n/a'} 样本=${entry.wallClock.mapping ? entry.wallClock.mapping.usedSamples : 0}/${entry.wallClock.mapping ? entry.wallClock.mapping.samples : 0} 离群=${entry.wallClock.mapping ? entry.wallClock.mapping.outliers : 0}`);
          console.log(`  detected=${entry.detected} missed=${entry.missed} errors=${JSON.stringify(entry.errors)}`);
          if (entry.mstp) {
            const m = entry.mstp;
            const f0 = (m.frames && m.frames[0]) || null;
            const lag = m.stats && m.stats.readMinusTimestampStats ? m.stats.readMinusTimestampStats.median : null;
            const tsDelta = m.stats && m.stats.timestampDeltaStats ? m.stats.timestampDeltaStats.median : null;
            console.log(`  MSTP 帧: count=${m.frameCount} 帧长=${f0 ? f0.numberOfFrames : 'n/a'}@${f0 ? f0.sampleRate : 'n/a'}Hz ch=${f0 ? f0.numberOfChannels : 'n/a'} fmt=${f0 ? f0.format : 'n/a'} timestamp单位=${f0 ? f0.timestampUnit : 'n/a'} ts步进中位数=${tsDelta} 读取滞后中位数=${lag} ms`);
            if (m.errors && m.errors.length) console.log(`  MSTP 错误: ${JSON.stringify(m.errors)}`);
          }
        }
        await sleep(500);
      }
    }
    return true;
  });
} catch (error) {
  results.error = String(error && error.stack ? error.stack : error);
  console.error('\n运行失败: ' + results.error);
  exitCode = 1;
}

// ---------------------------------------------------------------------------
// 汇总与结论
// ---------------------------------------------------------------------------
function groupOf (mode) {
  return results.runs_detail.filter(r => r.mode === mode && !r.thrown);
}

function perRunMedians (mode, key) {
  return groupOf(mode).map(r => (r.stats[key] || {}).medianMs).filter(v => typeof v === 'number');
}

function summarizeMode (mode) {
  const entries = groupOf(mode);
  if (!entries.length) return null;
  const appMedians = perRunMedians(mode, 'appSide');
  const appQuantumMedians = perRunMedians(mode, 'appSideQuantum');
  const captureMedians = perRunMedians(mode, 'captureSide');
  const captureS2Medians = perRunMedians(mode, 'captureSideS2');
  const allApp = entries.flatMap(r => r.stats.appSide.count ? r.wallClock.appSideAudioClockMs : []);
  const allAppWall = entries.flatMap(r => r.stats.appSideWall.count ? r.wallClock.appSideMs : []);
  const allCapture = entries.flatMap(r => r.stats.captureSide.count ? r.wallClock.captureSideMs : []);
  const residuals = entries
    .map(r => r.wallClock.mapping && r.wallClock.mapping.residualMs && r.wallClock.mapping.residualMs.rms)
    .filter(v => typeof v === 'number');
  return {
    mode,
    runsWithData: entries.length,
    appSide: {
      perRunMediansMs: appMedians,
      medianOfRunMediansMs: medianOf(appMedians),
      allSamples: statistics(allApp)
    },
    appSideWall: {
      perRunMediansMs: perRunMedians(mode, 'appSideWall'),
      medianOfRunMediansMs: medianOf(perRunMedians(mode, 'appSideWall')),
      allSamples: statistics(allAppWall)
    },
    appSideQuantum: {
      perRunMediansMs: appQuantumMedians,
      medianOfRunMediansMs: medianOf(appQuantumMedians)
    },
    captureSideS1: {
      perRunMediansMs: captureMedians,
      medianOfRunMediansMs: medianOf(captureMedians),
      allSamples: statistics(allCapture)
    },
    captureSideS2: {
      perRunMediansMs: captureS2Medians,
      medianOfRunMediansMs: medianOf(captureS2Medians)
    },
    clockMappingResidualRmsMs: residuals.length ? {
      perRun: residuals,
      median: medianOf(residuals),
      max: round(Math.max(...residuals))
    } : null,
    sampleRateContext: entries.map(r => r.context && r.context.sampleRate),
    gumSettings: entries.map(r => r.actualGum && r.actualGum.settings),
    quantumMs: entries
      .map(r => r.wallClock.mapping && r.wallClock.mapping.quantumMs)
      .find(v => typeof v === 'number') || null,
    errors: entries.flatMap(r => r.errors || [])
  };
}

const loopbackSummary = MODES.includes('loopback') ? summarizeMode('loopback') : null;
const mstpSummary = MODES.includes('mstp') ? summarizeMode('mstp') : null;

if (loopbackSummary && mstpSummary) {
  const lb = loopbackSummary.appSide.medianOfRunMediansMs;
  const mp = mstpSummary.appSide.medianOfRunMediansMs;
  const diff = (typeof lb === 'number' && typeof mp === 'number') ? round(lb - mp) : null;
  const lbCap = loopbackSummary.captureSideS1.medianOfRunMediansMs;
  const mpCap = mstpSummary.captureSideS1.medianOfRunMediansMs;
  const mpQ = mstpSummary.appSideQuantum.medianOfRunMediansMs;
  const lbQ = loopbackSummary.appSideQuantum.medianOfRunMediansMs;
  const diffQuantum = (typeof lbQ === 'number' && typeof mpQ === 'number') ? round(lbQ - mpQ) : null;
  const lbWall = loopbackSummary.appSideWall.medianOfRunMediansMs;
  const mpWall = mstpSummary.appSideWall.medianOfRunMediansMs;
  const diffWall = (typeof lbWall === 'number' && typeof mpWall === 'number') ? round(lbWall - mpWall) : null;
  results.conclusion = {
    comparable: true,
    fakeDevice: USE_FAKE,
    loopbackAppSideMedianMs: lb,
    mstpAppSideMedianMs: mp,
    netSavingMs: diff,
    netSavingNote: diff === null
      ? '样本不足，无法比较'
      : (diff > 0 ? `MSTP 比 MediaStreamAudioSourceNode 少 ${diff} ms` : `MSTP 反而多 ${Math.abs(diff)} ms`),
    // 交叉校验口径一：wall-clock 线性映射
    loopbackAppSideWallMedianMs: lbWall,
    mstpAppSideWallMedianMs: mpWall,
    netSavingMsWall: diffWall,
    // 交叉校验口径二：用「处理该帧的 render quantum 起点」作为到达时刻
    loopbackAppSideQuantumMedianMs: lbQ,
    mstpAppSideQuantumMedianMs: mpQ,
    netSavingMsQuantum: diffQuantum,
    loopbackCaptureSideMedianMs: lbCap,
    mstpCaptureSideMedianMs: mpCap,
    mstpCaptureSideS2MedianMs: mstpSummary.captureSideS2.medianOfRunMediansMs,
    quantumMs: mstpSummary.quantumMs,
    clockMappingResidualRmsMs: {
      loopback: loopbackSummary.clockMappingResidualRmsMs,
      mstp: mstpSummary.clockMappingResidualRmsMs
    }
  };
} else {
  results.conclusion = { comparable: false, note: '两种模式没有同时取得数据' };
}

results.finishedAt = new Date().toISOString();

try {
  fs.mkdirSync(path.dirname(RESULT_FILE), { recursive: true });
  fs.writeFileSync(RESULT_FILE, JSON.stringify(results, null, 2));
  console.log(`\n结果已写入 ${RESULT_FILE}`);
} catch (e) {
  console.error('写结果文件失败: ' + String(e));
}

console.log('\n================ 结论摘要 ================');
if (results.conclusion && results.conclusion.comparable) {
  const c = results.conclusion;
  console.log(`loopback（MediaStreamAudioSourceNode）app-side 中位数: ${c.loopbackAppSideMedianMs} ms`);
  console.log(`mstp    （MediaStreamTrackProcessor） app-side 中位数: ${c.mstpAppSideMedianMs} ms`);
  console.log(`净收益（同一 AudioContext 音频时钟口径，主指标）: ${c.netSavingMs} ms —— ${c.netSavingNote}`);
  console.log(`交叉校验（wall-clock 映射口径）: loopback=${c.loopbackAppSideWallMedianMs} ms, mstp=${c.mstpAppSideWallMedianMs} ms, 净收益=${c.netSavingMsWall} ms`);
  if (typeof c.loopbackAppSideQuantumMedianMs === 'number' && typeof c.mstpAppSideQuantumMedianMs === 'number') {
    console.log(`交叉校验（quantum 起点口径）: loopback=${c.loopbackAppSideQuantumMedianMs} ms, mstp=${c.mstpAppSideQuantumMedianMs} ms, 净收益=${c.netSavingMsQuantum} ms`);
  } else {
    console.log(`交叉校验（quantum 起点口径）: mstp=${c.mstpAppSideQuantumMedianMs} ms（该值是下界，最多比真实到达早 1 个 quantum=${c.quantumMs ? c.quantumMs : 'n/a'} ms）；loopback 路径的到达时刻本身就是精确音频时钟采样点，没有同口径值，故不计算差值`);
  }
  console.log(`mstp 采集侧（帧时间戳口径 S1）: ${c.mstpCaptureSideMedianMs} ms；loopback 采集侧: ${c.loopbackCaptureSideMedianMs} ms（MediaStreamAudioSourceNode 不暴露采集时间戳）`);
  console.log(`时钟映射拟合残差 rms: loopback=${c.clockMappingResidualRmsMs.loopback ? c.clockMappingResidualRmsMs.loopback.median : 'n/a'} ms, mstp=${c.clockMappingResidualRmsMs.mstp ? c.clockMappingResidualRmsMs.mstp.median : 'n/a'} ms`);
  if (USE_FAKE) {
    console.log('注意：本次是假设备冒烟测试（假设备不把输出回灌到输入），延迟数字没有物理意义，只证明链路可跑通。');
  }
} else {
  console.log(JSON.stringify(results.conclusion));
}
if (results.error) console.log('错误: ' + results.error);

process.exit(exitCode);
