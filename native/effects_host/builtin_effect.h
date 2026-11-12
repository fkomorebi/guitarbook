#pragma once
#include <juce_audio_processors_headless/juce_audio_processors_headless.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

// Original, deliberately small DSP effects; no external plugin assets required.
class BuiltinEffect final : public juce::AudioProcessor {
public:
    explicit BuiltinEffect(const juce::String& type)
        : AudioProcessor(BusesProperties().withInput("Input", juce::AudioChannelSet::stereo(), true)
                         .withOutput("Output", juce::AudioChannelSet::stereo(), true)), kind(type) {
        setPlayConfigDetails(2, 2, 48000, 512);
        if (kind == "fuzz" || kind == "overdrive") {
            title = kind == "fuzz" ? juce::String::fromUTF8("Fuzz 法兹") : juce::String::fromUTF8("过载 Overdrive");
            add("drive", "驱动", 1, kind == "fuzz" ? 30 : 20, kind == "fuzz" ? 12 : 4, "");
            add("tone", "音色", 200, 8000, kind == "fuzz" ? 2500 : 4000, "Hz");
            add("level", "输出", 0, 1, kind == "fuzz" ? 0.4f : 0.6f, "");
        } else if (kind.startsWith("amp_")) {
            if (kind == "amp_clean") { title = juce::String::fromUTF8("美式清音箱头"); model = 0; }
            else if (kind == "amp_chime") { title = juce::String::fromUTF8("英式清脆箱头"); model = 1; }
            else if (kind == "amp_crunch") { title = juce::String::fromUTF8("英式摇滚箱头"); model = 2; }
            else if (kind == "amp_modern") { title = juce::String::fromUTF8("现代高增益箱头"); model = 3; }
            else throw juce::String::fromUTF8("未知箱头类型。");
            add("gain", "增益", 0, 10, model == 0 ? 2 : model == 1 ? 4 : model == 2 ? 5 : 6, "");
            add("bass", "低频", -12, 12, 0, "dB");
            add("mid", "中频", -12, 12, 0, "dB");
            add("treble", "高频", -12, 12, 0, "dB");
            add("master", "主音量", 0, 1, 0.5f, "");
            add("cab", "箱体", 0, 1, 1, "");
        } else if (kind == "wah") {
            title = juce::String::fromUTF8("哇音 Wah");
            add("position", "位置", 0, 1, 0.5f, "");
            add("resonance", "共振", 0.5f, 8, 2, "Q");
            add("mix", "干湿比", 0, 1, 1, "");
            add("level", "输出", 0, 1, 0.7f, "");
            add("auto", "自动", 0, 1, 0, "");
            add("speed", "速度", 0.1f, 5, 1, "Hz");
            add("depth", "深度", 0, 1, 0.8f, "");
        } else if (kind == "compressor") {
            title = juce::String::fromUTF8("压缩 Compressor");
            add("threshold", "阈值", -60, 0, -24, "dB");
            add("ratio", "压缩比", 1, 12, 4, ":1");
            add("attack", "启动", 1, 100, 10, "ms");
            add("release", "释放", 20, 1000, 300, "ms");
            add("makeup", "补偿", 0, 18, 3, "dB");
        } else if (kind == "reverb") {
            title = juce::String::fromUTF8("混响 Reverb");
            add("room", "空间", 0, 1, 0.5f, "");
            add("damping", "阻尼", 0, 1, 0.5f, "");
            add("mix", "干湿比", 0, 1, 0.25f, "");
        } else if (kind == "delay") {
            title = juce::String::fromUTF8("延迟 Delay");
            add("time", "时间", 20, 1500, 350, "ms");
            add("feedback", "反馈", 0, 0.9f, 0.35f, "");
            add("mix", "干湿比", 0, 1, 0.25f, "");
        } else if (kind == "pitch") {
            title = juce::String::fromUTF8("移调 Pitch");
            add("semitone", "移调", -12, 12, 0, "半音");
            add("mix", "干湿比", 0, 1, 1, "");
            add("level", "输出", 0, 1, 1, "");
        } else if (kind == "marimba") {
            // 箱琴：参数顺序 = 参数下标，两端（C++ / JS）必须一致（规格 docs/marimba_effect_spec.md §2）。
            title = juce::String::fromUTF8("箱琴 Marimba");
            add("transpose", "移调", -12, 12, 0, "半音");
            add("decay", "衰减", 0.2f, 4, 1.2f, "s");
            add("tone", "音色", 0, 1, 0.6f, "");
            add("sensitivity", "触发", 0, 1, 0.5f, "");
            add("mix", "干湿比", 0, 1, 1, "");
            add("level", "输出", 0, 1, 0.8f, "");
        } else throw juce::String::fromUTF8("未知内置效果器。");
    }

    const juce::String getName() const override { return title; }
    // 供测试与自动化使用：按 add() 顺序返回已注册到 AudioProcessor 的浮点参数。
    // 基类 getParameters() 只返回 juce::AudioProcessorParameter*，读不到量程与默认值。
    const std::vector<juce::AudioParameterFloat*>& getFloatParameters() const { return parameters; }
    void prepareToPlay(double sampleRate, int) override {
        rate = sampleRate;
        for (size_t i = 0; i < parameters.size(); ++i) {
            smooth[i].reset(rate, 0.02);
            smooth[i].setCurrentAndTargetValue(parameters[i]->get());
        }
        wahPhase = 0;
        toneState.fill(0);
        for (auto& state : wahState) state.fill(0);
        for (auto& state : ampState) state.fill(0);
        dcInput.fill(0);
        dcOutput.fill(0);
        envelope = 0;
        delayBuffer.setSize(2, static_cast<int>(std::ceil(rate * 1.6)) + 2);
        delayBuffer.clear();
        position = 0;
        if (kind == "reverb") updateReverb(parameters[0]->get(), parameters[1]->get(), parameters[2]->get());
        reverb.setSampleRate(rate);
        reverb.reset();
        if (kind == "pitch") {
            // 移调状态复位：基准延迟 D = ceil(rate * 0.03)，环形缓冲长度 M = 2 * D。
            pitchDelay = static_cast<int>(std::ceil(rate * 0.03));
            pitchLength = pitchDelay * 2;
            pitchBuffer.setSize(2, pitchLength);
            pitchBuffer.clear();
            pitchTime = 0;
            pitchHead[0] = 0;
            pitchHead[1] = 0;
            pitchActive = 0;
            pitchFade = -1;
            pitchBlend = 1.0;
            pitchFilter[0][0] = pitchFilter[0][1] = 0.0;
            pitchFilter[1][0] = pitchFilter[1][1] = 0.0;
        }
        if (kind == "marimba") {
            // 箱琴状态复位：分析常量、捕获缓冲、抽取滤波器、包络、起音计数、声部与噪声种子。
            marimbaAnalysisRate = rate / marimbaDecimation;
            marimbaMaxLag = std::max(3, static_cast<int>(std::floor(marimbaAnalysisRate / marimbaMinFrequency)));
            marimbaLagMin = std::max(2, static_cast<int>(std::floor(marimbaAnalysisRate / marimbaMaxFrequency)));
            marimbaCaptureLength = 4 * marimbaMaxLag;
            marimbaCapture.assign(static_cast<size_t>(marimbaCaptureLength), 0.0);
            marimbaDifference.assign(static_cast<size_t>(marimbaMaxLag) + 1, 0.0);
            marimbaDecimator.fill(0.0);
            marimbaDecimPhase = 0;
            marimbaCaptureCount = 0;
            marimbaCapturing = false;
            marimbaArmed = true;
            marimbaCapturePeak = 0.0;
            marimbaFastEnv = 0.0;
            marimbaShortEnergy = 0.0;
            marimbaLongEnergy = 0.0;
            marimbaRefractorySamples = static_cast<int>(rate * 0.015);
            // 初值取不应期长度：首次起音立即可触发（不应期只抑制连续重复触发）。
            marimbaSamplesSinceOnset = marimbaRefractorySamples;
            marimbaDecimatorAlpha = 1.0 - std::exp(-2.0 * juce::MathConstants<double>::pi * 0.09);
            marimbaFastRelease = std::exp(-1.0 / (rate * 0.010));
            marimbaShortAlpha = 1.0 - std::exp(-1.0 / (rate * 0.006));
            marimbaLongAlpha = 1.0 - std::exp(-1.0 / (rate * 0.060));
            marimbaClickAlpha = 1.0 - std::exp(-2.0 * juce::MathConstants<double>::pi * 0.20);
            marimbaClickDecay = std::exp(-1.0 / (rate * 0.008));
            marimbaDecayTauBase = 1.0 / std::log(1000.0);
            marimbaDecayCoef.fill(0.0);
            marimbaLastDecay = -1.0;
            marimbaNoiseSeed = 22222u;
            marimbaNextVoiceAge = 0;
            for (auto& voice : marimbaVoices) {
                voice.active = false;
                voice.age = 0;
                voice.clickAmp = 0.0;
                voice.clickLp = 0.0;
                voice.phase.fill(0.0);
                voice.step.fill(0.0);
                voice.amp.fill(0.0);
            }
            updateMarimbaDecay(1.2);
        }
    }
    void releaseResources() override {}
    bool isBusesLayoutSupported(const BusesLayout& layout) const override {
        return layout.getMainInputChannelSet() == juce::AudioChannelSet::stereo()
            && layout.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
    }
    void processBlock(juce::AudioBuffer<float>& audio, juce::MidiBuffer&) override {
        juce::ScopedNoDenormals noDenormals;
        for (size_t i = 0; i < parameters.size(); ++i) smooth[i].setTargetValue(parameters[i]->get());
        const int samples = audio.getNumSamples();
        if (kind == "reverb") {
            updateReverb(smooth[0].skip(samples), smooth[1].skip(samples), smooth[2].skip(samples));
            reverb.processStereo(audio.getWritePointer(0), audio.getWritePointer(1), samples);
            return;
        }
        if (kind == "pitch") {
            processPitch(audio, samples);
            return;
        }
        for (int sample = 0; sample < samples; ++sample) {
            std::array<float, 8> values{};
            for (size_t i = 0; i < parameters.size(); ++i) values[i] = smooth[i].getNextValue();
            if (model >= 0) {
                const auto coefficient = [this](float hz) {
                    return 1 - std::exp(-juce::MathConstants<float>::twoPi * hz / static_cast<float>(rate));
                };
                const float lowCut = coefficient(model == 3 ? 110.0f : 55.0f);
                const float bassSplit = coefficient(250);
                const float trebleSplit = coefficient(2200);
                const float cabCut = coefficient(model == 1 ? 5800.0f : model == 3 ? 3800.0f : 4600.0f);
                const float bass = juce::Decibels::decibelsToGain(values[1]);
                const float mid = juce::Decibels::decibelsToGain(values[2] + (model == 2 ? 2.0f : model == 3 ? -3.0f : 0.0f));
                const float treble = juce::Decibels::decibelsToGain(values[3] + (model == 1 ? 2.0f : 0.0f));
                for (int ch = 0; ch < 2; ++ch) {
                    auto& state = ampState[static_cast<size_t>(ch)];
                    const float input = juce::jlimit(-8.0f, 8.0f, audio.getSample(ch, sample));
                    state[0] += lowCut * (input - state[0]);
                    float x = (input - state[0]) * (1 + values[0] * (model == 0 ? 0.3f : model == 1 ? 0.8f : model == 2 ? 1.8f : 3.5f));
                    const float bias = model == 1 ? 0.18f : model == 2 ? 0.1f : 0.0f;
                    x = std::tanh(x + bias) - std::tanh(bias);
                    if (model >= 2) x = std::tanh(x * (model == 3 ? 3.0f : 1.5f));
                    state[1] += bassSplit * (x - state[1]);
                    state[2] += trebleSplit * (x - state[2]);
                    x = state[1] * bass + (state[2] - state[1]) * mid + (x - state[2]) * treble;
                    x = std::tanh(x * 1.2f) * 0.8f;
                    state[3] += cabCut * (x - state[3]);
                    state[4] += cabCut * (state[3] - state[4]);
                    x += values[5] * (state[4] - x);
                    const float filtered = x - dcInput[static_cast<size_t>(ch)] +
                        std::exp(-juce::MathConstants<float>::twoPi * 20 / static_cast<float>(rate)) * dcOutput[static_cast<size_t>(ch)];
                    dcInput[static_cast<size_t>(ch)] = x;
                    dcOutput[static_cast<size_t>(ch)] = filtered;
                    audio.setSample(ch, sample, filtered * values[4]);
                }
            } else if (kind == "wah") {
                // TPT state-variable bandpass, normalized by Q to bound resonance gain.
                const float sweep = juce::jlimit(0.0f, 1.0f, values[0] +
                    0.5f * values[6] * static_cast<float>(std::sin(wahPhase)));
                const float positionValue = values[0] + values[4] * (sweep - values[0]);
                wahPhase += juce::MathConstants<double>::twoPi * values[5] / rate;
                if (wahPhase >= juce::MathConstants<double>::twoPi) wahPhase -= juce::MathConstants<double>::twoPi;
                const float frequency = 350.0f * std::pow(2200.0f / 350.0f, positionValue);
                const float g = std::tan(juce::MathConstants<float>::pi * frequency / static_cast<float>(rate));
                const float k = 1.0f / values[1];
                const float a1 = 1.0f / (1.0f + g * (g + k));
                for (int ch = 0; ch < 2; ++ch) {
                    auto& state = wahState[static_cast<size_t>(ch)];
                    const float input = audio.getSample(ch, sample);
                    const float v3 = input - state[1];
                    const float band = a1 * (state[0] + g * v3);
                    const float low = state[1] + g * band;
                    state[0] = 2 * band - state[0];
                    state[1] = 2 * low - state[1];
                    audio.setSample(ch, sample, (input * (1 - values[2]) + k * band * values[2]) * values[3]);
                }
            } else if (kind == "compressor") {
                const float peak = juce::jmax(std::abs(audio.getSample(0, sample)), std::abs(audio.getSample(1, sample)));
                const float coefficient = std::exp(-1.0f / static_cast<float>(rate * 0.001 * (peak > envelope ? values[2] : values[3])));
                envelope = coefficient * envelope + (1 - coefficient) * peak;
                const float above = juce::jmax(0.0f, juce::Decibels::gainToDecibels(envelope, -120.0f) - values[0]);
                const float gain = juce::Decibels::decibelsToGain(values[4] - above * (1 - 1 / values[1]));
                for (int ch = 0; ch < 2; ++ch) audio.setSample(ch, sample, audio.getSample(ch, sample) * gain);
            } else if (kind == "delay") {
                const double delaySamples = static_cast<double>(values[0]) * rate * 0.001;
                const int length = delayBuffer.getNumSamples();
                double read = static_cast<double>(position) - delaySamples;
                read -= std::floor(read / length) * length;
                if (read >= length) read = 0;
                const int first = static_cast<int>(read);
                const int second = (first + 1) % length;
                const float fraction = static_cast<float>(read - first);
                for (int ch = 0; ch < 2; ++ch) {
                    const float input = audio.getSample(ch, sample);
                    const float echo = delayBuffer.getSample(ch, first) * (1 - fraction) + delayBuffer.getSample(ch, second) * fraction;
                    // Bound the feedback memory too, including over-range upstream plugins.
                    delayBuffer.setSample(ch, position, juce::jlimit(-4.0f, 4.0f, input + echo * values[1]));
                    audio.setSample(ch, sample, input * (1 - values[2]) + echo * values[2]);
                }
                position = (position + 1) % delayBuffer.getNumSamples();
            } else if (kind == "marimba") {
                // 箱琴：干湿混合 + 输出增益（湿声本身带约 53 ms 的捕获窗口延迟，干声不补偿）。
                const float inLeft = audio.getSample(0, sample);
                const float inRight = audio.getSample(1, sample);
                const double wet = processMarimbaSample(inLeft, inRight, values);
                const double mix = static_cast<double>(values[4]);
                const double level = static_cast<double>(values[5]);
                audio.setSample(0, sample, static_cast<float>((static_cast<double>(inLeft) * (1.0 - mix) + wet * mix) * level));
                audio.setSample(1, sample, static_cast<float>((static_cast<double>(inRight) * (1.0 - mix) + wet * mix) * level));
            } else {
                const float alpha = 1 - std::exp(-juce::MathConstants<float>::twoPi * values[1] / static_cast<float>(rate));
                for (int ch = 0; ch < 2; ++ch) {
                    const auto channel = static_cast<size_t>(ch);
                    const float input = audio.getSample(ch, sample) * values[0];
                    // Fuzz is hard clipping; overdrive is a softer saturating curve.
                    const float shaped = kind == "fuzz" ? juce::jlimit(-1.0f, 1.0f, input) : std::tanh(input);
                    toneState[channel] += alpha * (shaped - toneState[channel]);
                    const float filtered = toneState[channel] - dcInput[channel] + 0.995f * dcOutput[channel];
                    dcInput[channel] = toneState[channel];
                    dcOutput[channel] = filtered;
                    audio.setSample(ch, sample, filtered * values[2]);
                }
            }
        }
    }
    juce::var describeParameters() const {
        juce::Array<juce::var> result;
        for (size_t i = 0; i < parameters.size(); ++i) {
            auto* param = parameters[i];
            auto* entry = new juce::DynamicObject();
            entry->setProperty("name", param->getName(64));
            entry->setProperty("min", param->range.start);
            entry->setProperty("max", param->range.end);
            entry->setProperty("value", param->get());
            entry->setProperty("unit", param->getLabel());
            result.add(juce::var(entry));
        }
        return result;
    }
    void setParameterValue(int index, float value) {
        if (index < 0 || index >= static_cast<int>(parameters.size()) || !std::isfinite(value))
            throw juce::String::fromUTF8("无效效果器参数。");
        auto* parameter = parameters[static_cast<size_t>(index)];
        parameter->setValueNotifyingHost(parameter->convertTo0to1(juce::jlimit(parameter->range.start, parameter->range.end, value)));
    }
    juce::String kind;
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return kind == "delay" ? 30 : kind == "reverb" ? 10 : kind == "pitch" ? 0.1 : kind == "marimba" ? 6.0 : 0; }
    juce::AudioProcessorEditor* createEditor() override { return nullptr; }
    bool hasEditor() const override { return false; }
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram(int) override {}
    const juce::String getProgramName(int) override { return {}; }
    void changeProgramName(int, const juce::String&) override {}
    void getStateInformation(juce::MemoryBlock&) override {}
    void setStateInformation(const void*, int) override {}
private:
    // 移调效果器：环形缓冲 + 双读头交叉淡变，共享状态两声道共用。
    static constexpr int pitchFadeLength = 256;
    static double pitchMod(double value, double length) {
        double result = value - std::floor(value / length) * length;
        if (result < 0) result += length;
        if (result >= length) result -= length;
        return result;
    }
    double readPitch(int channel, double position) const {
        const int length = pitchLength;
        int first = static_cast<int>(std::floor(position));
        if (first < 0) first += length;
        if (first >= length) first -= length;
        const double fraction = position - std::floor(position);
        const int second = (first + 1) % length;
        return static_cast<double>(pitchBuffer.getSample(channel, first)) * (1.0 - fraction)
            + static_cast<double>(pitchBuffer.getSample(channel, second)) * fraction;
    }
    void processPitch(juce::AudioBuffer<float>& audio, int samples) {
        if (pitchLength <= 0) return;
        const double blendStep = 1.0 - std::exp(-1.0 / (rate * 0.015));
        const double filterAlpha = 1.0 - std::exp(-2.0 * juce::MathConstants<double>::pi * 0.4);
        const double minDelay = pitchDelay / 2.0;
        const double maxDelay = pitchDelay * 1.5;
        for (int sample = 0; sample < samples; ++sample) {
            const float semitone = smooth[0].getNextValue();
            const float mix = smooth[1].getNextValue();
            const float level = smooth[2].getNextValue();
            // 步骤 A：参数换算，0 半音保持直通。
            const double ratio = std::pow(2.0, static_cast<double>(semitone) / 12.0);
            const double target = std::abs(static_cast<double>(semitone)) < 0.01 ? 1.0 : 0.0;
            pitchBlend += (target - pitchBlend) * blendStep;
            const double wetGain = static_cast<double>(mix) * (1.0 - pitchBlend);
            // 步骤 B：写入环形缓冲并按阈值切换读头。
            for (int ch = 0; ch < 2; ++ch)
                pitchBuffer.setSample(ch, static_cast<int>(pitchTime), audio.getSample(ch, sample));
            pitchTime = pitchMod(pitchTime + 1.0, pitchLength);
            const double now = pitchMod(pitchTime - 1.0, pitchLength);
            const double lag = pitchMod(now - pitchHead[pitchActive], pitchLength);
            if (lag < minDelay) {
                const int next = 1 - pitchActive;
                pitchHead[next] = pitchMod(now - (lag + pitchDelay), pitchLength);
                pitchFade = 0;
                pitchActive = next;
            } else if (lag > maxDelay) {
                const int next = 1 - pitchActive;
                pitchHead[next] = pitchMod(now - (lag - pitchDelay), pitchLength);
                pitchFade = 0;
                pitchActive = next;
            }
            // 步骤 C：读取、交叉淡化、湿声低通并与干声混合。
            for (int ch = 0; ch < 2; ++ch) {
                double wet = readPitch(ch, pitchHead[pitchActive]);
                if (pitchFade >= 0) {
                    const double old = readPitch(ch, pitchHead[1 - pitchActive]);
                    const double t = static_cast<double>(pitchFade) / (pitchFadeLength - 1);
                    wet = old * (1.0 - t) + wet * t;
                }
                auto& filter = pitchFilter[static_cast<size_t>(ch)];
                filter[0] += filterAlpha * (wet - filter[0]);
                filter[1] += filterAlpha * (filter[0] - filter[1]);
                wet = filter[1];
                const double input = audio.getSample(ch, sample);
                audio.setSample(ch, sample, static_cast<float>((input * (1.0 - wetGain) + wet * wetGain) * level));
            }
            // 步骤 D：推进淡变计数与两个读头。
            if (pitchFade >= 0) {
                pitchFade += 1;
                if (pitchFade >= pitchFadeLength) pitchFade = -1;
            }
            pitchHead[0] = pitchMod(pitchHead[0] + ratio, pitchLength);
            pitchHead[1] = pitchMod(pitchHead[1] + ratio, pitchLength);
        }
    }
    void updateReverb(float room, float damping, float mix) {
        juce::Reverb::Parameters settings;
        settings.roomSize = room;
        settings.damping = damping;
        // JUCE internally scales wet by 3 and dry by 2. Keep dry at unity
        // when mix is zero, consistent with the other built-in effects.
        settings.wetLevel = mix / 3;
        settings.dryLevel = (1 - mix) / 2;
        settings.width = 1;
        settings.freezeMode = 0;
        reverb.setParameters(settings);
    }
    void add(const char* id, const char* name, float low, float high, float initial, const char* unit) {
        auto* parameter = new juce::AudioParameterFloat(juce::ParameterID{id, 1}, juce::String::fromUTF8(name),
            juce::NormalisableRange<float>(low, high), initial,
            juce::AudioParameterFloatAttributes().withLabel(juce::String::fromUTF8(unit)));
        addParameter(parameter);
        parameters.push_back(parameter);
    }
    juce::String title;
    std::vector<juce::AudioParameterFloat*> parameters;
    std::array<juce::SmoothedValue<float>, 8> smooth;
    std::array<float, 2> toneState{}, dcInput{}, dcOutput{};
    juce::AudioBuffer<float> delayBuffer;
    juce::Reverb reverb;
    double rate = 48000;
    std::array<std::array<float, 5>, 2> ampState{};
    std::array<std::array<float, 2>, 2> wahState{};
    double wahPhase = 0;
    int model = -1;
    float envelope = 0;
    int position = 0;
    // 移调效果器状态
    juce::AudioBuffer<float> pitchBuffer;
    int pitchDelay = 0;
    int pitchLength = 0;
    double pitchTime = 0;
    std::array<double, 2> pitchHead{0.0, 0.0};
    int pitchActive = 0;
    int pitchFade = -1;
    double pitchBlend = 1.0;
    std::array<std::array<double, 2>, 2> pitchFilter{};
    // ---------------------------------------------------------------------------
    // 箱琴 Marimba：起音检测 + YIN 音高检测 + 模态加法合成
    // 规格：docs/marimba_effect_spec.md（与网页端 web/effects_worklet.js 1:1 对应）
    // ---------------------------------------------------------------------------
    static constexpr int marimbaPartialCount = 5;       // 分音数
    static constexpr int marimbaVoiceCount = 4;          // 同时发声的声部数
    static constexpr int marimbaDecimation = 4;          // 抽取倍数
    static constexpr double marimbaMinFrequency = 75.0;  // 可检测最低频率
    static constexpr double marimbaMaxFrequency = 1100.0;
    static constexpr double marimbaOnsetBase = 0.05;     // 起音绝对阈值基准
    static constexpr double marimbaEnergyRatio = 1.6;    // 起音判定：短时 / 长时能量比
    static constexpr double marimbaRearmRatio = 1.02;    // 重新武装阈值
    static constexpr double marimbaVelocityReference = 0.30;
    static constexpr double marimbaVelocityFloor = 0.25;
    static constexpr double marimbaVelocityCeiling = 1.0;
    static constexpr double marimbaVoiceGain = 0.20;    // 单声部分音整体增益（槌击噪声不乘）
    static constexpr double marimbaClickGain = 0.08;     // 槌击噪声初始增益
    static constexpr double marimbaVoiceEndLevel = 1e-4; // 声部结束阈值
    static constexpr double marimbaEnergyFloor = 0.002;  // 捕获窗口 RMS 下限
    static constexpr double marimbaYinThreshold = 0.15;  // YIN 绝对阈值
    static constexpr double marimbaPartialRatio[marimbaPartialCount] = {1.0, 2.0, 3.0, 4.0, 6.0};
    static constexpr double marimbaPartialBase[marimbaPartialCount] = {1.0, 0.06, 0.03, 0.05, 0.0};
    static constexpr double marimbaPartialDelta[marimbaPartialCount] = {0.0, 0.10, 0.12, 0.30, 0.07};
    static constexpr double marimbaPartialDecayFactor[marimbaPartialCount] = {1.0, 0.55, 0.42, 0.30, 0.22};

    struct MarimbaVoice {
        bool active = false;
        int age = 0;
        double clickAmp = 0.0;
        double clickLp = 0.0;
        std::array<double, marimbaPartialCount> phase{};
        std::array<double, marimbaPartialCount> step{};
        std::array<double, marimbaPartialCount> amp{};
    };
    std::array<MarimbaVoice, marimbaVoiceCount> marimbaVoices{};
    std::vector<double> marimbaCapture;                 // 抽取域捕获缓冲
    std::vector<double> marimbaDifference;               // YIN 差分数组
    std::array<double, marimbaPartialCount> marimbaDecayCoef{};
    std::array<double, 4> marimbaDecimator{};
    double marimbaAnalysisRate = 0.0;
    int marimbaMaxLag = 0;
    int marimbaLagMin = 0;
    int marimbaCaptureLength = 0;
    int marimbaDecimPhase = 0;
    int marimbaCaptureCount = 0;
    bool marimbaCapturing = false;
    bool marimbaArmed = true;
    double marimbaCapturePeak = 0.0;
    double marimbaFastEnv = 0.0;
    double marimbaShortEnergy = 0.0;
    double marimbaLongEnergy = 0.0;
    int marimbaRefractorySamples = 0;
    int marimbaSamplesSinceOnset = 0;
    double marimbaDecimatorAlpha = 0.0;
    double marimbaFastRelease = 0.0;
    double marimbaShortAlpha = 0.0;
    double marimbaLongAlpha = 0.0;
    double marimbaClickAlpha = 0.0;
    double marimbaClickDecay = 0.0;
    double marimbaDecayTauBase = 0.0;   // 1 / log(1000)
    double marimbaLastDecay = -1.0;
    std::uint32_t marimbaNoiseSeed = 22222u;
    int marimbaNextVoiceAge = 0;

    // 衰减参数变化时重算逐采样衰减系数（已发声的声部立即采用新值）。
    void updateMarimbaDecay(double decay) {
        if (std::abs(decay - marimbaLastDecay) <= 1e-6) return;
        marimbaLastDecay = decay;
        for (int p = 0; p < marimbaPartialCount; ++p) {
            const size_t index = static_cast<size_t>(p);
            const double tau = decay * marimbaDecayTauBase * marimbaPartialDecayFactor[index];
            marimbaDecayCoef[index] = std::exp(-1.0 / (rate * tau));
        }
    }

    // xorshift32 伪随机（与网页端逐位一致），返回 [-1, 1)。
    double nextMarimbaNoise() {
        std::uint32_t state = marimbaNoiseSeed;
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        marimbaNoiseSeed = state;
        return (static_cast<double>(state & 0xFFFFFFu) / 8388607.5) - 1.0;
    }

    // 触发一个木琴声部（没有空闲声部时抢占最早触发的一个）。
    void triggerMarimbaVoice(double frequency, double velocity) {
        MarimbaVoice* voice = nullptr;
        for (auto& candidate : marimbaVoices) {
            if (!candidate.active) {
                voice = &candidate;
                break;
            }
        }
        if (voice == nullptr) {
            voice = &marimbaVoices[0];
            for (auto& candidate : marimbaVoices)
                if (candidate.age < voice->age) voice = &candidate;
        }
        voice->active = true;
        voice->age = marimbaNextVoiceAge++;
        voice->clickAmp = marimbaClickGain * velocity;
        voice->clickLp = 0.0;
        for (int p = 0; p < marimbaPartialCount; ++p) {
            const size_t index = static_cast<size_t>(p);
            voice->phase[index] = 0.0;
            voice->amp[index] = 1.0;
            voice->step[index] = juce::MathConstants<double>::twoPi * frequency * marimbaPartialRatio[index] / rate;
        }
    }

    // YIN 音高检测（移植自 lib/features/tuner/pitch_detector.dart，规格 §5），检测失败返回 0。
    double detectMarimbaPitch() {
        if (marimbaMaxLag < 3 || marimbaCaptureLength <= marimbaMaxLag) return 0.0;
        const int window = marimbaCaptureLength - marimbaMaxLag;
        double mean = 0.0;
        for (int i = 0; i < marimbaCaptureLength; ++i) mean += marimbaCapture[static_cast<size_t>(i)];
        mean /= static_cast<double>(marimbaCaptureLength);
        double energy = 0.0;
        for (int i = 0; i < marimbaCaptureLength; ++i) {
            const double delta = marimbaCapture[static_cast<size_t>(i)] - mean;
            energy += delta * delta;
        }
        if (std::sqrt(energy / static_cast<double>(marimbaCaptureLength)) < marimbaEnergyFloor) return 0.0;
        // 差分 + 累积均值归一化。
        double cumulative = 0.0;
        marimbaDifference[0] = 1.0;
        for (int lag = 1; lag <= marimbaMaxLag; ++lag) {
            double sum = 0.0;
            for (int i = 0; i < window; ++i) {
                const double delta = marimbaCapture[static_cast<size_t>(i)] - marimbaCapture[static_cast<size_t>(i + lag)];
                sum += delta * delta;
            }
            cumulative += sum;
            marimbaDifference[static_cast<size_t>(lag)] = cumulative == 0.0 ? 1.0 : sum * static_cast<double>(lag) / cumulative;
        }
        // 首个低于阈值的谷，抛物线插值细化滞后。
        int lag = marimbaLagMin;
        while (lag < marimbaMaxLag - 1) {
            if (marimbaDifference[static_cast<size_t>(lag)] >= marimbaYinThreshold) {
                ++lag;
                continue;
            }
            while (lag + 1 < marimbaMaxLag && marimbaDifference[static_cast<size_t>(lag + 1)] < marimbaDifference[static_cast<size_t>(lag)])
                ++lag;
            if (lag >= marimbaMaxLag) return 0.0;
            const double left = marimbaDifference[static_cast<size_t>(lag - 1)];
            const double center = marimbaDifference[static_cast<size_t>(lag)];
            const double right = marimbaDifference[static_cast<size_t>(lag + 1)];
            const double denominator = left - 2.0 * center + right;
            const double offset = denominator == 0.0 ? 0.0 : 0.5 * (left - right) / denominator;
            return marimbaAnalysisRate / (static_cast<double>(lag) + offset);
        }
        return 0.0;
    }

    // 箱琴逐采样处理（规格 §4），返回湿声（未做干湿混合与输出增益）。
    double processMarimbaSample(float inLeft, float inRight, const std::array<float, 8>& values) {
        // 步骤 0：衰减参数变化时立即重算衰减系数。
        updateMarimbaDecay(static_cast<double>(values[1]));
        // 步骤 A：分析用单声道输入 + 快包络 + 短时 / 长时能量。
        const double x = 0.5 * (static_cast<double>(inLeft) + static_cast<double>(inRight));
        const double amplitude = std::abs(x);
        marimbaFastEnv = std::max(amplitude, marimbaFastEnv * marimbaFastRelease);
        const double power = amplitude * amplitude;
        marimbaShortEnergy += marimbaShortAlpha * (power - marimbaShortEnergy);
        marimbaLongEnergy += marimbaLongAlpha * (power - marimbaLongEnergy);
        // 步骤 B：起音检测（短时能量相对长时能量突增 = 标准能量比起音检测）。
        const double threshold = marimbaOnsetBase * std::pow(0.1, static_cast<double>(values[3]));
        // 重新武装：一次起音触发后必须等能量回落到长时能量附近，才允许下一次起音（防止持续音连奏）。
        if (!marimbaArmed && marimbaShortEnergy <= marimbaLongEnergy * marimbaRearmRatio) marimbaArmed = true;
        // 捕获进行中忽略新的起音：保证音符起点固定在「首个起音 + 捕获窗口」。
        if (marimbaArmed && !marimbaCapturing && marimbaFastEnv > threshold
            && marimbaShortEnergy > marimbaLongEnergy * marimbaEnergyRatio
            && marimbaSamplesSinceOnset >= marimbaRefractorySamples) {
            marimbaSamplesSinceOnset = 0;
            marimbaArmed = false;
            marimbaCapturing = true;
            marimbaCaptureCount = 0;
            marimbaCapturePeak = 0.0;
        }
        ++marimbaSamplesSinceOnset;
        if (marimbaCapturing && amplitude > marimbaCapturePeak) marimbaCapturePeak = amplitude;
        // 步骤 C：4 倍抽取（4 级单极点低通级联），每 4 个采样点落一次抽取值。
        marimbaDecimator[0] += marimbaDecimatorAlpha * (x - marimbaDecimator[0]);
        marimbaDecimator[1] += marimbaDecimatorAlpha * (marimbaDecimator[0] - marimbaDecimator[1]);
        marimbaDecimator[2] += marimbaDecimatorAlpha * (marimbaDecimator[1] - marimbaDecimator[2]);
        marimbaDecimator[3] += marimbaDecimatorAlpha * (marimbaDecimator[2] - marimbaDecimator[3]);
        ++marimbaDecimPhase;
        if (marimbaDecimPhase >= marimbaDecimation) {
            marimbaDecimPhase = 0;
            if (marimbaCapturing) {
                marimbaCapture[static_cast<size_t>(marimbaCaptureCount)] = marimbaDecimator[3];
                ++marimbaCaptureCount;
                if (marimbaCaptureCount >= marimbaCaptureLength) {
                    marimbaCapturing = false;
                    const double frequency = detectMarimbaPitch();
                    if (frequency > 0.0) {
                        // 力度取捕获窗口内的峰值幅度（比起音瞬间的包络更稳）。
                        const double velocity = juce::jlimit(marimbaVelocityFloor, marimbaVelocityCeiling,
                            marimbaCapturePeak / marimbaVelocityReference);
                        triggerMarimbaVoice(frequency * std::pow(2.0, static_cast<double>(values[0]) / 12.0), velocity);
                    }
                }
            }
        }
        // 步骤 D：声部合成（模态加法合成 + 槌击噪声）。
        const double noise = nextMarimbaNoise();
        const double tone = static_cast<double>(values[2]);
        double wet = 0.0;
        for (auto& voice : marimbaVoices) {
            if (!voice.active) continue;
            double sum = 0.0;
            for (int p = 0; p < marimbaPartialCount; ++p) {
                const size_t index = static_cast<size_t>(p);
                voice.phase[index] += voice.step[index];
                if (voice.phase[index] >= juce::MathConstants<double>::twoPi) voice.phase[index] -= juce::MathConstants<double>::twoPi;
                sum += voice.amp[index] * (marimbaPartialBase[index] + marimbaPartialDelta[index] * tone)
                    * std::sin(voice.phase[index]);
                voice.amp[index] *= marimbaDecayCoef[index];
            }
            voice.clickLp += marimbaClickAlpha * (noise - voice.clickLp);
            const double click = (noise - voice.clickLp) * voice.clickAmp;
            voice.clickAmp *= marimbaClickDecay;
            wet += sum * marimbaVoiceGain + click;
            if (voice.amp[0] < marimbaVoiceEndLevel && voice.clickAmp < marimbaVoiceEndLevel) voice.active = false;
        }
        return wet;
    }
};
