#pragma once
#include <juce_audio_utils/juce_audio_utils.h>
#include <array>
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
        } else throw juce::String::fromUTF8("未知内置效果器。");
    }

    const juce::String getName() const override { return title; }
    void prepareToPlay(double sampleRate, int) override {
        rate = sampleRate;
        for (size_t i = 0; i < parameters.size(); ++i) {
            smooth[i].reset(rate, 0.02);
            smooth[i].setCurrentAndTargetValue(parameters[i]->get());
        }
        toneState.fill(0);
        dcInput.fill(0);
        dcOutput.fill(0);
        envelope = 0;
        delayBuffer.setSize(2, static_cast<int>(std::ceil(rate * 1.6)) + 2);
        delayBuffer.clear();
        position = 0;
        if (kind == "reverb") updateReverb(parameters[0]->get(), parameters[1]->get(), parameters[2]->get());
        reverb.setSampleRate(rate);
        reverb.reset();
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
        for (int sample = 0; sample < samples; ++sample) {
            std::array<float, 5> values{};
            for (size_t i = 0; i < parameters.size(); ++i) values[i] = smooth[i].getNextValue();
            if (kind == "compressor") {
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
    double getTailLengthSeconds() const override { return kind == "delay" ? 30 : kind == "reverb" ? 10 : 0; }
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
            juce::NormalisableRange<float>(low, high), initial, juce::AudioParameterFloatAttributes().withLabel(unit));
        addParameter(parameter);
        parameters.push_back(parameter);
    }
    juce::String title;
    std::vector<juce::AudioParameterFloat*> parameters;
    std::array<juce::SmoothedValue<float>, 5> smooth;
    std::array<float, 2> toneState{}, dcInput{}, dcOutput{};
    juce::AudioBuffer<float> delayBuffer;
    juce::Reverb reverb;
    double rate = 48000;
    float envelope = 0;
    int position = 0;
};
