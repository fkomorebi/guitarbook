/*
 * guitarbook Web 效果器 DSP 内核 · Node 离线回归
 *
 * 运行：node tool/effects_worklet_test.js
 *
 * 断言镜像 native/effects_host/builtin_effect_tests.h（原生 JUCE C++ 回归），
 * 数值与契约一致：
 *   1. 静音输入 → 输出静音
 *   2. 44100/48000/96000 × 10 种 kind，参数在最小/最大值间来回切换 40 块 → 输出必须全部有限
 *   3. amp 参考渲染：幅度 > 0.01；四款箱头两两 Σ|Δ| > 1；6 个参数各自能改变输出；
 *      master=0 → 静音；两个独立实例输出完全一致（不共享状态）
 *   4. wah：幅度 > 0.001；param0..3 各自改变输出；level=0 → 静音；
 *      自动哇与手动哇有差异（speed/depth 生效）；depth=0 时与手动 wah 差 < 0.001；
 *      mix=0 且 level=1 → 第 0 个采样 = 0.5 且右声道静音
 *   5. delay：time=20ms、feedback=0.5、mix=1，脉冲 0.5 → sample0 == 0、
 *      sample960 == 0.5±0.001、sample1920 == 0.25±0.001
 *   6. compressor：threshold=-20、ratio=4、attack=1ms、makeup=0，16384 个 0.5 常量
 *      → 末样本 0.149535±0.001
 *   7. reverb：mix=0 → sample0 == 0.5±0.0001（干声 unity）；mix=1 → |sample0| < 0.0001
 *      且 [1000,4096) 有尾巴幅度 > 0.0001
 *   8. 新建的 delay 实例不得继承别的实例尾巴
 *
 * 附加（不计入上面 8 项）：worklet 消息协议的越界保护与电平上报自检。
 */

'use strict';

const path = require('path');
const worklet = require(path.join(__dirname, '..', 'web', 'effects_worklet.js'));

const {
    BuiltinEffect,
    EffectChain,
    GuitarbookEffectsProcessor
} = worklet;

const RENDER_RATE = 48000;
const RENDER_SAMPLES = 4096;
const ALL_KINDS = [
    'fuzz', 'overdrive', 'wah', 'compressor', 'reverb', 'delay',
    'amp_clean', 'amp_chime', 'amp_crunch', 'amp_modern'
];

// ---------------------------------------------------------------------------
// 断言工具
// ---------------------------------------------------------------------------

function assertTrue (condition, message) {
    if (!condition)
        throw new Error(message);
}

function assertEqual (actual, expected, message) {
    if (actual !== expected)
        throw new Error(`${message}：期望 ${expected}，实际 ${actual}`);
}

function assertNear (actual, expected, tolerance, message) {
    if (!Number.isFinite(actual) || Math.abs(actual - expected) > tolerance) {
        throw new Error(`${message}：期望 ${expected} ±${tolerance}，实际 ${actual}`
            + `（偏差 ${(actual - expected).toFixed(6)}）`);
    }
}

// ---------------------------------------------------------------------------
// 缓冲区工具（等价 juce::AudioBuffer<float> 的两个声道）
// ---------------------------------------------------------------------------

function stereoBuffer (samples) {
    return [new Float64Array(samples), new Float64Array(samples)];
}

/** 等价 AudioBuffer::getMagnitude(channel, startSample, numSamples)。 */
function magnitude (buffer, channel, start, count) {
    let peak = 0;
    for (let i = start; i < start + count; ++i) {
        const value = Math.abs(buffer[channel][i]);
        if (value > peak)
            peak = value;
    }
    return peak;
}

/** 等价原生测试里的 difference()：左声道 Σ|Δ|。 */
function difference (a, b) {
    let sum = 0;
    for (let i = 0; i < a[0].length; ++i)
        sum += Math.abs(a[0][i] - b[0][i]);
    return sum;
}

/** 箱头 / 哇音参考渲染：0.12*(sin(110Hz) + sin(997Hz) + sin(6000Hz))。 */
function renderReference (kind, parameter, value) {
    const effect = new BuiltinEffect(kind, RENDER_RATE);
    if (parameter >= 0)
        effect.setParameterValue(parameter, value);
    effect.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
    const buffer = stereoBuffer(RENDER_SAMPLES);
    for (let i = 0; i < RENDER_SAMPLES; ++i) {
        const t = i / RENDER_RATE;
        const sample = 0.12 * (Math.sin(t * 2 * Math.PI * 110)
            + Math.sin(t * 2 * Math.PI * 997)
            + Math.sin(t * 2 * Math.PI * 6000));
        buffer[0][i] = sample;
        buffer[1][i] = sample;
    }
    effect.processBlock(buffer[0], buffer[1], RENDER_SAMPLES);
    return buffer;
}

// ---------------------------------------------------------------------------
// 8 项断言
// ---------------------------------------------------------------------------

const cases = [];

function testCase (name, fn) {
    cases.push({ name, fn });
}

testCase('1. 静音输入 → 输出静音（10 种效果器 × 3 个采样率）', () => {
    for (const rate of [44100, 48000, 96000]) {
        for (const kind of ALL_KINDS) {
            const effect = new BuiltinEffect(kind, rate);
            effect.prepareToPlay(rate, 512);
            const buffer = stereoBuffer(512);
            effect.processBlock(buffer[0], buffer[1], 512);
            const peak = magnitude(buffer, 0, 0, 512);
            assertEqual(peak, 0, `${kind} @ ${rate} Hz：静音输入应保持静音`);
        }
    }
});

testCase('2. 参数在最小/最大值间切换 40 块 → 输出全部有限', () => {
    for (const rate of [44100, 48000, 96000]) {
        for (const kind of ALL_KINDS) {
            const effect = new BuiltinEffect(kind, rate);
            effect.prepareToPlay(rate, 512);
            const buffer = stereoBuffer(512);
            for (let block = 0; block < 40; ++block) {
                for (let i = 0; i < effect.parameters.length; ++i) {
                    const parameter = effect.parameters[i];
                    effect.setParameterValue(i, block % 2 ? parameter.min : parameter.max);
                }
                for (let i = 0; i < 512; ++i) {
                    const sample = 0.3 * Math.sin((block * 512 + i) * 2 * Math.PI * 220 / rate);
                    buffer[0][i] = sample;
                    buffer[1][i] = sample;
                }
                effect.processBlock(buffer[0], buffer[1], 512);
                for (let i = 0; i < 512; ++i) {
                    assertTrue(Number.isFinite(buffer[0][i]),
                        `${kind} @ ${rate} Hz 第 ${block} 块左声道出现非有限值：${buffer[0][i]}`);
                    assertTrue(Number.isFinite(buffer[1][i]),
                        `${kind} @ ${rate} Hz 第 ${block} 块右声道出现非有限值：${buffer[1][i]}`);
                }
            }
        }
    }
});

testCase('3. 箱头：幅度 > 0.01 / 四款音色互异 / 6 个参数有效 / master=0 静音 / 实例不共享状态', () => {
    const models = [];
    for (const kind of ['amp_clean', 'amp_chime', 'amp_crunch', 'amp_modern']) {
        const reference = renderReference(kind, -1, 0);
        const peak = magnitude(reference, 0, 0, RENDER_SAMPLES);
        assertTrue(peak > 0.01, `${kind} 参考渲染幅度应为 > 0.01，实际 ${peak}`);
        for (const previous of models) {
            const delta = difference(reference, previous);
            assertTrue(delta > 1, `${kind} 与前一款箱头波形应不同（Σ|Δ| = ${delta}，需 > 1）`);
        }
        for (let parameter = 0; parameter < 6; ++parameter) {
            const value = parameter === 0 ? 10 : parameter < 4 ? -12 : 0;
            const changed = renderReference(kind, parameter, value);
            const delta = difference(reference, changed);
            assertTrue(delta > 1, `${kind} 第 ${parameter} 个参数应能改变输出（Σ|Δ| = ${delta}，需 > 1）`);
            if (parameter === 4)
                assertEqual(magnitude(changed, 0, 0, RENDER_SAMPLES), 0, `${kind} master=0 应完全静音`);
        }
        const delta = difference(reference, renderReference(kind, -1, 0));
        assertEqual(delta, 0, `${kind} 两个独立实例输出应完全一致（不共享状态），实际 Σ|Δ| = ${delta}`);
        models.push(reference);
    }
});

testCase('4. 哇音：幅度 > 0.001 / 参数有效 / level=0 静音 / 自动扫频 / 干声 unity 与通道隔离', () => {
    const reference = renderReference('wah', -1, 0);
    const peak = magnitude(reference, 0, 0, RENDER_SAMPLES);
    assertTrue(peak > 0.001, `wah 参考渲染幅度应为 > 0.001，实际 ${peak}`);
    for (let parameter = 0; parameter < 4; ++parameter) {
        const value = parameter === 1 ? 8.0 : 0.0;
        const changed = renderReference('wah', parameter, value);
        const delta = difference(reference, changed);
        assertTrue(delta > 1, `wah 第 ${parameter} 个参数应能改变输出（Σ|Δ| = ${delta}，需 > 1）`);
        if (parameter === 3)
            assertEqual(magnitude(changed, 0, 0, RENDER_SAMPLES), 0, 'wah level=0 应完全静音');
    }
    const isolated = difference(reference, renderReference('wah', -1, 0));
    assertEqual(isolated, 0, `wah 两个独立实例输出应完全一致，实际 Σ|Δ| = ${isolated}`);

    // 自动哇：auto=1，speed/depth 生效，depth=0 时与手动 wah 一致。
    const renderAutoWah = (speed, depth) => {
        const wah = new BuiltinEffect('wah', RENDER_RATE);
        wah.setParameterValue(4, 1);
        wah.setParameterValue(5, speed);
        wah.setParameterValue(6, depth);
        wah.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
        const buffer = stereoBuffer(RENDER_SAMPLES);
        for (let i = 0; i < RENDER_SAMPLES; ++i) {
            const t = i / RENDER_RATE;
            const sample = 0.12 * (Math.sin(t * 2 * Math.PI * 110)
                + Math.sin(t * 2 * Math.PI * 997)
                + Math.sin(t * 2 * Math.PI * 6000));
            buffer[0][i] = sample;
            buffer[1][i] = sample;
        }
        wah.processBlock(buffer[0], buffer[1], RENDER_SAMPLES);
        return buffer;
    };

    const autoWah = renderAutoWah(1, 0.8);
    const sweepDelta = difference(reference, autoWah);
    assertTrue(sweepDelta > 1, `自动哇应与手动哇有差异（Σ|Δ| = ${sweepDelta}，需 > 1）`);
    const speedDelta = difference(autoWah, renderAutoWah(5, 0.8));
    assertTrue(speedDelta > 1, `自动哇速度应影响输出（Σ|Δ| = ${speedDelta}，需 > 1）`);
    const depthDelta = difference(autoWah, renderAutoWah(1, 0.2));
    assertTrue(depthDelta > 1, `自动哇深度应影响输出（Σ|Δ| = ${depthDelta}，需 > 1）`);
    const zeroDepthDelta = difference(reference, renderAutoWah(1, 0));
    assertTrue(zeroDepthDelta < 0.001,
        `depth=0 应与手动 wah 一致（Σ|Δ| = ${zeroDepthDelta}，需 < 0.001）`);

    // 干声 unity 与声道隔离：mix=0、level=1。
    const dryWah = new BuiltinEffect('wah', RENDER_RATE);
    dryWah.setParameterValue(2, 0);
    dryWah.setParameterValue(3, 1);
    dryWah.prepareToPlay(RENDER_RATE, 512);
    const dry = stereoBuffer(512);
    dry[0][0] = 0.5;
    dryWah.processBlock(dry[0], dry[1], 512);
    assertEqual(dry[0][0], 0.5, 'wah mix=0 时左声道第 0 个采样应保持 0.5');
    assertEqual(magnitude(dry, 1, 0, 512), 0, 'wah mix=0 时右声道应完全静音');
});

testCase('5. 延迟：全湿不漏干声 / 960 采样处 0.5 / 1920 采样处 0.25', () => {
    const delay = new BuiltinEffect('delay', RENDER_RATE);
    delay.setParameterValue(0, 20);
    delay.setParameterValue(1, 0.5);
    delay.setParameterValue(2, 1);
    delay.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
    const impulse = stereoBuffer(RENDER_SAMPLES);
    impulse[0][0] = 0.5;
    impulse[1][0] = 0.5;
    delay.processBlock(impulse[0], impulse[1], RENDER_SAMPLES);
    assertEqual(impulse[0][0], 0, '全湿延迟第 0 个采样应为 0（不漏干声）');
    assertNear(impulse[0][960], 0.5, 0.001, '延迟 20ms 首次回声');
    assertNear(impulse[0][1920], 0.25, 0.001, '延迟 feedback=0.5 第二次回声');
});

testCase('6. 压缩器：阈值 -20 / 比例 4 / 启动 1ms / 补偿 0 → 末样本 0.149535±0.001', () => {
    const compressor = new BuiltinEffect('compressor', RENDER_RATE);
    compressor.setParameterValue(0, -20);
    compressor.setParameterValue(1, 4);
    compressor.setParameterValue(2, 1);
    compressor.setParameterValue(4, 0);
    compressor.prepareToPlay(RENDER_RATE, 16384);
    const sustained = stereoBuffer(16384);
    sustained[0].fill(0.5);
    sustained[1].fill(0.5);
    compressor.processBlock(sustained[0], sustained[1], 16384);
    assertNear(sustained[0][16383], 0.149535, 0.001, '压缩器末样本');
});

testCase('7. 混响：mix=0 干声 unity / mix=1 不漏干声且有尾巴', () => {
    const reverb = new BuiltinEffect('reverb', RENDER_RATE);
    reverb.setParameterValue(2, 0);
    reverb.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
    const impulse = stereoBuffer(RENDER_SAMPLES);
    impulse[0][0] = 0.5;
    reverb.processBlock(impulse[0], impulse[1], RENDER_SAMPLES);
    assertNear(impulse[0][0], 0.5, 0.0001, '混响 mix=0 时干声应为 unity');

    reverb.setParameterValue(2, 1);
    reverb.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
    impulse[0].fill(0);
    impulse[1].fill(0);
    impulse[0][0] = 0.5;
    reverb.processBlock(impulse[0], impulse[1], RENDER_SAMPLES);
    assertTrue(Math.abs(impulse[0][0]) < 0.0001,
        `全湿混响不应漏干声，实际 ${impulse[0][0]}`);
    const tail = magnitude(impulse, 0, 1000, 3096);
    assertTrue(tail > 0.0001, `全湿混响应有尾巴，实际幅度 ${tail}`);
});

testCase('8. 新建的 delay 实例不得继承别的实例尾巴', () => {
    const fresh = new BuiltinEffect('delay', RENDER_RATE);
    fresh.prepareToPlay(RENDER_RATE, RENDER_SAMPLES);
    const buffer = stereoBuffer(RENDER_SAMPLES);
    fresh.processBlock(buffer[0], buffer[1], RENDER_SAMPLES);
    assertEqual(magnitude(buffer, 0, 0, RENDER_SAMPLES), 0, '新实例不应继承别的实例尾巴');
});

// ---------------------------------------------------------------------------
// 附加（不计入上面 8 项）：worklet 消息协议自检
// ---------------------------------------------------------------------------

function protocolChecks () {
    const processor = new GuitarbookEffectsProcessor();
    const sent = [];
    const send = message => {
        if (typeof processor.port.onmessage === 'function')
            processor.port.onmessage({ data: message });
    };

    // add / parameter / bypass / move / remove / gain / reset
    send({ type: 'add', index: 0, kind: 'delay', parameters: [20, 0.5, 1] });
    send({ type: 'add', index: 1, kind: 'overdrive', parameters: [] });
    assertEqual(processor.chain.blocks.length, 2, 'add 之后链上应有 2 块');
    assertEqual(processor.chain.blocks[0].effect.parameters[0].value, 20, 'add 的 parameters 应写入初值');

    send({ type: 'move', index: 1, destination: 0 });
    assertEqual(processor.chain.blocks[0].kind, 'overdrive', 'move 之后顺序应交换');

    send({ type: 'bypass', index: 0, value: true });
    assertEqual(processor.chain.blocks[0].bypass, true, 'bypass 应生效');

    send({ type: 'parameter', index: 0, parameter: 0, value: 12 });
    assertEqual(processor.chain.blocks[0].effect.parameters[0].value, 12, 'parameter 应生效');

    send({ type: 'gain', value: 0.5 });
    assertEqual(processor.chain.gain, 0.5, 'gain 应生效');

    // 越界保护：不得抛异常打断音频线程，只回 error。
    send({ type: 'parameter', index: 99, parameter: 0, value: 1 });
    send({ type: 'parameter', index: 0, parameter: 99, value: 1 });
    send({ type: 'remove', index: 99 });
    send({ type: 'move', index: 0, destination: 99 });
    send({ type: 'add', index: 0, kind: '不存在', parameters: [] });
    send({ type: '未知指令' });
    const errors = processor.port.posted.filter(message => message.type === 'error');
    assertTrue(errors.length >= 6, `越界指令应回 error，实际 ${errors.length} 条`);

    // 电平上报：每 ~100 ms 一次。
    const input = [new Float32Array(128)];
    const output = [new Float32Array(128), new Float32Array(128)];
    input[0].fill(0.25);
    for (let block = 0; block < 200; ++block)
        processor.process([input], [output]);
    const meters = processor.port.posted.filter(message => message.type === 'meter');
    assertTrue(meters.length >= 1, `应上报 meter，实际 ${meters.length} 条`);
    assertTrue(meters[0].input > 0 && meters[0].output > 0, 'meter 应带非零输入/输出峰值');

    send({ type: 'reset' });
    assertEqual(processor.chain.blocks.length, 0, 'reset 应清空整条链');
}

// ---------------------------------------------------------------------------
// 运行
// ---------------------------------------------------------------------------

function main () {
    console.log('guitarbook Web 效果器 DSP 内核 · Node 离线回归');
    console.log('模块：' + path.relative(process.cwd(), path.join(__dirname, '..', 'web', 'effects_worklet.js')));
    console.log('');

    let failed = 0;
    for (const item of cases) {
        try {
            item.fn();
            console.log('  ✓ ' + item.name);
        } catch (error) {
            ++failed;
            console.log('  ✗ ' + item.name);
            console.log('      ' + error.message);
        }
    }

    console.log('');
    try {
        protocolChecks();
        console.log('  ✓ 附加：worklet 消息协议（越界保护 / 电平上报 / reset）');
    } catch (error) {
        ++failed;
        console.log('  ✗ 附加：worklet 消息协议（越界保护 / 电平上报 / reset）');
        console.log('      ' + error.message);
    }

    console.log('');
    if (failed > 0) {
        console.error(`回归失败：${failed} / ${cases.length + 1} 项未通过`);
        process.exit(1);
    }
    console.log(`回归通过：${cases.length + 1} / ${cases.length + 1} 项全部通过（Web 效果器 DSP 内核与原生一致）`);
    process.exit(0);
}

main();
