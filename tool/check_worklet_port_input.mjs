// 浏览器端验证：web/effects_worklet.js 的「主线程端口注入采集帧」输入通道。
// 用法：node tool/check_worklet_port_input.mjs
//
// 做法：用 headless Chrome + 真实 OfflineAudioContext 加载真实的 web/effects_worklet.js
// （页面用 worklet 文件自身的 file:// URL 作为宿主，addModule 同一个 file:// URL；
// 本沙箱内 Chrome 的 http 出站被拦，因此不能起静态服务器）：
//   1) inputMode:'port' 时注入已知斜坡，断言渲染输出与注入样本逐样本相等；
//   2) 注入样本少于渲染长度时断言欠载补零；
//   3) 分两条 input 消息注入，验证跨消息/量子的 FIFO 续接；
//   4) 默认 inputMode:'node' 走原有音频节点输入，做回归断言；
//   5) 非法 input 消息不应打断渲染（输出保持静音）；
//   6) reset 应同时清空端口注入 FIFO。
// 全部通过退出码 0，任一失败打印差异并退出 1。
//
// 依赖：仅 Node 内置模块（http / child_process / WebSocket 全局对象），无 npm 依赖。

import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const CHROME = '/usr/bin/google-chrome';
const DEVTOOLS_PORT = 9447;
const PROFILE = path.join(root, '.tools', 'chrome-profile-worklet-port');
const WORKLET_PATH = path.join(root, 'web', 'effects_worklet.js');
const WORKLET_URL = pathToFileURL(WORKLET_PATH).href;
// 宿主页就用 worklet 文件本身：file:// 下的真实文件页 origin 为 file://，
// 才能让 addModule(file://.../effects_worklet.js) 通过同源检查（目录列表页的 origin 是 null）。
const HOST_URL = WORKLET_URL;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function httpJson (method, pathname) {
    return new Promise((resolve, reject) => {
        const req = http.request({
            host: '127.0.0.1',
            port: DEVTOOLS_PORT,
            path: pathname,
            method
        }, res => {
            let body = '';
            res.setEncoding('utf8');
            res.on('data', chunk => { body += chunk; });
            res.on('end', () => {
                try {
                    resolve(body ? JSON.parse(body) : null);
                } catch (error) {
                    reject(new Error(`DevTools 返回了非 JSON 内容：${body.slice(0, 200)}`));
                }
            });
        });
        req.on('error', reject);
        req.end();
    });
}

async function waitDevtools () {
    const deadline = Date.now() + 15000;
    let lastError = null;
    while (Date.now() < deadline) {
        try {
            const version = await httpJson('GET', '/json/version');
            if (version && version.Browser)
                return version;
        } catch (error) {
            lastError = error;
        }
        await sleep(200);
    }
    throw new Error(`Chrome DevTools 未就绪：${lastError ? lastError.message : '超时'}`);
}

class CdpSession {
    constructor (webSocketUrl) {
        this.nextId = 1;
        this.pending = new Map();
        this.ws = new WebSocket(webSocketUrl);
        this.opened = new Promise((resolve, reject) => {
            this.ws.addEventListener('open', () => resolve());
            this.ws.addEventListener('error', event => reject(new Error('CDP WebSocket 错误：' + String(event && event.message))));
        });
        this.ws.addEventListener('message', event => {
            let message = null;
            try {
                message = JSON.parse(typeof event.data === 'string' ? event.data : '');
            } catch (error) {
                return;
            }
            if (message.id && this.pending.has(message.id)) {
                const entry = this.pending.get(message.id);
                this.pending.delete(message.id);
                if (message.error)
                    entry.reject(new Error(`${entry.method} 失败：${message.error.message}`));
                else
                    entry.resolve(message.result);
            }
        });
    }

    send (method, params = {}, timeoutMs = 30000) {
        return new Promise((resolve, reject) => {
            const id = this.nextId++;
            const timer = setTimeout(() => {
                if (this.pending.has(id)) {
                    this.pending.delete(id);
                    reject(new Error(`CDP 调用超时：${method}`));
                }
            }, timeoutMs);
            this.pending.set(id, {
                method,
                resolve: value => { clearTimeout(timer); resolve(value); },
                reject: error => { clearTimeout(timer); reject(error); }
            });
            this.ws.send(JSON.stringify({ id, method, params }));
        });
    }

    async evaluate (expression, awaitPromise = true, timeoutMs = 120000) {
        const result = await this.send('Runtime.evaluate', {
            expression,
            awaitPromise,
            returnByValue: true
        }, timeoutMs + 20000);
        if (result.exceptionDetails) {
            const detail = result.exceptionDetails.exception && result.exceptionDetails.exception.description
                ? result.exceptionDetails.exception.description
                : result.exceptionDetails.text;
            throw new Error(`页面脚本抛异常：${detail}`);
        }
        return result.result ? result.result.value : undefined;
    }

    close () {
        try { this.ws.close(); } catch (error) { /* ignore */ }
    }
}

// --- 页面内执行的断言代码 ---------------------------------------------------
// 用字符串拼接拼装，避免与 worklet 源码内的反引号/插值冲突。

const pageScript = `(async () => {
    const WORKLET_URL = ${JSON.stringify(WORKLET_URL)};
    const SR = 48000;
    const EPS = 1e-7;
    const results = [];
    const ramp = new Float32Array(480);
    for (let i = 0; i < ramp.length; ++i)
        ramp[i] = i * 1.5 / ramp.length - 0.75;

    function record (name, pass, detail) {
        results.push({ name, pass, detail });
    }

    function maxDiff (expected, actual, offset) {
        let max = 0;
        let at = -1;
        let mismatches = 0;
        for (let i = 0; i < expected.length; ++i) {
            const d = Math.abs(actual[offset + i] - expected[i]);
            if (d > EPS)
                mismatches++;
            if (d > max) {
                max = d;
                at = i;
            }
        }
        return { max, at, mismatches };
    }

    function head (array, offset) {
        const parts = [];
        for (let i = 0; i < 4 && offset + i < array.length; ++i)
            parts.push(array[offset + i].toFixed(4));
        return '[' + parts.join(', ') + ']';
    }

    function describeDiff (diff, expected, actual, offset) {
        let detail = '最大误差 ' + diff.max.toExponential(3) + ' @sample ' + diff.at +
            '；不匹配样本 ' + diff.mismatches + '/' + expected.length;
        if (diff.at >= 0)
            detail += '（实际 ' + actual[offset + diff.at].toFixed(6) + '，期望 ' +
                expected[diff.at].toFixed(6) + '；前 4 样本 实际 ' + head(actual, offset) +
                ' 期望 ' + head(expected, 0) + '）';
        return detail;
    }

    async function build (frames) {
        const ctx = new OfflineAudioContext(2, frames, SR);
        // 同一个 file:// URL 可以反复 addModule，浏览器会复用已编译的模块。
        await ctx.audioWorklet.addModule(WORKLET_URL);
        const node = new AudioWorkletNode(ctx, 'guitarbook-effects', {
            numberOfInputs: 1,
            numberOfOutputs: 1,
            outputChannelCount: [2],
            channelCount: 2,
            channelCountMode: 'explicit'
        });
        node.connect(ctx.destination);
        return { ctx, node };
    }

    function inject (node, samples) {
        // 复制一份，保证 buffer.byteOffset === 0（协议要求）。
        const copy = new Float32Array(samples);
        node.port.postMessage({ type: 'input', buffer: copy.buffer, frames: copy.length });
    }

    // 端口消息是跨线程异步投递的，若在 startRendering 前不等它落地，
    // 离线渲染会在极短时间内跑完、抢在消息到达之前，导致首量子读不到注入样本。
    // 这里利用 worklet 对未知指令回发 {type:'error'} 的行为做一次同步：
    // 端口消息按 FIFO 处理，收到该回执即说明之前的 inputMode / input 已全部处理完。
    function flushPort (node, timeoutMs = 2000) {
        return new Promise(resolve => {
            let settled = false;
            const done = () => {
                if (settled)
                    return;
                settled = true;
                clearTimeout(timer);
                node.port.removeEventListener('message', onMessage);
                resolve();
            };
            const timer = setTimeout(done, timeoutMs);
            const onMessage = event => {
                if (event.data && event.data.type === 'error' && String(event.data.message).indexOf('__flush__') >= 0)
                    done();
            };
            node.port.addEventListener('message', onMessage);
            node.port.postMessage({ type: '__flush__' });
        });
    }

    // 1) port 模式直通 + 右声道复制。
    try {
        const { ctx, node } = await build(480);
        node.port.postMessage({ type: 'inputMode', mode: 'port' });
        inject(node, ramp);
        await flushPort(node);
        const rendered = await ctx.startRendering();
        const left = maxDiff(ramp, rendered.getChannelData(0), 0);
        const right = maxDiff(ramp, rendered.getChannelData(1), 0);
        record('port 模式直通（左声道）', left.max <= EPS, describeDiff(left, ramp, rendered.getChannelData(0), 0));
        record('port 模式右声道复制（单声道上混）', right.max <= EPS, describeDiff(right, ramp, rendered.getChannelData(1), 0));
    } catch (error) {
        record('port 模式直通（左声道）', false, '抛异常：' + String(error && error.message ? error.message : error));
        record('port 模式右声道复制（单声道上混）', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    // 2) 欠载：只注入 300 帧，渲染 480 帧，尾部应补零。
    try {
        const head300 = ramp.subarray(0, 300);
        const expected = new Float32Array(480);
        expected.set(head300, 0);
        const { ctx, node } = await build(480);
        node.port.postMessage({ type: 'inputMode', mode: 'port' });
        inject(node, head300);
        await flushPort(node);
        const rendered = await ctx.startRendering();
        const diff = maxDiff(expected, rendered.getChannelData(0), 0);
        record('port 模式 FIFO 欠载补零（300/480）', diff.max <= EPS, describeDiff(diff, expected, rendered.getChannelData(0), 0));
    } catch (error) {
        record('port 模式 FIFO 欠载补零（300/480）', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    // 3) 跨消息/量子续接：两条 input 消息拼成 480 帧。
    try {
        const first = ramp.subarray(0, 233);
        const second = ramp.subarray(233, 480);
        const { ctx, node } = await build(480);
        node.port.postMessage({ type: 'inputMode', mode: 'port' });
        inject(node, first);
        inject(node, second);
        await flushPort(node);
        const rendered = await ctx.startRendering();
        const diff = maxDiff(ramp, rendered.getChannelData(0), 0);
        record('port 模式跨消息/量子 FIFO 续接', diff.max <= EPS, describeDiff(diff, ramp, rendered.getChannelData(0), 0));
    } catch (error) {
        record('port 模式跨消息/量子 FIFO 续接', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    // 4) 回归：默认 node 模式沿用音频节点输入，且单声道上混行为不变。
    try {
        const { ctx, node } = await build(480);
        const buffer = ctx.createBuffer(1, 480, SR);
        buffer.copyToChannel(ramp, 0);
        const sourceNode = ctx.createBufferSource();
        sourceNode.buffer = buffer;
        sourceNode.connect(node);
        sourceNode.start(0);
        const rendered = await ctx.startRendering();
        const left = maxDiff(ramp, rendered.getChannelData(0), 0);
        const right = maxDiff(ramp, rendered.getChannelData(1), 0);
        record('node 模式回归（音频节点输入，左）', left.max <= EPS, describeDiff(left, ramp, rendered.getChannelData(0), 0));
        record('node 模式回归（单声道上混，右）', right.max <= EPS, describeDiff(right, ramp, rendered.getChannelData(1), 0));
    } catch (error) {
        record('node 模式回归（音频节点输入，左）', false, '抛异常：' + String(error && error.message ? error.message : error));
        record('node 模式回归（单声道上混，右）', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    // 5) 非法 input 消息：应报错但不断渲染，输出保持静音。
    try {
        const errors = [];
        const { ctx, node } = await build(480);
        node.port.onmessage = event => {
            if (event.data && event.data.type === 'error')
                errors.push(String(event.data.message));
        };
        node.port.postMessage({ type: 'inputMode', mode: 'port' });
        node.port.postMessage({ type: 'input', buffer: 'not-a-buffer', frames: 480 });
        node.port.postMessage({ type: 'input', buffer: new Float32Array(10).buffer, frames: 480 });
        const rendered = await ctx.startRendering();
        await new Promise(resolve => setTimeout(resolve, 200));
        let peak = 0;
        const left = rendered.getChannelData(0);
        for (let i = 0; i < left.length; ++i)
            peak = Math.max(peak, Math.abs(left[i]));
        record('非法 input 消息不打断渲染（输出静音）', peak <= EPS,
            '输出峰值 ' + peak.toExponential(3) + '；worklet 报错条数 ' + errors.length + '（期望 2）');
    } catch (error) {
        record('非法 input 消息不打断渲染（输出静音）', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    // 6) reset 应清空端口注入 FIFO（避免复位后吐出旧样本）。
    try {
        const { ctx, node } = await build(480);
        node.port.postMessage({ type: 'inputMode', mode: 'port' });
        inject(node, ramp);
        node.port.postMessage({ type: 'reset' });
        await flushPort(node);
        const rendered = await ctx.startRendering();
        let peak = 0;
        const left = rendered.getChannelData(0);
        for (let i = 0; i < left.length; ++i)
            peak = Math.max(peak, Math.abs(left[i]));
        record('reset 清空端口注入 FIFO（输出静音）', peak <= EPS, '输出峰值 ' + peak.toExponential(3));
    } catch (error) {
        record('reset 清空端口注入 FIFO（输出静音）', false, '抛异常：' + String(error && error.message ? error.message : error));
    }

    return { secure: isSecureContext, sampleRate: SR, results };
})()`;

// --- 主流程 -----------------------------------------------------------------

let chrome = null;
let session = null;
let chromeStderr = '';
let exitCode = 1;

try {
    fs.rmSync(PROFILE, { recursive: true, force: true });
    fs.mkdirSync(PROFILE, { recursive: true });

    chrome = spawn(CHROME, [
        '--headless=new',
        '--no-sandbox',
        '--disable-gpu',
        '--disable-dev-shm-usage',
        '--disable-extensions',
        '--no-first-run',
        '--allow-file-access-from-files',
        `--remote-debugging-port=${DEVTOOLS_PORT}`,
        `--user-data-dir=${PROFILE}`,
        'about:blank'
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    chrome.stderr.setEncoding('utf8');
    chrome.stderr.on('data', chunk => { chromeStderr += chunk; });

    const version = await waitDevtools();
    console.log(`Chrome：${version.Browser}（pid ${chrome.pid}）`);

    // 先建空白 target，attach 后再导航到 file:// 宿主页。
    const target = await httpJson('PUT', '/json/new?' + encodeURIComponent('about:blank'));
    if (!target || !target.webSocketDebuggerUrl)
        throw new Error('无法创建 DevTools target。');

    session = new CdpSession(target.webSocketDebuggerUrl);
    await session.opened;
    await session.send('Page.enable');
    await session.send('Runtime.enable');
    await session.send('Page.navigate', { url: HOST_URL });

    let pageReady = false;
    for (let attempt = 0; attempt < 100; ++attempt) {
        const state = await session.evaluate(
            '({ ready: document.readyState, href: location.href, secure: isSecureContext, hasContext: typeof OfflineAudioContext })',
            false
        );
        if (state && state.ready === 'complete' && state.hasContext === 'function' && state.secure) {
            console.log(`宿主页面：${state.href}（isSecureContext=${state.secure}）`);
            pageReady = true;
            break;
        }
        await sleep(150);
    }
    if (!pageReady)
        throw new Error('宿主页面没有就绪（file:// 页面加载失败？）');

    console.log(`worklet：${WORKLET_PATH}`);
    console.log('开始离线渲染断言……\n');

    const report = await session.evaluate(pageScript, true, 120000);
    const results = report && Array.isArray(report.results) ? report.results : [];
    if (results.length === 0)
        throw new Error('页面没有返回任何断言结果。');

    let failed = 0;
    for (const result of results) {
        if (!result.pass)
            failed++;
        console.log(`[${result.pass ? 'PASS' : 'FAIL'}] ${result.name} — ${result.detail}`);
    }
    console.log(`\n合计 ${results.length} 项断言：${results.length - failed} 通过，${failed} 失败。`);

    exitCode = failed === 0 ? 0 : 1;
} catch (error) {
    console.error(`\n验证脚本失败：${error && error.message ? error.message : error}`);
    const tail = chromeStderr.trim().split('\n').slice(-8).join('\n');
    if (tail)
        console.error('Chrome stderr（尾部）：\n' + tail);
    exitCode = 1;
} finally {
    if (session)
        session.close();
    if (chrome && !chrome.killed) {
        chrome.kill('SIGKILL');
        await new Promise(resolve => {
            chrome.once('exit', resolve);
            setTimeout(resolve, 2000);
        });
    }
    // Chrome 退出时子进程可能还在写 profile 目录，清理失败不影响断言结果。
    try {
        await new Promise(resolve => setTimeout(resolve, 300));
        fs.rmSync(PROFILE, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch (error) {
        console.error(`清理临时 profile 失败（忽略）：${error && error.message ? error.message : error}`);
    }
    console.log(`\n退出码：${exitCode}`);
    process.exit(exitCode);
}
