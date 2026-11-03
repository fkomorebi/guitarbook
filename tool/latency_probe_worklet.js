/*
 * guitarbook · 浏览器效果器监听延迟测量探针（AudioWorklet）
 *
 * 不是 DSP 内核的一部分，只服务于 tool/check_web_latency.mjs。
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
 * worklet → 主线程消息：
 *   {type:'detection', index, expected, arrival, deltaMs, peak}
 *   {type:'missed',    index, expected}
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
        this.port.onmessage = event => {
            const data = event.data || {};
            if (data.type === 'arm') {
                this.pulses = (data.pulses || []).slice()
                    .sort((a, b) => a.expected - b.expected)
                    .map(p => ({ index: p.index, expected: p.expected, done: false, missed: false }));
                this.cursor = 0;
            }
        };
    }

    process (inputs, outputs) {
        const output = outputs[0];
        if (output)
            for (let c = 0; c < output.length; c++) output[c].fill(0);

        const input = inputs[0];
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
