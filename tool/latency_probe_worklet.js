/*
 * guitarbook · 浏览器效果器监听延迟测量探针（AudioWorklet）
 *
 * 不是 DSP 内核的一部分，只服务于 tool/check_web_latency.mjs 与
 * tool/check_web_latency_mstp.mjs。
 *
 * 注册处理器 `latency-detector`：
 *   - 1 路输入、1 路输出（输出恒为静音，仅为了让节点被音频图拉动）；
 *   - 主线程预先用 {type:'arm', pulses:[{index, expected}]} 告知期望的脉冲时刻
 *     （AudioContext.currentTime 时间轴，单位秒）；
 *   - 在输入样本中检测首次越过阈值的采样点，用
 *     currentTime + i / sampleRate 记录到达时刻，回报 delta = 到达 - 期望；
 *   - 超过 timeoutSec 仍未检测到就回报 missed。
 *
 * 为什么用阈值检测而不是互相关：脉冲是 1 kHz、幅度 0.4、50 ms 级信噪比，
 * 阈值穿越的误差 < 0.2 ms，足够分辨 10~50 ms 的延迟；而且实现简单、可复核。
 *
 * ── 扩展（2026-11-03，MSTP 路径）─────────────────────────────────────────
 * 新增「帧喂入」模式：主线程从 MediaStreamTrackProcessor 读到 AudioData 后，
 * 用 {type:'frame', buffer, frames, sampleRate, tsUs, tsMs, readWall} 把
 * 平面 0 的 Float32 采样通过 port（transferable ArrayBuffer）送进来。
 * worklet 在没有输入节点连线的情况下照样做阈值检测，并回报：
 *   - crossingIndex：越过阈值的那一采样点在帧内的下标；
 *   - frameTimestampMs / readWall：主线程给的帧时间戳与读取时刻（wall clock，ms）；
 *   - frameArrivalAudio / arrivalAudioEstimate：用 currentTime + 当前 render
 *     quantum 内偏移估算的音频时钟时刻（详见 estimateAudioNow 的注释）。
 *
 * worklet → 主线程消息：
 *   {type:'detection', index, expected, arrival, deltaMs, peak}            （输入连线模式）
 *   {type:'missed',    index, expected}
 *   {type:'detection', index, expected, mode:'frame', crossingIndex, ...} （帧喂入模式）
 *   {type:'missed',    index, expected, mode:'frame'}
 */

'use strict';

class LatencyDetectorProcessor extends AudioWorkletProcessor {
    constructor (options) {
        super(options);
        const opts = (options && options.processorOptions) || {};
        this.threshold = typeof opts.threshold === 'number' ? opts.threshold : 0.05;
        this.timeoutSec = typeof opts.timeoutSec === 'number' ? opts.timeoutSec : 0.3;
        this.pulses = [];
        this.cursor = 0;

        // 帧喂入模式的状态
        this.frameMode = false;
        this.prevSample = 0;          // 跨帧保持的上升沿判据
        this.audioOffsetMs = 0;       // 粗略的 wall(ms) → audio(s) 偏移，仅用于宽松时间门限

        // render quantum 起点（用于 currentTime + quantum 内偏移估算）
        this.quantumStartAudio = 0;
        this.quantumStartPerf = 0;
        this.quantumStartFrame = 0;
        this.hasPerf = (typeof performance !== 'undefined' && performance !== null &&
                         typeof performance.now === 'function');
        this.perfSource = this.hasPerf ? 'performance.now' : 'Date.now';

        this.port.onmessage = event => {
            const data = event.data || {};
            if (data.type === 'arm') {
                this.pulses = (data.pulses || []).slice()
                    .sort((a, b) => a.expected - b.expected)
                    .map(p => ({ index: p.index, expected: p.expected, done: false, missed: false }));
                this.cursor = 0;
                this.prevSample = 0;
                if (typeof data.audioOffsetMs === 'number') this.audioOffsetMs = data.audioOffsetMs;
                if (data.mode === 'frame') this.frameMode = true;
            } else if (data.type === 'frame') {
                this.handleFrame(data);
            }
        };
    }

    /*
     * 估算「此刻」的音频时钟时刻。
     *
     * AudioWorkletGlobalScope 里的 currentTime 只在每个 render quantum（128 帧）
     * 开始时前进，quantum 内部不再变化；而 port 消息是在两次 process() 之间
     * 投递的，因此消息处理时 currentTime 落后于真实位置最多 1 个 quantum
     * （48 kHz 下 2.667 ms）。
     *
     * 估算方法：记录每个 quantum 起点处的 (currentTime, currentFrame,
     * performance.now())，在消息处理时用 performance.now() 与 quantum 起点的
     * perf 时间差算出 quantum 内的偏移，夹在 [0, 128/sampleRate] 内：
     *
     *   audio_now ≈ currentTime_at_quantum_start + (perf_now - perf_at_quantum_start)/1000
     *
     * 误差量级：≤ 1 个 render quantum（2.667 ms @48 kHz）+ performance.now()
     * 的抖动（通常 < 0.1 ms）。currentFrame 只用于交叉校验
     * （currentTime ≈ currentFrame / sampleRate）。
     */
    estimateAudioNow () {
        const nowPerf = this.hasPerf ? performance.now() : Date.now();
        const quantumSec = 128 / sampleRate;
        let offsetSec = (nowPerf - this.quantumStartPerf) / 1000;
        if (!(offsetSec >= 0)) offsetSec = 0;
        const clamped = offsetSec > quantumSec;
        if (clamped) offsetSec = quantumSec;
        return {
            audio: this.quantumStartAudio + offsetSec,
            offsetMs: offsetSec * 1000,
            quantumMs: quantumSec * 1000,
            clamped,
            perfSource: this.perfSource,
            currentFrame: this.quantumStartFrame,
            quantumStartAudio: this.quantumStartAudio
        };
    }

    /*
     * 处理一帧从 MediaStreamTrackProcessor 送来的采样。
     * 帧内采样率可能与本 AudioContext 不同（设备 44100 / 上下文 48000 都出现过），
     * 因此阈值检测与到达时刻都按帧自己的 sampleRate 计算。
     */
    handleFrame (data) {
        if (!data.buffer) return;
        const samples = new Float32Array(data.buffer);
        const sr = typeof data.sampleRate === 'number' && data.sampleRate > 0
            ? data.sampleRate
            : sampleRate;

        const now = this.estimateAudioNow();

        // 先把已经超时的脉冲判为 missed，避免 cursor 卡住。
        while (this.cursor < this.pulses.length) {
            const pending = this.pulses[this.cursor];
            if (pending.done || pending.expected + this.timeoutSec >= now.audio) break;
            pending.done = true;
            pending.missed = true;
            this.port.postMessage({
                type: 'missed',
                index: pending.index,
                expected: pending.expected,
                mode: 'frame'
            });
            this.cursor++;
        }

        const next = this.cursor < this.pulses.length ? this.pulses[this.cursor] : null;
        if (!next || next.done) return;

        // 宽松时间门限：用主线程给的粗略 offset 把帧的 wall 时间戳换算成
        // 音频时钟数量级，用来挡掉「脉冲还没开始就出现的噪声/提示音」。
        const frameTsMs = typeof data.tsMs === 'number' ? data.tsMs : null;
        let frameAudioSec = null;
        if (frameTsMs !== null) frameAudioSec = (frameTsMs + this.audioOffsetMs) / 1000;
        if (frameAudioSec !== null && frameAudioSec < next.expected - 0.05) return;

        let prev = this.prevSample;
        for (let i = 0; i < samples.length; i++) {
            const value = samples[i];
            const magnitude = value < 0 ? -value : value;
            const prevMag = prev < 0 ? -prev : prev;
            if (magnitude >= this.threshold && prevMag < this.threshold) {
                next.done = true;
                this.port.postMessage({
                    type: 'detection',
                    index: next.index,
                    expected: next.expected,
                    mode: 'frame',
                    // 与输入连线模式同口径：到达时刻 - 期望时刻（音频时钟域，单位 ms）。
                    // 帧喂入模式下「到达时刻」= worklet 处理到该帧的时刻（音频时钟估计值）。
                    arrival: now.audio,
                    deltaMs: (now.audio - next.expected) * 1000,
                    crossingIndex: i,
                    frameFrames: samples.length,
                    frameSampleRate: sr,
                    frameTimestampUs: typeof data.tsUs === 'number' ? data.tsUs : null,
                    frameTimestampMs: frameTsMs,
                    readWall: typeof data.readWall === 'number' ? data.readWall : null,
                    seq: typeof data.seq === 'number' ? data.seq : null,
                    // 帧到达（worklet 收到帧）的音频时钟估计
                    frameArrivalAudio: now.audio,
                    // 处理该帧的那个 render quantum 的音频时钟起点（精确值，无估算误差）
                    quantumStartAudio: now.quantumStartAudio,
                    // 采样点被处理时的音频时钟估计（上限值：真实采集时刻更早）
                    arrivalAudioEstimate: now.audio + i / sr,
                    quantumOffsetMs: now.offsetMs,
                    quantumMs: now.quantumMs,
                    perfSource: now.perfSource,
                    peak: magnitude
                });
                this.cursor++;
                this.prevSample = 0;
                return;
            }
            prev = value;
        }
        this.prevSample = prev;
    }

    process (inputs, outputs) {
        const output = outputs[0];
        if (output)
            for (let c = 0; c < output.length; c++) output[c].fill(0);

        // 记录本 quantum 的起点，用于 currentTime + quantum 内偏移估算。
        this.quantumStartAudio = currentTime;
        this.quantumStartFrame = currentFrame;
        this.quantumStartPerf = this.hasPerf ? performance.now() : Date.now();

        const input = inputs[0] || [];
        const frames = (input && input.length && input[0]) ? input[0].length : 128;

        for (let i = 0; i < frames; i++) {
            const t = currentTime + i / sampleRate;

            // 先把已经超时的脉冲判为 missed，避免 cursor 卡住。
            while (this.cursor < this.pulses.length) {
                const pending = this.pulses[this.cursor];
                if (pending.done || pending.expected + this.timeoutSec >= t) break;
                pending.done = true;
                pending.missed = true;
                this.port.postMessage({ type: 'missed', index: pending.index, expected: pending.expected });
                this.cursor++;
            }

            const next = this.cursor < this.pulses.length ? this.pulses[this.cursor] : null;
            if (!next || next.done) continue;

            // 脉冲不可能早于 expected 到达，所以只在 expected 之后做阈值检测。
            if (t < next.expected - 1e-6) continue;

            let peak = 0;
            for (let c = 0; c < input.length; c++) {
                const value = input[c][i];
                const magnitude = value < 0 ? -value : value;
                if (magnitude > peak) peak = magnitude;
            }
            if (peak < this.threshold) continue;

            next.done = true;
            this.port.postMessage({
                type: 'detection',
                index: next.index,
                expected: next.expected,
                arrival: t,
                deltaMs: (t - next.expected) * 1000,
                peak
            });
            this.cursor++;
        }
        return true;
    }
}

registerProcessor('latency-detector', LatencyDetectorProcessor);
