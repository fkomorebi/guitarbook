#pragma once
#include "builtin_effect.h"
#include <iostream>

inline void testBuiltinDsp() {
    auto require = [](bool condition, const char* message) { if (!condition) throw juce::String(message); };
    juce::MidiBuffer midi;
    // Check sample-rate changes, parameter extremes, silence and finite output.
    for (auto rate : {44100.0, 48000.0, 96000.0}) {
        for (const auto* kind : {"wah", "fuzz", "compressor", "reverb", "overdrive", "delay", "amp_clean", "amp_chime", "amp_crunch", "amp_modern"}) {
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

    // An independent instance must not inherit another delay's tail.
    BuiltinEffect fresh("delay");
    fresh.prepareToPlay(48000, 4096);
    impulse.clear();
    fresh.processBlock(impulse, midi);
    require(impulse.getMagnitude(0, 4096) == 0, "Effect instances shared state");
    std::cout << "Built-in DSP tests passed" << std::endl;
}
