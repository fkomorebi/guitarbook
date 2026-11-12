#pragma once
#include "builtin_effect.h"
#include <cmath>
#include <iostream>
#include <utility>
#include <vector>

inline void testBuiltinDsp() {
    auto require = [](bool condition, const char* message) { if (!condition) throw juce::String(message); };
    juce::MidiBuffer midi;
    // Check sample-rate changes, parameter extremes, silence and finite output.
    for (auto rate : {44100.0, 48000.0, 96000.0}) {
        for (const auto* kind : {"wah", "fuzz", "compressor", "reverb", "overdrive", "delay", "pitch", "marimba", "amp_clean", "amp_chime", "amp_crunch", "amp_modern"}) {
            BuiltinEffect effect(kind);
            effect.prepareToPlay(rate, 512);
            juce::AudioBuffer<float> audio(2, 512);
            audio.clear();
            effect.processBlock(audio, midi);
            require(audio.getMagnitude(0, 512) == 0, "Silent input must remain silent");
            for (int block = 0; block < 40; ++block) {
                for (auto* param : effect.getParameters()) param->setValueNotifyingHost(block % 2 ? 0.0f : 1.0f);
                for (int ch = 0; ch < 2; ++ch)
                    for (int i = 0; i < 512; ++i) audio.setSample(ch, i, 0.3f * std::sin(static_cast<float>((block * 512 + i) * 2 * juce::MathConstants<double>::pi * 220 / rate)));
                effect.processBlock(audio, midi);
                for (int ch = 0; ch < 2; ++ch)
                    for (int i = 0; i < 512; ++i) require(std::isfinite(audio.getSample(ch, i)), "Non-finite DSP output");
            }
        }
    }
    // Compare complete waveforms, exercise every control and reset/instance isolation.
    const auto renderAmp = [&midi](const char* kind, int parameter, float value) {
        BuiltinEffect amp(kind);
        if (parameter >= 0) amp.setParameterValue(parameter, value);
        amp.prepareToPlay(48000, 4096);
        juce::AudioBuffer<float> audio(2, 4096);
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < 4096; ++i) {
                const double t = i / 48000.0;
                audio.setSample(ch, i, 0.12f * static_cast<float>(
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 110) +
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 997) +
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 6000)));
            }
        amp.processBlock(audio, midi);
        return audio;
    };
    const auto difference = [](const juce::AudioBuffer<float>& a, const juce::AudioBuffer<float>& b) {
        double sum = 0;
        for (int i = 0; i < a.getNumSamples(); ++i) sum += std::abs(a.getSample(0, i) - b.getSample(0, i));
        return sum;
    };
    std::vector<juce::AudioBuffer<float>> models;
    for (const auto* kind : {"amp_clean", "amp_chime", "amp_crunch", "amp_modern"}) {
        auto reference = renderAmp(kind, -1, 0);
        require(reference.getMagnitude(0, 4096) > 0.01f, "Amp produced no audio");
        for (const auto& previous : models)
            require(difference(reference, previous) > 1, "Amp models sound identical");
        for (int parameter = 0; parameter < 6; ++parameter) {
            const auto changed = renderAmp(kind, parameter, parameter == 0 ? 10 : parameter < 4 ? -12 : 0);
            require(difference(reference, changed) > 1, "Amp control has no effect");
            if (parameter == 4) require(changed.getMagnitude(0, 4096) == 0, "Amp master zero is not silent");
        }
        require(difference(reference, renderAmp(kind, -1, 0)) == 0, "Amp instances shared state");
        models.push_back(std::move(reference));
    }
    const auto wahReference = renderAmp("wah", -1, 0);
    require(wahReference.getMagnitude(0, 4096) > 0.001f, "Wah produced no audio");
    for (int parameter = 0; parameter < 4; ++parameter) {
        const auto changed = renderAmp("wah", parameter, parameter == 1 ? 8.0f : 0.0f);
        require(difference(wahReference, changed) > 1, "Wah control has no effect");
        if (parameter == 3) require(changed.getMagnitude(0, 4096) == 0, "Wah output zero is not silent");
    }
    require(difference(wahReference, renderAmp("wah", -1, 0)) == 0, "Wah instances shared state");
    const auto renderAutoWah = [&midi](float speed, float depth) {
        BuiltinEffect wah("wah");
        wah.setParameterValue(4, 1);
        wah.setParameterValue(5, speed);
        wah.setParameterValue(6, depth);
        wah.prepareToPlay(48000, 4096);
        juce::AudioBuffer<float> audio(2, 4096);
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < 4096; ++i) {
                const double t = i / 48000.0;
                audio.setSample(ch, i, 0.12f * static_cast<float>(
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 110) +
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 997) +
                    std::sin(t * 2 * juce::MathConstants<double>::pi * 6000)));
            }
        wah.processBlock(audio, midi);
        return audio;
    };
    const auto autoWah = renderAutoWah(1, 0.8f);
    require(difference(wahReference, autoWah) > 1, "Auto wah did not sweep");
    require(difference(autoWah, renderAutoWah(5, 0.8f)) > 1, "Auto wah speed had no effect");
    require(difference(autoWah, renderAutoWah(1, 0.2f)) > 1, "Auto wah depth had no effect");
    require(difference(wahReference, renderAutoWah(1, 0)) < 0.001, "Zero depth differs from manual wah");
    BuiltinEffect dryWah("wah");
    dryWah.setParameterValue(2, 0);
    dryWah.setParameterValue(3, 1);
    dryWah.prepareToPlay(48000, 512);
    juce::AudioBuffer<float> drySignal(2, 512);
    drySignal.clear();
    drySignal.setSample(0, 0, 0.5f);
    dryWah.processBlock(drySignal, midi);
    require(drySignal.getSample(0, 0) == 0.5f && drySignal.getMagnitude(1, 0, 512) == 0,
            "Wah dry mix or channel isolation failed");
    BuiltinEffect delay("delay");
    delay.setParameterValue(0, 20);
    delay.setParameterValue(1, 0.5f);
    delay.setParameterValue(2, 1);
    delay.prepareToPlay(48000, 4096);
    juce::AudioBuffer<float> impulse(2, 4096);
    impulse.clear();
    impulse.setSample(0, 0, 0.5f);
    impulse.setSample(1, 0, 0.5f);
    delay.processBlock(impulse, midi);
    require(impulse.getSample(0, 0) == 0, "Fully wet delay leaked dry audio");
    require(std::abs(impulse.getSample(0, 960) - 0.5f) < 0.001f, "Delay time mismatch");
    require(std::abs(impulse.getSample(0, 1920) - 0.25f) < 0.001f, "Delay feedback mismatch");

    BuiltinEffect compressor("compressor");
    compressor.setParameterValue(0, -20);
    compressor.setParameterValue(1, 4);
    compressor.setParameterValue(2, 1);
    compressor.setParameterValue(4, 0);
    compressor.prepareToPlay(48000, 16384);
    juce::AudioBuffer<float> sustained(2, 16384);
    for (int ch = 0; ch < 2; ++ch) juce::FloatVectorOperations::fill(sustained.getWritePointer(ch), 0.5f, 16384);
    compressor.processBlock(sustained, midi);
    require(std::abs(sustained.getSample(0, 16383) - 0.149535f) < 0.001f, "Compressor ratio/threshold mismatch");

    BuiltinEffect reverb("reverb");
    reverb.setParameterValue(2, 0);
    reverb.prepareToPlay(48000, 4096);
    impulse.clear();
    impulse.setSample(0, 0, 0.5f);
    reverb.processBlock(impulse, midi);
    require(std::abs(impulse.getSample(0, 0) - 0.5f) < 0.0001f, "Reverb dry gain must be unity");
    reverb.setParameterValue(2, 1);
    reverb.prepareToPlay(48000, 4096);
    impulse.clear();
    impulse.setSample(0, 0, 0.5f);
    reverb.processBlock(impulse, midi);
    require(impulse.getMagnitude(0, 1000, 3096) > 0.0001f, "Reverb has no tail");
    require(std::abs(impulse.getSample(0, 0)) < 0.0001f, "Fully wet reverb leaked dry audio");

    // 移调效果器：按规格 §5 验证直通、升/降八度、参数切换与实例隔离。
    // 中文消息用 fromUTF8 构造，避免 juce::String(const char*) 对非 ASCII 的断言噪音。
    const auto requireZh = [](bool condition, const char* message) {
        if (!condition) throw juce::String::fromUTF8(message);
    };
    const auto renderPitch = [&midi](float semitone, int samples) {
        BuiltinEffect pitch("pitch");
        pitch.setParameterValue(0, semitone);
        pitch.setParameterValue(1, 1);
        pitch.setParameterValue(2, 1);
        pitch.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, samples);
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < samples; ++i) {
                const double t = i / 48000.0;
                audio.setSample(ch, i, 0.4f * static_cast<float>(std::sin(t * 2 * juce::MathConstants<double>::pi * 220.0)));
            }
        pitch.processBlock(audio, midi);
        return audio;
    };
    // 自相关峰值搜索：在给定滞后区间内取最大相关峰，并用抛物线插值细化峰位。
    // 只在期望周期附近搜索，避免全局最大落在低滞后处（降八度时相关函数单调衰减）。
    const auto estimatePeriod = [](const juce::AudioBuffer<float>& audio, int start, int length, int minLag, int maxLag) {
        std::vector<double> signal(static_cast<size_t>(length));
        double mean = 0;
        for (int i = 0; i < length; ++i) mean += audio.getSample(0, start + i);
        mean /= static_cast<double>(length);
        for (int i = 0; i < length; ++i) signal[static_cast<size_t>(i)] = audio.getSample(0, start + i) - mean;
        double energy = 0;
        for (double value : signal) energy += value * value;
        const int lastLag = std::max(minLag + 1, std::min(maxLag, length - 2));
        std::vector<double> correlations(static_cast<size_t>(lastLag) + 1, 0.0);
        int bestLag = minLag;
        double bestCorrelation = -1;
        for (int lag = minLag; lag <= lastLag; ++lag) {
            double sum = 0;
            for (int i = 0; i + lag < length; ++i) sum += signal[static_cast<size_t>(i)] * signal[static_cast<size_t>(i + lag)];
            correlations[static_cast<size_t>(lag)] = sum / (energy + 1e-20);
            if (correlations[static_cast<size_t>(lag)] > bestCorrelation) {
                bestCorrelation = correlations[static_cast<size_t>(lag)];
                bestLag = lag;
            }
        }
        double refined = bestLag;
        if (bestLag > minLag && bestLag < lastLag) {
            const double y0 = correlations[static_cast<size_t>(bestLag - 1)];
            const double y1 = correlations[static_cast<size_t>(bestLag)];
            const double y2 = correlations[static_cast<size_t>(bestLag + 1)];
            const double curvature = y0 - 2 * y1 + y2;
            if (std::abs(curvature) > 1e-12) refined = bestLag + 0.5 * (y0 - y2) / curvature;
        }
        return std::pair<double, double>(refined, bestCorrelation);
    };
    // 过零率统计：每周期记一次下穿零，用于交叉验证输出基频。
    const auto estimateFrequency = [](const juce::AudioBuffer<float>& audio, int start, int length, double sampleRate) {
        int crossings = 0;
        int state = 0;
        for (int i = 0; i < length; ++i) {
            const double value = audio.getSample(0, start + i);
            if (state <= 0 && value > 0.02) state = 1;
            else if (state >= 0 && value < -0.02) { state = -1; ++crossings; }
        }
        return crossings * sampleRate / static_cast<double>(length);
    };
    const auto pitchSignal = [&midi]() {
        juce::AudioBuffer<float> audio(2, 4096);
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < 4096; ++i) {
                const double t = i / 48000.0;
                audio.setSample(ch, i, 0.4f * static_cast<float>(std::sin(t * 2 * juce::MathConstants<double>::pi * 220.0)
                    + 0.2 * std::sin(t * 2 * juce::MathConstants<double>::pi * 997.0)));
            }
        return audio;
    };
    // 0 半音必须完全直通：逐采样与输入一致（无额外延迟、无梳状失真）。
    {
        BuiltinEffect pitch("pitch");
        pitch.setParameterValue(0, 0);
        pitch.setParameterValue(1, 1);
        pitch.setParameterValue(2, 1);
        pitch.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio = pitchSignal();
        const juce::AudioBuffer<float> source(audio);
        pitch.processBlock(audio, midi);
        double maxDifference = 0;
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < audio.getNumSamples(); ++i) {
                const double delta = std::abs(static_cast<double>(audio.getSample(ch, i)) - source.getSample(ch, i));
                if (delta > maxDifference) maxDifference = delta;
            }
        requireZh(maxDifference < 1e-6, "移调 0 半音未保持完全直通");
    }
    // 干湿比为 0 时只输出干声，输出旋钮为 0 时静音。
    {
        BuiltinEffect pitch("pitch");
        pitch.setParameterValue(0, 12);
        pitch.setParameterValue(1, 0);
        pitch.setParameterValue(2, 1);
        pitch.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio = pitchSignal();
        const juce::AudioBuffer<float> source(audio);
        pitch.processBlock(audio, midi);
        double maxDifference = 0;
        for (int i = 0; i < audio.getNumSamples(); ++i) {
            const double delta = std::abs(static_cast<double>(audio.getSample(0, i)) - source.getSample(0, i));
            if (delta > maxDifference) maxDifference = delta;
        }
        requireZh(maxDifference < 1e-6, "移调干湿比为 0 时未保持干声直通");

        BuiltinEffect muted("pitch");
        muted.setParameterValue(0, 12);
        muted.setParameterValue(1, 1);
        muted.setParameterValue(2, 0);
        muted.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> quiet = pitchSignal();
        muted.processBlock(quiet, midi);
        requireZh(quiet.getMagnitude(0, quiet.getNumSamples()) == 0, "移调输出旋钮为 0 时未静音");
    }
    // 升/降八度：自相关峰应落在约 0.5 倍周期（升）与约 2 倍周期（降）。
    {
        const int analysisStart = 16384; // 跳过干湿混合的过渡段
        const int analysisLength = 32768;
        const auto dry = renderPitch(0, analysisStart + analysisLength);
        const auto up = renderPitch(12, analysisStart + analysisLength);
        const auto down = renderPitch(-12, analysisStart + analysisLength);
        requireZh(dry.getMagnitude(0, analysisStart + analysisLength) > 0.1f, "移调效果器没有输出");
        // 基线：220 Hz 正弦在 48 kHz 下周期约 218 采样
        const auto dryPeriod = estimatePeriod(dry, analysisStart, analysisLength, 150, 300);
        // 只在期望周期附近搜索相关峰，避免低滞后处的相关值压过真正的周期峰
        const auto upPeriod = estimatePeriod(up, analysisStart, analysisLength,
            static_cast<int>(dryPeriod.first * 0.4), static_cast<int>(dryPeriod.first * 0.6));
        const auto downPeriod = estimatePeriod(down, analysisStart, analysisLength,
            static_cast<int>(dryPeriod.first * 1.7), static_cast<int>(dryPeriod.first * 2.3));
        requireZh(dryPeriod.first > 196 && dryPeriod.first < 240, "移调基线周期测量异常");
        requireZh(upPeriod.first * 2 > dryPeriod.first * 0.9 && upPeriod.first * 2 < dryPeriod.first * 1.1,
            "升八度后基频没有升高");
        requireZh(downPeriod.first > dryPeriod.first * 1.8 && downPeriod.first < dryPeriod.first * 2.2,
            "降八度后基频没有降低");
        requireZh(upPeriod.second > 0.5 && downPeriod.second > 0.5, "移调输出周期性太弱");
        // 过零率交叉验证：升八度约两倍、降八度约一半
        const double dryFrequency = estimateFrequency(dry, analysisStart, analysisLength, 48000);
        const double upFrequency = estimateFrequency(up, analysisStart, analysisLength, 48000);
        const double downFrequency = estimateFrequency(down, analysisStart, analysisLength, 48000);
        requireZh(upFrequency > dryFrequency * 1.75 && upFrequency < dryFrequency * 2.25,
            "升八度后过零率未接近两倍");
        requireZh(downFrequency > dryFrequency * 0.44 && downFrequency < dryFrequency * 0.56,
            "降八度后过零率未接近一半");
    }
    // 参数切换（0 → +12 → -12 → 0）过程中不得出现 NaN/Inf、削波或爆音。
    {
        BuiltinEffect pitch("pitch");
        pitch.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, 512);
        const float steps[] = {0.0f, 12.0f, -12.0f, 0.0f};
        for (float step : steps) {
            pitch.setParameterValue(0, step);
            for (int block = 0; block < 24; ++block) {
                for (int ch = 0; ch < 2; ++ch)
                    for (int i = 0; i < 512; ++i) {
                        const double t = (block * 512 + i) / 48000.0;
                        audio.setSample(ch, i, 0.3f * static_cast<float>(std::sin(t * 2 * juce::MathConstants<double>::pi * 220.0)));
                    }
                pitch.processBlock(audio, midi);
                for (int ch = 0; ch < 2; ++ch)
                    for (int i = 0; i < 512; ++i) {
                        const float value = audio.getSample(ch, i);
                        requireZh(std::isfinite(value), "移调参数切换期间出现非有限输出");
                        requireZh(std::abs(value) <= 1.2f, "移调参数切换期间出现削波");
                        if (i > 0)
                            requireZh(std::abs(value - audio.getSample(ch, i - 1)) <= 0.5f, "移调参数切换期间出现爆音");
                    }
            }
        }
    }
    // 多实例隔离：两个实例状态互不影响。
    {
        const auto reference = renderPitch(0, 8192);
        const auto shifted = renderPitch(12, 8192);
        requireZh(difference(reference, shifted) > 1, "移调参数没有生效");
        requireZh(difference(reference, renderPitch(0, 8192)) == 0, "移调效果器实例间共享状态");
    }

    // ===========================================================================
    // 箱琴 Marimba：按规格 docs/marimba_effect_spec.md §8 验证
    // ===========================================================================
    // 参数表：6 个参数，名称 / 量程 / 默认值 / 顺序必须与规格 §2 一致。
    {
        BuiltinEffect marimba("marimba");
        const auto& parameters = marimba.getParameters();
        requireZh(parameters.size() == 6, "箱琴参数数量与规格不一致");
        const float minimums[6] = {-12.0f, 0.2f, 0.0f, 0.0f, 0.0f, 0.0f};
        const float maximums[6] = {12.0f, 4.0f, 1.0f, 1.0f, 1.0f, 1.0f};
        const float initials[6] = {0.0f, 1.2f, 0.6f, 0.5f, 1.0f, 0.8f};
        for (int i = 0; i < 6; ++i) {
            auto* parameter = parameters[i];
            requireZh(std::abs(parameter->range.start - minimums[i]) < 1e-6f
                && std::abs(parameter->range.end - maximums[i]) < 1e-6f
                && std::abs(parameter->get() - initials[i]) < 1e-6f,
                "箱琴参数量程或默认值与规格不一致");
        }
    }
    // 箱琴测试信号：0.3 幅度 220 Hz 正弦 + 20 ms 线性起音（避免突变引入宽带噪声）。
    const auto marimbaSignal = [](juce::AudioBuffer<float>& audio, int samples) {
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < samples; ++i) {
                const double t = i / 48000.0;
                const double envelope = t < 0.02 ? t / 0.02 : 1.0;
                audio.setSample(ch, i, static_cast<float>(0.3 * envelope
                    * std::sin(t * 2 * juce::MathConstants<double>::pi * 220.0)));
            }
    };
    const auto renderMarimba = [&midi, &marimbaSignal](int samples, const std::vector<std::pair<int, float>>& overrides) {
        BuiltinEffect marimba("marimba");
        for (const auto& override : overrides) marimba.setParameterValue(override.first, override.second);
        marimba.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, samples);
        marimbaSignal(audio, samples);
        marimba.processBlock(audio, midi);
        return audio;
    };
    // 音符起点：第一个非零采样（湿声在捕获窗口结束前必须保持静音）。
    const auto firstNoteSample = [](const juce::AudioBuffer<float>& audio) {
        for (int i = 0; i < audio.getNumSamples(); ++i)
            if (std::abs(audio.getSample(0, i)) > 0.0f) return i;
        return -1;
    };
    // 余音末端：最后一个幅度超过 1e-3 的采样。
    const auto tailSample = [](const juce::AudioBuffer<float>& audio) {
        int last = -1;
        for (int i = 0; i < audio.getNumSamples(); ++i)
            if (std::abs(audio.getSample(0, i)) > 1e-3f) last = i;
        return last;
    };
    // 音分偏差：1200 * log2(f / 参考频率)。
    const auto centsFrom = [](double frequency, double reference) {
        return 1200.0 * std::log2(frequency / reference);
    };
    // 静音输入必须保持静音。
    {
        BuiltinEffect marimba("marimba");
        marimba.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, 512);
        audio.clear();
        marimba.processBlock(audio, midi);
        requireZh(audio.getMagnitude(0, 512) == 0 && audio.getMagnitude(1, 512) == 0,
            "箱琴静音输入未保持静音");
    }
    // 干湿比为 0 时只输出干声（输出旋钮取 1，默认 0.8 会整体缩放干声）。
    {
        BuiltinEffect marimba("marimba");
        marimba.setParameterValue(4, 0);
        marimba.setParameterValue(5, 1);
        marimba.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, 4096);
        marimbaSignal(audio, 4096);
        const juce::AudioBuffer<float> source(audio);
        marimba.processBlock(audio, midi);
        double maxDifference = 0;
        for (int ch = 0; ch < 2; ++ch)
            for (int i = 0; i < audio.getNumSamples(); ++i) {
                const double delta = std::abs(static_cast<double>(audio.getSample(ch, i)) - source.getSample(ch, i));
                if (delta > maxDifference) maxDifference = delta;
            }
        requireZh(maxDifference < 1e-6, "箱琴干湿比为 0 时未保持干声直通");
    }
    // 输出旋钮为 0 时必须静音。
    {
        BuiltinEffect muted("marimba");
        muted.setParameterValue(5, 0);
        muted.prepareToPlay(48000, 512);
        juce::AudioBuffer<float> audio(2, 8192);
        marimbaSignal(audio, 8192);
        muted.processBlock(audio, midi);
        requireZh(audio.getMagnitude(0, audio.getNumSamples()) == 0, "箱琴输出旋钮为 0 时未静音");
    }
    // 220 Hz 输入：约 53 ms（捕获窗口）之后出现音符，音高接近 220 Hz（±5 音分）。
    {
        const auto audio = renderMarimba(16384, {{4, 1.0f}, {5, 1.0f}});
        const int note = firstNoteSample(audio);
        // 捕获窗口 = 16 * maxLag 采样（抽取 4 倍 × 捕获 4 * maxLag），48 kHz 下约 53.3 ms。
        requireZh(note > 2400 && note < 3600, "箱琴音符起点不在捕获窗口之后");
        requireZh(note > 0 && audio.getMagnitude(0, 0, note) == 0, "箱琴捕获窗口内不应出现输出");
        const auto period = estimatePeriod(audio, note + 512, 8192, 150, 300);
        const double frequency = 48000.0 / period.first;
        requireZh(period.second > 0.5, "箱琴输出周期性太弱");
        requireZh(std::abs(centsFrom(frequency, 220.0)) <= 5.0, "箱琴音高偏离 220 Hz 超过 5 音分");
    }
    // 移调参数改变输出音高（+12 半音 = 高八度）。
    {
        const auto plain = renderMarimba(16384, {{5, 1.0f}});
        const auto up = renderMarimba(16384, {{0, 12.0f}, {5, 1.0f}});
        const int plainNote = firstNoteSample(plain);
        const int upNote = firstNoteSample(up);
        const auto plainPeriod = estimatePeriod(plain, plainNote + 512, 8192, 150, 300);
        const auto upPeriod = estimatePeriod(up, upNote + 512, 8192, 60, 160);
        const double ratio = plainPeriod.first / upPeriod.first;
        requireZh(ratio > 1.9 && ratio < 2.1, "箱琴移调 12 半音后音高未升高一倍");
    }
    // 衰减参数改变余音长度（衰减越大余音越长）。
    {
        const auto quick = renderMarimba(120000, {{1, 0.4f}, {5, 1.0f}});
        const auto longTail = renderMarimba(120000, {{1, 2.4f}, {5, 1.0f}});
        const int quickEnd = tailSample(quick);
        const int longEnd = tailSample(longTail);
        requireZh(quickEnd > 0 && longEnd > 0, "箱琴余音缺失");
        requireZh(longEnd > quickEnd * 3, "箱琴衰减参数未改变余音长度");
    }
    // 多实例隔离：两个实例状态互不影响。
    {
        const auto reference = renderMarimba(8192, {{5, 1.0f}});
        requireZh(difference(reference, renderMarimba(8192, {{5, 1.0f}})) == 0, "箱琴效果器实例间共享状态");
        requireZh(difference(reference, renderMarimba(8192, {{0, 7.0f}, {5, 1.0f}})) > 1, "箱琴参数没有生效");
    }

    // An independent instance must not inherit another delay's tail.
    BuiltinEffect fresh("delay");
    fresh.prepareToPlay(48000, 4096);
    impulse.clear();
    fresh.processBlock(impulse, midi);
    require(impulse.getMagnitude(0, 4096) == 0, "Effect instances shared state");
    std::cout << "Built-in DSP tests passed" << std::endl;
}
