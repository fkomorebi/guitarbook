/*
 * guitarbook · 电脑端浏览器版效果器 DSP 内核（AudioWorklet）
 *
 * 1:1 移植自 native/effects_host/builtin_effect.h（JUCE C++ 内置效果器）：
 *   fuzz / overdrive / wah / compressor / reverb / delay / pitch /
 *   amp_clean / amp_chime / amp_crunch / amp_modern
 *
 * 移调（pitch）另有一份两端共用的权威规格：docs/pitch_shifter_spec.md，
 * C++ 与 JS 必须按同一份规格实现（同一输入 → 浮点误差 ≤ 1e-4）。
 *
 * 约束：
 *   - 单文件、自包含：无 import / 无 fetch / 无 DOM 依赖（AudioWorkletGlobalScope 里没有 DOM）。
 *   - 同一份代码既能在浏览器里 registerProcessor('guitarbook-effects')，也能被 Node require 做离线回归。
 *   - 逐样本公式照抄 C++ 语义，不做「优化」或改写数学。
 *
 * 主线程 → worklet 消息协议：
 *   {type:'add',       index:int, kind:String, parameters:[double]}
 *   {type:'remove',    index:int}
 *   {type:'move',      index:int, destination:int}
 *   {type:'bypass',    index:int, value:bool}
 *   {type:'parameter', index:int, parameter:int, value:double}
 *   {type:'gain',      value:double}          // 输出音量 0..1
 *   {type:'reset'}                           // 清空整条链并复位状态
 *   {type:'input',     buffer:ArrayBuffer, frames:int}
 *       // 主线程注入的采集帧：buffer 为单声道 Float32 的原始字节（byteOffset 0），
 *       // frames 为采样数，追加到端口输入 FIFO，供 inputMode:'port' 消费。
 *   {type:'inputMode', mode:'port'|'node'}
 *       // 'port' = 优先消费 FIFO（欠载补零）；'node' = 走音频节点输入（默认，行为不变）。
 *
 * worklet → 主线程 消息协议：
 *   {type:'meter', input:double, output:double}   // 每 ~100 ms 最多一次
 *   {type:'error', message:String}                // 运行期错误（越界 / 非法参数等）
 *
 * 链上块的定位就是数组下标 index（协议里没有 id 字段）。
 */

'use strict';

(function () {

    // ---------------------------------------------------------------------------
    // 0. 运行环境守卫：浏览器 AudioWorkletGlobalScope 与 Node CommonJS 双向兼容
    // ---------------------------------------------------------------------------

    /** 是否运行在真正的 AudioWorklet 环境（浏览器）。 */
    const WORKLET_SCOPE = typeof AudioWorkletProcessor !== 'undefined'
        && typeof registerProcessor === 'function';

    /** worklet 的全局采样率；Node / 普通网页下没有这个全局，回落到 48 kHz。 */
    const GLOBAL_SAMPLE_RATE = (typeof AudioWorkletProcessor !== 'undefined'
        && typeof sampleRate === 'number' && isFinite(sampleRate) && sampleRate > 0)
        ? sampleRate
        : 48000;

    /** 链上最多 8 块（与原生宿主一致）。 */
    const MAX_EFFECTS = 8;

    /** 注册名（协议固定）。 */
    const PROCESSOR_NAME = 'guitarbook-effects';

    /** Node 环境下用的假端口：记录 postMessage 的内容，便于离线回归断言。 */
    function createStubPort () {
        const posted = [];
        return {
            posted,
            onmessage: null,
            postMessage (message) { posted.push(message); }
        };
    }

    /** Node 环境下 AudioWorkletProcessor 的替身，保证类定义不引用不存在的全局。 */
    class StubAudioWorkletProcessor {
        constructor () {
            this.port = createStubPort();
        }
    }

    const BaseProcessor = WORKLET_SCOPE ? AudioWorkletProcessor : StubAudioWorkletProcessor;

    // ---------------------------------------------------------------------------
    // 1. 基础数学工具（对齐 JUCE 的 jlimit / jmax / Decibels）
    // ---------------------------------------------------------------------------

    const TWO_PI = Math.PI * 2;

    function jlimit (min, max, value) {
        return value < min ? min : (value > max ? max : value);
    }

    function jmax (a, b) {
        return a > b ? a : b;
    }

    /** JUCE Decibels::decibelsToGain：10^(dB/20)。 */
    function decibelsToGain (decibels) {
        return Math.pow(10.0, decibels / 20.0);
    }

    /** JUCE Decibels::gainToDecibels：gain <= 0 时返回 minusInfinityDb。 */
    function gainToDecibels (gain, minusInfinityDb) {
        return gain > 0 ? 20.0 * Math.log10(gain) : minusInfinityDb;
    }

    // ---------------------------------------------------------------------------
    // 2. 参数平滑器（等价 JUCE SmoothedValue）
    // ---------------------------------------------------------------------------

    /**
     * 与 juce::SmoothedValue 等价的线性渐变器。
     * - reset(rate, 0.02) → rampLength = round(0.02 * rate) 采样
     * - setCurrentAndTargetValue(v)：直接落到 v（初始化用，无渐变）
     * - setTargetValue(v)：设定目标；每采样线性逼近，收敛后输出目标值
     * - getNextValue()：取下一个采样值
     * - skip(n)：推进 n 个采样但不取值（reverb 分支用）
     */
    class SmoothedValue {
        constructor () {
            this.rampLength = 0;
            this.counter = 0;
            this.rampDelta = 0;
            this.value = 0;
            this.target = 0;
        }

        reset (rate, rampLengthSeconds) {
            this.rampLength = Math.round(rate * rampLengthSeconds);
            this.counter = 0;
            this.rampDelta = 0;
            this.value = 0;
            this.target = 0;
        }

        setCurrentAndTargetValue (value) {
            this.value = value;
            this.target = value;
            this.counter = 0;
            this.rampDelta = 0;
        }

        setTargetValue (value) {
            if (value === this.target)
                return;
            this.target = value;
            if (this.rampLength <= 0) {
                this.value = this.target;
                this.counter = 0;
                this.rampDelta = 0;
                return;
            }
            this.rampDelta = (this.target - this.value) / this.rampLength;
        }

        getNextValue () {
            let result;
            if (this.counter < this.rampLength) {
                this.value += this.rampDelta;
                ++this.counter;
                if (this.counter >= this.rampLength)
                    this.value = this.target;
                result = this.value;
            } else {
                this.value = this.target;
                result = this.target;
            }
            // 逼近完成（差值 < 1e-6）后直接输出目标值。
            if (Math.abs(this.target - result) < 1e-6) {
                result = this.target;
                this.value = this.target;
            }
            return result;
        }

        skip (numSamples) {
            if (numSamples <= 0)
                return this.value;
            if (this.counter < this.rampLength) {
                this.counter += numSamples;
                if (this.counter >= this.rampLength) {
                    this.counter = this.rampLength;
                    this.value = this.target;
                    this.rampDelta = 0;
                } else {
                    this.value += this.rampDelta * numSamples;
                }
            }
            return this.value;
        }
    }

    // ---------------------------------------------------------------------------
    // 3. 混响：Freeverb 结构等效实现（8 comb + 4 allpass，双声道）
    //    原生用闭源的 JUCE Reverb，无法逐样本对齐；这里是结构等效的替身。
    // ---------------------------------------------------------------------------

    /** 44.1 kHz 基准的 comb 调谐。 */
    const COMB_TUNINGS = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
    /** 44.1 kHz 基准的 allpass 调谐。 */
    const ALLPASS_TUNINGS = [556, 441, 341, 225];
    /** 右声道 comb 长度额外 +23 采样，做立体声展宽。 */
    const STEREO_SPREAD = 23;

    class CombFilter {
        constructor (size) {
            this.size = Math.max(1, size);
            this.buffer = new Float32Array(this.size);
            this.index = 0;
            this.feedback = 0.84;
            this.damp1 = 0.2;
            this.damp2 = 0.8;
            this.filterStore = 0;
        }

        setFeedback (value) { this.feedback = value; }
        setDamp1 (value) { this.damp1 = value; this.damp2 = 1 - value; }

        reset () {
            this.buffer.fill(0);
            this.index = 0;
            this.filterStore = 0;
        }

        process (input) {
            const output = this.buffer[this.index];
            this.filterStore = output * this.damp2 + this.filterStore * this.damp1;
            this.buffer[this.index] = input + this.filterStore * this.feedback;
            this.index = this.index + 1 >= this.size ? 0 : this.index + 1;
            return output;
        }
    }

    class AllPassFilter {
        constructor (size, feedback) {
            this.size = Math.max(1, size);
            this.buffer = new Float32Array(this.size);
            this.index = 0;
            this.feedback = feedback;
        }

        setFeedback (value) { this.feedback = value; }

        reset () {
            this.buffer.fill(0);
            this.index = 0;
        }

        process (input) {
            const bufout = this.buffer[this.index];
            const output = bufout - input;
            this.buffer[this.index] = input + bufout * this.feedback;
            this.index = this.index + 1 >= this.size ? 0 : this.index + 1;
            return output;
        }
    }

    class FreeverbReverb {
        constructor (rate) {
            this.rate = rate;
            this.combs = [[], []];
            this.allpasses = [[], []];
            const scale = rate / 44100;
            for (let channel = 0; channel < 2; ++channel) {
                for (let i = 0; i < COMB_TUNINGS.length; ++i) {
                    const spread = channel === 1 ? STEREO_SPREAD : 0;
                    this.combs[channel].push(new CombFilter(Math.round(COMB_TUNINGS[i] * scale) + spread));
                }
                for (let i = 0; i < ALLPASS_TUNINGS.length; ++i) {
                    this.allpasses[channel].push(new AllPassFilter(Math.round(ALLPASS_TUNINGS[i] * scale), 0.2));
                }
            }
            // Freeverb 原始固定增益（湿声整体电平），湿干比由 mix 决定。
            this.fixedGain = 0.015;
            this.room = 0.5;
            this.damping = 0.5;
            this.mix = 0.25;
            this.dryGain = 1 - this.mix;
            this.wetGain = this.mix;
            this.applyParameters();
        }

        setRoom (room) {
            this.room = jlimit(0, 1, room);
            this.applyParameters();
        }

        setDamping (damping) {
            this.damping = jlimit(0, 1, damping);
            this.applyParameters();
        }

        setMix (mix) {
            this.mix = jlimit(0, 1, mix);
            // 原生内部 wet×3、dry×2，净效果 dryGain = 1-mix、wetGain = mix。
            this.dryGain = 1 - this.mix;
            this.wetGain = this.mix;
        }

        applyParameters () {
            // room → comb 反馈 0.7 + room*0.28
            const feedback = 0.7 + this.room * 0.28;
            // damping → damp1 = damping*0.4，damp2 = 1-damp1
            const damp1 = this.damping * 0.4;
            for (let channel = 0; channel < 2; ++channel) {
                for (const comb of this.combs[channel])
                    comb.setFeedback(feedback);
                for (const comb of this.combs[channel])
                    comb.setDamp1(damp1);
                for (const allpass of this.allpasses[channel])
                    allpass.setFeedback(damp1);
            }
        }

        reset () {
            for (let channel = 0; channel < 2; ++channel) {
                for (const comb of this.combs[channel])
                    comb.reset();
                for (const allpass of this.allpasses[channel])
                    allpass.reset();
            }
        }

        /** 就地处理：left/right 为同一段立体声缓冲。 */
        processStereo (left, right, samples) {
            for (let i = 0; i < samples; ++i) {
                const inputLeft = left[i];
                const inputRight = right[i];
                let wetLeft = 0;
                let wetRight = 0;
                for (const comb of this.combs[0])
                    wetLeft += comb.process(inputLeft);
                for (const comb of this.combs[1])
                    wetRight += comb.process(inputRight);
                for (const allpass of this.allpasses[0])
                    wetLeft = allpass.process(wetLeft);
                for (const allpass of this.allpasses[1])
                    wetRight = allpass.process(wetRight);
                wetLeft *= this.fixedGain;
                wetRight *= this.fixedGain;
                left[i] = inputLeft * this.dryGain + wetLeft * this.wetGain;
                right[i] = inputRight * this.dryGain + wetRight * this.wetGain;
            }
        }
    }

    // ---------------------------------------------------------------------------
    // 4. 移调：双读头环形缓冲 + 交叉淡化（等价 C++ 端的 pitch 分支）
    //    权威规格：docs/pitch_shifter_spec.md（C++ / JS 两端共用，逐条照抄，不做改写）
    // ---------------------------------------------------------------------------

    /** 交叉淡化长度（采样），规格 §3 的 F。 */
    const PITCH_FADE_LENGTH = 256;

    /**
     * 移调状态机：两个读头在环形缓冲上以 ratio 速度推进，读头落后量越界时切换读头，
     * 并用 256 采样的线性交叉淡化避免爆音（规格 §2 / §4）。
     */
    class PitchShifter {
        /**
         * @param {number} rate 采样率
         */
        constructor (rate) {
            this.reset(rate);
        }

        /** 复位全部状态（规格 §2）：缓冲区清零、读头归零、blend = 1（0 半音直通）。 */
        reset (rate) {
            this.rate = rate;
            // D = ceil(rate * 0.03)，M = 2 * D（环形缓冲长度，两声道各一份）。
            this.delay = Math.ceil(rate * 0.03);
            this.length = this.delay * 2;
            // 触发读头切换的上下限。
            this.minDelay = this.delay / 2.0;
            this.maxDelay = this.delay * 1.5;
            this.buffer = [new Float32Array(this.length), new Float32Array(this.length)];
            this.time = 0;
            this.head = [0, 0];
            this.active = 0;
            this.fade = -1;
            // blend = 1 表示全干直通，0 表示全湿移调声。
            this.blend = 1.0;
            // 每声道二阶（一阶级联）低通状态。
            this.filter = [new Float64Array(2), new Float64Array(2)];
            // 直通融合系数的一阶平滑步长（15 ms 时间常数）。
            this.blendStep = 1 - Math.exp(-1 / (rate * 0.015));
            // 湿声柔化低通：cutoff = 0.4 * rate ⇒ 系数与采样率无关。
            this.filterAlpha = 1 - Math.exp(-TWO_PI * 0.4);
        }

        /** 规格 §4 的 mod(x, M) = x - floor(x / M) * M，结果落在 [0, M)。 */
        mod (value, modulus) {
            // 与 C++ 端 pitchMod 逐行一致：先取模，再做两道越界防御
            //（极端浮点舍入可能把结果推出 [0, M)，两端必须同样修正）。
            let result = value - Math.floor(value / modulus) * modulus;
            if (result < 0)
                result += modulus;
            if (result >= modulus)
                result -= modulus;
            return result;
        }

        /** 读取环形缓冲的一个位置：相邻两点线性插值（规格 §4「读取函数」）。 */
        read (channel, position) {
            const base = Math.floor(position);
            // 与 C++ 端 readPitch 逐行一致：索引越界时做同样的修正。
            let first = base;
            if (first < 0)
                first += this.length;
            if (first >= this.length)
                first -= this.length;
            const fraction = position - base;
            const second = (first + 1) % this.length;
            const buffer = this.buffer[channel];
            return buffer[first] * (1 - fraction) + buffer[second] * fraction;
        }
    }

    // ---------------------------------------------------------------------------
    // 5. 效果器参数表（顺序 = describeParameters() 顺序）
    // ---------------------------------------------------------------------------

    function createEffectDefinition (kind) {
        switch (kind) {
            case 'fuzz':
                return {
                    kind,
                    title: 'Fuzz 法兹',
                    model: -1,
                    parameters: [
                        { id: 'drive', name: '驱动', min: 1, max: 30, initial: 12, unit: '' },
                        { id: 'tone', name: '音色', min: 200, max: 8000, initial: 2500, unit: 'Hz' },
                        { id: 'level', name: '输出', min: 0, max: 1, initial: 0.4, unit: '' }
                    ]
                };
            case 'overdrive':
                return {
                    kind,
                    title: '过载 Overdrive',
                    model: -1,
                    parameters: [
                        { id: 'drive', name: '驱动', min: 1, max: 20, initial: 4, unit: '' },
                        { id: 'tone', name: '音色', min: 200, max: 8000, initial: 4000, unit: 'Hz' },
                        { id: 'level', name: '输出', min: 0, max: 1, initial: 0.6, unit: '' }
                    ]
                };
            case 'amp_clean':
            case 'amp_chime':
            case 'amp_crunch':
            case 'amp_modern': {
                const model = kind === 'amp_clean' ? 0 : kind === 'amp_chime' ? 1 : kind === 'amp_crunch' ? 2 : 3;
                const titles = ['美式清音箱头', '英式清脆箱头', '英式摇滚箱头', '现代高增益箱头'];
                const gains = [2, 4, 5, 6];
                return {
                    kind,
                    title: titles[model],
                    model,
                    parameters: [
                        { id: 'gain', name: '增益', min: 0, max: 10, initial: gains[model], unit: '' },
                        { id: 'bass', name: '低频', min: -12, max: 12, initial: 0, unit: 'dB' },
                        { id: 'mid', name: '中频', min: -12, max: 12, initial: 0, unit: 'dB' },
                        { id: 'treble', name: '高频', min: -12, max: 12, initial: 0, unit: 'dB' },
                        { id: 'master', name: '主音量', min: 0, max: 1, initial: 0.5, unit: '' },
                        { id: 'cab', name: '箱体', min: 0, max: 1, initial: 1, unit: '' }
                    ]
                };
            }
            case 'wah':
                return {
                    kind,
                    title: '哇音 Wah',
                    model: -1,
                    parameters: [
                        { id: 'position', name: '位置', min: 0, max: 1, initial: 0.5, unit: '' },
                        { id: 'resonance', name: '共振', min: 0.5, max: 8, initial: 2, unit: 'Q' },
                        { id: 'mix', name: '干湿比', min: 0, max: 1, initial: 1, unit: '' },
                        { id: 'level', name: '输出', min: 0, max: 1, initial: 0.7, unit: '' },
                        { id: 'auto', name: '自动', min: 0, max: 1, initial: 0, unit: '' },
                        { id: 'speed', name: '速度', min: 0.1, max: 5, initial: 1, unit: 'Hz' },
                        { id: 'depth', name: '深度', min: 0, max: 1, initial: 0.8, unit: '' }
                    ]
                };
            case 'compressor':
                return {
                    kind,
                    title: '压缩 Compressor',
                    model: -1,
                    parameters: [
                        { id: 'threshold', name: '阈值', min: -60, max: 0, initial: -24, unit: 'dB' },
                        { id: 'ratio', name: '压缩比', min: 1, max: 12, initial: 4, unit: ':1' },
                        { id: 'attack', name: '启动', min: 1, max: 100, initial: 10, unit: 'ms' },
                        { id: 'release', name: '释放', min: 20, max: 1000, initial: 300, unit: 'ms' },
                        { id: 'makeup', name: '补偿', min: 0, max: 18, initial: 3, unit: 'dB' }
                    ]
                };
            case 'reverb':
                return {
                    kind,
                    title: '混响 Reverb',
                    model: -1,
                    parameters: [
                        { id: 'room', name: '空间', min: 0, max: 1, initial: 0.5, unit: '' },
                        { id: 'damping', name: '阻尼', min: 0, max: 1, initial: 0.5, unit: '' },
                        { id: 'mix', name: '干湿比', min: 0, max: 1, initial: 0.25, unit: '' }
                    ]
                };
            case 'delay':
                return {
                    kind,
                    title: '延迟 Delay',
                    model: -1,
                    parameters: [
                        { id: 'time', name: '时间', min: 20, max: 1500, initial: 350, unit: 'ms' },
                        { id: 'feedback', name: '反馈', min: 0, max: 0.9, initial: 0.35, unit: '' },
                        { id: 'mix', name: '干湿比', min: 0, max: 1, initial: 0.25, unit: '' }
                    ]
                };
            case 'pitch':
                // 参数顺序 = 参数下标，两端（C++ / JS）必须一致（规格 §1）。
                return {
                    kind,
                    title: '移调 Pitch',
                    model: -1,
                    parameters: [
                        { id: 'semitone', name: '移调', min: -12, max: 12, initial: 0, unit: '半音' },
                        { id: 'mix', name: '干湿比', min: 0, max: 1, initial: 1, unit: '' },
                        { id: 'level', name: '输出', min: 0, max: 1, initial: 1, unit: '' }
                    ]
                };
            default:
                return null;
        }
    }

    /** 所有内置效果器类型。 */
    const BUILTIN_KINDS = [
        'fuzz', 'overdrive', 'wah', 'compressor', 'reverb', 'delay',
        'amp_clean', 'amp_chime', 'amp_crunch', 'amp_modern',
        'pitch'
    ];

    // ---------------------------------------------------------------------------
    // 6. BuiltinEffect：1:1 移植 JUCE 内置效果器
    // ---------------------------------------------------------------------------

    class BuiltinEffect {
        /**
         * @param {string} kind 内置效果器类型
         * @param {number} [rate] 初始采样率（随后可用 prepareToPlay 重新指定）
         */
        constructor (kind, rate) {
            const definition = createEffectDefinition(kind);
            if (!definition)
                throw new Error('未知内置效果器。');
            this.kind = kind;
            this.title = definition.title;
            this.model = definition.model;
            this.parameters = definition.parameters.map(p => ({
                id: p.id, name: p.name, min: p.min, max: p.max, unit: p.unit, value: p.initial
            }));

            // 每个实例独立的状态（原生测试会校验两个实例输出完全一致）。
            this.smooth = [];
            for (let i = 0; i < 8; ++i)
                this.smooth.push(new SmoothedValue());
            // 逐采样的参数平滑值（等价原生 std::array<float,8> values）。
            this.values = new Float64Array(8);
            this.toneState = new Float64Array(2);
            this.dcInput = new Float64Array(2);
            this.dcOutput = new Float64Array(2);
            this.wahState = [new Float64Array(2), new Float64Array(2)];
            this.ampState = [new Float64Array(5), new Float64Array(5)];
            this.wahPhase = 0;
            this.envelope = 0;
            this.position = 0;
            this.rate = 48000;
            this.delayLength = 0;
            this.delayBuffer = [new Float32Array(0), new Float32Array(0)];
            this.reverb = null;
            this.pitch = null;

            this.prepareToPlay(rate || 48000, 512);
        }

        /** 参数元数据（UI 需要的 {name,min,max,value,unit}）。 */
        describeParameters () {
            return this.parameters.map(p => ({
                name: p.name, min: p.min, max: p.max, value: p.value, unit: p.unit
            }));
        }

        /**
         * 与原生 setParameterValue 同语义：越界下标 / 非有限数值抛错，数值本身夹到量程内。
         * JS 扩展：value 为 null / undefined 时表示「不改这个参数」，直接返回（便于 UI 与测试
         * 复用同一个参数数组，null 占位表示保持原值）；NaN / ±Infinity 仍然抛错。
         */
        setParameterValue (index, value) {
            if (!Number.isInteger(index) || index < 0 || index >= this.parameters.length)
                throw new Error('无效效果器参数。');
            if (value === null || value === undefined)
                return;
            if (!Number.isFinite(value))
                throw new Error('无效效果器参数。');
            const parameter = this.parameters[index];
            parameter.value = jlimit(parameter.min, parameter.max, value);
        }

        prepareToPlay (rate, blockSize) {
            this.rate = rate;
            for (let i = 0; i < this.parameters.length; ++i) {
                this.smooth[i].reset(rate, 0.02);
                this.smooth[i].setCurrentAndTargetValue(this.parameters[i].value);
            }
            this.wahPhase = 0;
            this.toneState.fill(0);
            for (const state of this.wahState)
                state.fill(0);
            for (const state of this.ampState)
                state.fill(0);
            this.dcInput.fill(0);
            this.dcOutput.fill(0);
            this.envelope = 0;
            const length = Math.ceil(rate * 1.6) + 2;
            this.delayLength = length;
            this.delayBuffer = [new Float32Array(length), new Float32Array(length)];
            this.position = 0;
            if (this.kind === 'reverb') {
                this.reverb = new FreeverbReverb(rate);
                this.updateReverb(this.parameters[0].value, this.parameters[1].value, this.parameters[2].value);
            }
            if (this.kind === 'pitch') {
                // 移调状态（环形缓冲 / 读头 / 淡变 / 低通）按规格 §2 全部复位。
                this.pitch = new PitchShifter(rate);
            }
        }

        updateReverb (room, damping, mix) {
            if (!this.reverb)
                return;
            this.reverb.setRoom(room);
            this.reverb.setDamping(damping);
            this.reverb.setMix(mix);
        }

        /** 就地处理一段立体声缓冲（与原生 processBlock 同语义）。 */
        processBlock (left, right, samples) {
            for (let i = 0; i < this.parameters.length; ++i)
                this.smooth[i].setTargetValue(this.parameters[i].value);

            if (this.kind === 'reverb') {
                // 原生 reverb 分支在块首用 skip() 推进平滑器后再取当前值。
                this.updateReverb(
                    this.smooth[0].skip(samples),
                    this.smooth[1].skip(samples),
                    this.smooth[2].skip(samples));
                this.reverb.processStereo(left, right, samples);
                return;
            }

            const rate = this.rate;
            const values = this.values;

            if (this.model >= 0) {
                // ---- 箱头模型 ----
                const model = this.model;
                const coefficient = hz => 1 - Math.exp(-TWO_PI * hz / rate);
                const lowCut = coefficient(model === 3 ? 110.0 : 55.0);
                const bassSplit = coefficient(250);
                const trebleSplit = coefficient(2200);
                const cabCut = coefficient(model === 1 ? 5800.0 : model === 3 ? 3800.0 : 4600.0);
                const dcCoefficient = Math.exp(-TWO_PI * 20 / rate);
                for (let sample = 0; sample < samples; ++sample) {
                    this.fillValues(values);
                    // 原生在逐采样循环里用当拍的平滑值算 EQ 增益，这里保持一致。
                    const bass = decibelsToGain(values[1]);
                    const mid = decibelsToGain(values[2] + (model === 2 ? 2.0 : model === 3 ? -3.0 : 0.0));
                    const treble = decibelsToGain(values[3] + (model === 1 ? 2.0 : 0.0));
                    for (let channel = 0; channel < 2; ++channel) {
                        const state = this.ampState[channel];
                        const input = jlimit(-8.0, 8.0, channel === 0 ? left[sample] : right[sample]);
                        state[0] += lowCut * (input - state[0]);
                        let x = (input - state[0]) * (1 + values[0] * (model === 0 ? 0.3 : model === 1 ? 0.8 : model === 2 ? 1.8 : 3.5));
                        const bias = model === 1 ? 0.18 : model === 2 ? 0.1 : 0.0;
                        x = Math.tanh(x + bias) - Math.tanh(bias);
                        if (model >= 2)
                            x = Math.tanh(x * (model === 3 ? 3.0 : 1.5));
                        state[1] += bassSplit * (x - state[1]);
                        state[2] += trebleSplit * (x - state[2]);
                        x = state[1] * bass + (state[2] - state[1]) * mid + (x - state[2]) * treble;
                        x = Math.tanh(x * 1.2) * 0.8;
                        state[3] += cabCut * (x - state[3]);
                        state[4] += cabCut * (state[3] - state[4]);
                        x += values[5] * (state[4] - x);
                        const filtered = x - this.dcInput[channel] + dcCoefficient * this.dcOutput[channel];
                        this.dcInput[channel] = x;
                        this.dcOutput[channel] = filtered;
                        const output = filtered * values[4];
                        if (channel === 0)
                            left[sample] = output;
                        else
                            right[sample] = output;
                    }
                }
                return;
            }

            if (this.kind === 'wah') {
                // ---- 哇音（TPT 状态变量带通）----
                for (let sample = 0; sample < samples; ++sample) {
                    this.fillValues(values);
                    const sweep = jlimit(0.0, 1.0, values[0] + 0.5 * values[6] * Math.sin(this.wahPhase));
                    const positionValue = values[0] + values[4] * (sweep - values[0]);
                    this.wahPhase += TWO_PI * values[5] / rate;
                    if (this.wahPhase >= TWO_PI)
                        this.wahPhase -= TWO_PI;
                    const frequency = 350.0 * Math.pow(2200.0 / 350.0, positionValue);
                    const g = Math.tan(Math.PI * frequency / rate);
                    const k = 1.0 / values[1];
                    const a1 = 1.0 / (1.0 + g * (g + k));
                    for (let channel = 0; channel < 2; ++channel) {
                        const state = this.wahState[channel];
                        const input = channel === 0 ? left[sample] : right[sample];
                        const v3 = input - state[1];
                        const band = a1 * (state[0] + g * v3);
                        const low = state[1] + g * band;
                        state[0] = 2 * band - state[0];
                        state[1] = 2 * low - state[1];
                        const output = (input * (1 - values[2]) + k * band * values[2]) * values[3];
                        if (channel === 0)
                            left[sample] = output;
                        else
                            right[sample] = output;
                    }
                }
                return;
            }

            if (this.kind === 'compressor') {
                // ---- 压缩器 ----
                for (let sample = 0; sample < samples; ++sample) {
                    this.fillValues(values);
                    const leftSample = left[sample];
                    const rightSample = right[sample];
                    const peak = jmax(Math.abs(leftSample), Math.abs(rightSample));
                    const coefficient = Math.exp(-1.0 / (rate * 0.001 * (peak > this.envelope ? values[2] : values[3])));
                    this.envelope = coefficient * this.envelope + (1 - coefficient) * peak;
                    const above = jmax(0.0, gainToDecibels(this.envelope, -120.0) - values[0]);
                    const gain = decibelsToGain(values[4] - above * (1 - 1 / values[1]));
                    left[sample] = leftSample * gain;
                    right[sample] = rightSample * gain;
                }
                return;
            }

            if (this.kind === 'delay') {
                // ---- 延迟 ----
                const length = this.delayLength;
                for (let sample = 0; sample < samples; ++sample) {
                    this.fillValues(values);
                    const delaySamples = values[0] * rate * 0.001;
                    let read = this.position - delaySamples;
                    read -= Math.floor(read / length) * length;
                    if (read >= length)
                        read = 0;
                    const first = Math.trunc(read);
                    const second = (first + 1) % length;
                    const fraction = read - first;
                    for (let channel = 0; channel < 2; ++channel) {
                        const buffer = this.delayBuffer[channel];
                        const input = channel === 0 ? left[sample] : right[sample];
                        const echo = buffer[first] * (1 - fraction) + buffer[second] * fraction;
                        // 反馈回路同样限幅（含上游插件送来的超范围信号）。
                        buffer[this.position] = jlimit(-4.0, 4.0, input + echo * values[1]);
                        const output = input * (1 - values[2]) + echo * values[2];
                        if (channel === 0)
                            left[sample] = output;
                        else
                            right[sample] = output;
                    }
                    this.position = (this.position + 1) % length;
                }
                return;
            }

            if (this.kind === 'pitch') {
                // ---- 移调（双读头环形缓冲 + 交叉淡化，规格 §4）----
                const pitch = this.pitch;
                const length = pitch.length;
                for (let sample = 0; sample < samples; ++sample) {
                    this.fillValues(values);
                    // 步骤 A：参数换算。
                    const semitone = values[0];
                    const mix = values[1];
                    const level = values[2];
                    const ratio = Math.pow(2.0, semitone / 12.0);
                    // 0 半音 → 直通；非 0 半音 → 湿声。
                    const target = Math.abs(semitone) < 0.01 ? 1.0 : 0.0;
                    pitch.blend += (target - pitch.blend) * pitch.blendStep;
                    const wetGain = mix * (1.0 - pitch.blend);

                    // 步骤 B：写入与切换（共享状态每采样只更新一次，两声道共用）。
                    for (let channel = 0; channel < 2; ++channel) {
                        pitch.buffer[channel][Math.trunc(pitch.time)] =
                            channel === 0 ? left[sample] : right[sample];
                    }
                    pitch.time = pitch.mod(pitch.time + 1.0, length);
                    const now = pitch.mod(pitch.time - 1.0, length);
                    // 读头落后量（规格里的 delay）：取值范围 (0, M)。
                    const lag = pitch.mod(now - pitch.head[pitch.active], length);
                    if (lag < pitch.minDelay) {
                        // 读头追得太近：换到落后 D 个采样的新读头。
                        const next = 1 - pitch.active;
                        pitch.head[next] = pitch.mod(now - (lag + pitch.delay), length);
                        pitch.fade = 0;
                        pitch.active = next;
                    } else if (lag > pitch.maxDelay) {
                        // 读头落得太远：换到靠近 D 个采样的新读头。
                        const next = 1 - pitch.active;
                        pitch.head[next] = pitch.mod(now - (lag - pitch.delay), length);
                        pitch.fade = 0;
                        pitch.active = next;
                    }

                    // 步骤 C：读取与混合（每声道独立低通状态）。
                    for (let channel = 0; channel < 2; ++channel) {
                        const input = channel === 0 ? left[sample] : right[sample];
                        let wet = pitch.read(channel, pitch.head[pitch.active]);
                        if (pitch.fade >= 0) {
                            const old = pitch.read(channel, pitch.head[1 - pitch.active]);
                            const t = pitch.fade / (PITCH_FADE_LENGTH - 1);
                            wet = old * (1.0 - t) + wet * t;
                        }
                        const filterState = pitch.filter[channel];
                        filterState[0] += pitch.filterAlpha * (wet - filterState[0]);
                        filterState[1] += pitch.filterAlpha * (filterState[0] - filterState[1]);
                        wet = filterState[1];
                        const output = (input * (1.0 - wetGain) + wet * wetGain) * level;
                        if (channel === 0)
                            left[sample] = output;
                        else
                            right[sample] = output;
                    }

                    // 步骤 D：推进（淡变计数 + 两个读头同步前进）。
                    if (pitch.fade >= 0) {
                        pitch.fade += 1;
                        if (pitch.fade >= PITCH_FADE_LENGTH)
                            pitch.fade = -1;
                    }
                    pitch.head[0] = pitch.mod(pitch.head[0] + ratio, length);
                    pitch.head[1] = pitch.mod(pitch.head[1] + ratio, length);
                }
                return;
            }

            // ---- fuzz / overdrive ----
            for (let sample = 0; sample < samples; ++sample) {
                this.fillValues(values);
                const alpha = 1 - Math.exp(-TWO_PI * values[1] / rate);
                for (let channel = 0; channel < 2; ++channel) {
                    const input = (channel === 0 ? left[sample] : right[sample]) * values[0];
                    // fuzz 是硬削波，overdrive 是较软的饱和曲线。
                    const shaped = this.kind === 'fuzz' ? jlimit(-1.0, 1.0, input) : Math.tanh(input);
                    this.toneState[channel] += alpha * (shaped - this.toneState[channel]);
                    const filtered = this.toneState[channel] - this.dcInput[channel] + 0.995 * this.dcOutput[channel];
                    this.dcInput[channel] = this.toneState[channel];
                    this.dcOutput[channel] = filtered;
                    const output = filtered * values[2];
                    if (channel === 0)
                        left[sample] = output;
                    else
                        right[sample] = output;
                }
            }
        }

        /** 取当前块的参数平滑值（与原生 std::array<float,8> values 等价）。 */
        fillValues (values) {
            for (let i = 0; i < this.parameters.length; ++i)
                values[i] = this.smooth[i].getNextValue();
        }
    }

    // ---------------------------------------------------------------------------
    // 7. 效果链（最多 8 块串联，顺序处理，与原生宿主一致）
    // ---------------------------------------------------------------------------

    class EffectChain {
        constructor (rate) {
            this.rate = rate || GLOBAL_SAMPLE_RATE;
            this.blocks = [];
            this.gain = 1;
        }

        add (index, kind, parameters) {
            if (this.blocks.length >= MAX_EFFECTS)
                throw new Error('最多添加 8 个效果器。');
            const effect = new BuiltinEffect(kind, this.rate);
            if (Array.isArray(parameters)) {
                for (let i = 0; i < effect.parameters.length && i < parameters.length; ++i) {
                    const value = parameters[i];
                    if (!Number.isFinite(value))
                        throw new Error('无效效果器参数。');
                    effect.setParameterValue(i, value);
                }
            }
            this.blocks.splice(index, 0, { kind, effect, bypass: false });
            return effect;
        }

        remove (index) {
            if (!Number.isInteger(index) || index < 0 || index >= this.blocks.length)
                throw new Error('效果器已不存在。');
            this.blocks.splice(index, 1);
        }

        move (index, destination) {
            if (!Number.isInteger(index) || index < 0 || index >= this.blocks.length)
                throw new Error('效果器已不存在。');
            if (!Number.isInteger(destination) || destination < 0 || destination >= this.blocks.length)
                throw new Error('无效排序位置。');
            const [block] = this.blocks.splice(index, 1);
            this.blocks.splice(destination, 0, block);
        }

        setBypass (index, value) {
            if (!Number.isInteger(index) || index < 0 || index >= this.blocks.length)
                throw new Error('效果器已不存在。');
            this.blocks[index].bypass = !!value;
        }

        setParameter (index, parameter, value) {
            if (!Number.isInteger(index) || index < 0 || index >= this.blocks.length)
                throw new Error('效果器已不存在。');
            this.blocks[index].effect.setParameterValue(parameter, value);
        }

        setGain (value) {
            if (!Number.isFinite(value))
                throw new Error('无效输出音量。');
            this.gain = jlimit(0.0, 1.0, value);
        }

        /** 清空整条链并复位状态。 */
        reset () {
            this.blocks.length = 0;
        }

        /** 就地处理：按链顺序串联，旁通的块直通。 */
        process (left, right, samples) {
            for (const block of this.blocks) {
                if (block.bypass)
                    continue;
                block.effect.processBlock(left, right, samples);
            }
        }
    }

    // ---------------------------------------------------------------------------
    // 8. AudioWorkletProcessor
    // ---------------------------------------------------------------------------

    class GuitarbookEffectsProcessor extends BaseProcessor {
        constructor (options) {
            super(options);
            this.chain = new EffectChain(GLOBAL_SAMPLE_RATE);
            this.inputPeak = 0;
            this.outputPeak = 0;
            this.lastMeterTime = -1;
            this.frameCounter = 0;
            this.leftBuffer = new Float32Array(0);
            this.rightBuffer = new Float32Array(0);
            // 端口注入输入通道：inputMode 默认 'node'，保持原有音频节点输入行为。
            this.inputMode = 'node';
            this.portFifo = new Float32Array(0);
            this.portFifoLength = 0;
            this.port.onmessage = event => this.handleMessage(event.data);
        }

        reportError (message) {
            this.port.postMessage({ type: 'error', message: String(message) });
        }

        handleMessage (message) {
            if (!message || typeof message !== 'object') {
                this.reportError('无效的消息。');
                return;
            }
            try {
                switch (message.type) {
                    case 'add': {
                        const index = message.index;
                        if (!Number.isInteger(index) || index < 0 || index > this.chain.blocks.length)
                            throw new Error('无效效果器位置。');
                        if (typeof message.kind !== 'string' || !createEffectDefinition(message.kind))
                            throw new Error('未知内置效果器。');
                        this.chain.add(index, message.kind, message.parameters);
                        break;
                    }
                    case 'remove':
                        this.chain.remove(message.index);
                        break;
                    case 'move':
                        this.chain.move(message.index, message.destination);
                        break;
                    case 'bypass':
                        this.chain.setBypass(message.index, message.value);
                        break;
                    case 'parameter':
                        this.chain.setParameter(message.index, message.parameter, message.value);
                        break;
                    case 'gain':
                        this.chain.setGain(message.value);
                        break;
                    case 'reset':
                        this.chain.reset();
                        this.inputPeak = 0;
                        this.outputPeak = 0;
                        // 复位也清空端口输入 FIFO；inputMode 属于通道配置，不随 reset 改变。
                        this.portFifoLength = 0;
                        break;
                    case 'input': {
                        const buffer = message.buffer;
                        const frames = message.frames;
                        if (!(buffer instanceof ArrayBuffer))
                            throw new Error('input 消息缺少 ArrayBuffer。');
                        if (!Number.isInteger(frames) || frames < 0)
                            throw new Error('无效的采集帧数。');
                        if (frames * Float32Array.BYTES_PER_ELEMENT > buffer.byteLength)
                            throw new Error('采集帧数据不足。');
                        this.appendPortFrames(new Float32Array(buffer, 0, frames));
                        break;
                    }
                    case 'inputMode': {
                        const mode = message.mode;
                        if (mode !== 'port' && mode !== 'node')
                            throw new Error('无效的输入模式。');
                        this.inputMode = mode;
                        break;
                    }
                    default:
                        this.reportError('未知指令：' + String(message.type));
                        break;
                }
            } catch (error) {
                this.reportError(error && error.message ? error.message : String(error));
            }
        }

        /** 把主线程注入的单声道采集帧追加到端口输入 FIFO。 */
        appendPortFrames (samples) {
            const pending = this.portFifoLength;
            const needed = pending + samples.length;
            if (needed > this.portFifo.length) {
                let capacity = Math.max(128, this.portFifo.length);
                while (capacity < needed)
                    capacity *= 2;
                const grown = new Float32Array(capacity);
                grown.set(this.portFifo.subarray(0, pending));
                this.portFifo = grown;
            }
            this.portFifo.set(samples, pending);
            this.portFifoLength = needed;
        }

        /**
         * 从端口输入 FIFO 取 frames 个样本填到 target；不足时补零（欠载），
         * 并把剩余样本前移保留给下一个量子。
         */
        readPortFrames (target, frames) {
            const available = Math.min(frames, this.portFifoLength);
            if (available > 0)
                target.set(this.portFifo.subarray(0, available));
            if (available < frames)
                target.fill(0, available);
            if (available > 0) {
                this.portFifo.copyWithin(0, available, this.portFifoLength);
                this.portFifoLength -= available;
            }
        }

        process (inputs, outputs) {
            const output = outputs && outputs.length ? outputs[0] : null;
            if (!output || output.length === 0)
                return true;
            const frames = output[0].length;
            if (this.leftBuffer.length < frames) {
                this.leftBuffer = new Float32Array(frames);
                this.rightBuffer = new Float32Array(frames);
            }
            const left = this.leftBuffer;
            const right = this.rightBuffer;
            const input = inputs && inputs.length ? inputs[0] : null;

            if (this.inputMode === 'port') {
                // 端口注入模式：优先消费主线程采集帧，欠载补零；忽略音频节点输入。
                this.readPortFrames(left, frames);
                right.set(left.subarray(0, frames));
            } else if (input && input.length >= 2) {
                left.set(input[0].subarray(0, frames));
                right.set(input[1].subarray(0, frames));
            } else if (input && input.length >= 1) {
                // 单声道输入上混为双声道（同一路干声进左右），与原生一致。
                left.set(input[0].subarray(0, frames));
                right.set(input[0].subarray(0, frames));
            } else {
                left.fill(0);
                right.fill(0);
            }

            let inputPeak = 0;
            for (let i = 0; i < frames; ++i) {
                const magnitude = Math.abs(left[i]);
                if (magnitude > inputPeak)
                    inputPeak = magnitude;
            }

            this.chain.process(left, right, frames);

            const gain = this.chain.gain;
            const outputLeft = output[0];
            const outputRight = output.length > 1 ? output[1] : null;
            let outputPeak = 0;
            for (let i = 0; i < frames; ++i) {
                const valueLeft = left[i] * gain;
                const valueRight = right[i] * gain;
                outputLeft[i] = valueLeft;
                const magnitudeLeft = Math.abs(valueLeft);
                if (magnitudeLeft > outputPeak)
                    outputPeak = magnitudeLeft;
                if (outputRight) {
                    outputRight[i] = valueRight;
                    const magnitudeRight = Math.abs(valueRight);
                    if (magnitudeRight > outputPeak)
                        outputPeak = magnitudeRight;
                }
            }

            if (inputPeak > this.inputPeak)
                this.inputPeak = inputPeak;
            if (outputPeak > this.outputPeak)
                this.outputPeak = outputPeak;

            this.frameCounter += frames;
            this.reportMeter();
            return true;
        }

        /** 每 ~100 ms 最多上报一次输入/输出峰值。 */
        reportMeter () {
            // currentTime 只在 AudioWorkletGlobalScope 里是音频时钟；其他地方用采样计数兜底。
            const now = (typeof AudioWorkletProcessor !== 'undefined'
                && typeof currentTime === 'number' && isFinite(currentTime))
                ? currentTime
                : this.frameCounter / this.chain.rate;
            if (this.lastMeterTime < 0) {
                this.lastMeterTime = now;
                return;
            }
            if (now - this.lastMeterTime < 0.1)
                return;
            this.lastMeterTime = now;
            this.port.postMessage({ type: 'meter', input: this.inputPeak, output: this.outputPeak });
            this.inputPeak = 0;
            this.outputPeak = 0;
        }
    }

    // ---------------------------------------------------------------------------
    // 9. 导出：浏览器注册 processor，Node 暴露模块供离线回归
    // ---------------------------------------------------------------------------

    /**
     * 导出的 API：Node 走 module.exports，浏览器页面走 globalThis.GuitarbookEffects，
     * 两者指向同一个对象（页面里可直接用 GuitarbookEffects.BuiltinEffect 复跑数值断言）。
     */
    const GuitarbookEffects = {
        BuiltinEffect,
        EffectChain,
        GuitarbookEffectsProcessor,
        SmoothedValue,
        FreeverbReverb,
        CombFilter,
        AllPassFilter,
        BUILTIN_KINDS,
        MAX_EFFECTS,
        PROCESSOR_NAME,
        createEffectDefinition,
        decibelsToGain,
        gainToDecibels,
        jlimit,
        jmax
    };

    if (typeof module !== 'undefined' && module.exports && typeof module.exports === 'object')
        module.exports = GuitarbookEffects;

    if (typeof globalThis !== 'undefined')
        globalThis.GuitarbookEffects = GuitarbookEffects;

    if (WORKLET_SCOPE)
        registerProcessor(PROCESSOR_NAME, GuitarbookEffectsProcessor);
})();
