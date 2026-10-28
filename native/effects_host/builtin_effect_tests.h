#pragma once
#include "builtin_effect.h"
#include <iostream>

inline void testBuiltinDsp() {
    auto require = [](bool condition, const char* message) { if (!condition) throw juce::String(message); };
    juce::MidiBuffer midi;
    // Check sample-rate changes, parameter extremes, silence and finite output.
    for (auto rate : {44100.0, 48000.0, 96000.0}) {
        for (const auto* kind : {"fuzz", "compressor", "reverb", "overdrive", "delay"}) {
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
