#pragma once
#include "../effects_host/builtin_effect.h"
#include <atomic>
#include <mutex>
#include <vector>

namespace guitarbook {
inline juce::var object(std::initializer_list<std::pair<juce::Identifier, juce::var>> fields) {
    auto* result = new juce::DynamicObject();
    for (const auto& field : fields) result->setProperty(field.first, field.second);
    return juce::var(result);
}

// Control calls are serialized by the platform main thread. Only process() runs
// on the audio thread; it never waits for a control operation or allocates PCM.
class Engine {
public:
    static constexpr int capacity = 16384;
    virtual ~Engine() = default;
    virtual void open() = 0;
    virtual void close() = 0; // Must join/drain callbacks before returning.
    virtual juce::var deviceStatus() = 0;

    juce::var command(const juce::var& request) {
        const auto action = request["command"].toString();
        if (action == "start" || action == "probe") {
            close();
            try {
                failed = false;
                running = true;
                open();
                auto result = status();
                if (action == "probe") {
                    close();
                    result.getDynamicObject()->setProperty("running", false);
                    result.getDynamicObject()->setProperty("audioOpen", false);
                    result.getDynamicObject()->setProperty("available", true);
                }
                return result;
            } catch (...) { close(); throw; }
        }
        if (action == "stop") close();
        else if (action == "audioBuffer") {
            if (running) throw juce::String::fromUTF8("请先停止监听，再调整缓冲。");
            const int frames = request["frames"];
            if (frames != 64 && frames != 128 && frames != 256 && frames != 512)
                throw juce::String::fromUTF8("无效缓冲大小。");
            requestedBuffer = frames;
        } else if (action == "gain") {
            const float value = request["value"];
            if (!std::isfinite(value)) throw juce::String::fromUTF8("无效音量。");
            gain = juce::jlimit(0.0f, 1.0f, value);
        } else if (action == "builtin") {
            if (chain.size() >= 8) throw juce::String::fromUTF8("最多添加 8 个效果器。");
            auto effect = std::make_unique<BuiltinEffect>(request["kind"].toString());
            effect->prepareToPlay(rate, capacity);
            std::lock_guard<std::mutex> lock(mutex);
            chain.push_back({std::move(effect), false});
        } else if (action == "parameter" || action == "bypass" || action == "move" || action == "remove") {
            const int index = request["index"];
            if (index < 0 || index >= static_cast<int>(chain.size()))
                throw juce::String::fromUTF8("效果器已不存在。");
            std::lock_guard<std::mutex> lock(mutex);
            if (action == "parameter") chain[index].effect->setParameterValue(int(request["parameter"]), float(request["value"]));
            else if (action == "bypass") chain[index].bypass = bool(request["value"]);
            else if (action == "remove") chain.erase(chain.begin() + index);
            else {
                const int destination = request["destination"];
                if (destination < 0 || destination >= static_cast<int>(chain.size()))
                    throw juce::String::fromUTF8("无效排序位置。");
                auto item = std::move(chain[index]);
                chain.erase(chain.begin() + index);
                chain.insert(chain.begin() + destination, std::move(item));
            }
        } else if (action == "loopStart") {
            std::lock_guard<std::mutex> lock(mutex);
            if (!running || failed) throw juce::String::fromUTF8("请先在效果器中开始监听，再录音。");
            if (std::abs(rate - 48000) > 0.1) throw juce::String::fromUTF8("湿声录音需要实际采样率为 48 kHz，当前设备不支持，请更换音频设备。");
            wet = false;
            fifo.reset();
            overflow = false;
            wet = true;
            return object({{"sampleRate", 48000}});
        } else if (action == "loopStop") {
            std::lock_guard<std::mutex> lock(mutex);
            wet = false;
            fifo.reset();
        } else if (action == "loopRead") {
            if (!wet || !running || failed) throw juce::String::fromUTF8("效果器监听已中断，请重新开始监听和录音。");
            if (overflow) throw juce::String::fromUTF8("湿声采集缓冲溢出，请重新录音。");
            juce::MemoryBlock pcm;
            int a, n, b, m;
            fifo.prepareToRead(fifo.getNumReady(), a, n, b, m);
            pcm.append(pcmData.data() + a * 2, size_t(n * 2));
            pcm.append(pcmData.data() + b * 2, size_t(m * 2));
            fifo.finishedRead(n + m);
            return object({{"pcm", juce::Base64::toBase64(pcm.getData(), pcm.getSize())}});
        } else if (action != "status" && action != "start" && action != "probe" && action != "stop") {
            throw juce::String::fromUTF8("移动端仅支持内置效果器，请使用系统音频路由设置。");
        }
        return status();
    }

    juce::String dispatch(const juce::String& json) {
        try { return juce::JSON::toString(object({{"result", command(juce::JSON::parse(json))}})); }
        catch (const juce::String& error) { return juce::JSON::toString(object({{"error", error}})); }
        catch (const std::exception& error) { return juce::JSON::toString(object({{"error", juce::String(error.what())}})); }
    }

    void prepare(double sampleRate, int frames) {
        rate = sampleRate;
        block = frames;
        audio.setSize(2, capacity);
        midi.ensureSize(2048);
        for (auto& item : chain) item.effect->prepareToPlay(rate, capacity);
        wet = false;
        inputPeak = outputPeak = 0;
    }
    void stopped(bool error = false) {
        running = false;
        wet = false;
        failed = error;
        inputPeak = outputPeak = 0;
    }
    void process(const float* input, int inputFrames, float* output, int frames) {
        std::fill(output, output + frames * 2, 0.0f);
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        block = frames;
        if (frames > capacity) { stopped(true); return; }
        if (!lock || !running || failed) return;
        for (int ch = 0; ch < 2; ++ch) {
            audio.clear(ch, 0, frames);
            if (input) audio.copyFrom(ch, 0, input, juce::jmin(inputFrames, frames));
        }
        inputPeak = juce::jmax(inputPeak.load(), audio.getMagnitude(0, 0, frames));
        float* pointers[] = {audio.getWritePointer(0), audio.getWritePointer(1)};
        juce::AudioBuffer<float> view(pointers, 2, frames);
        for (auto& item : chain) if (!item.bypass) item.effect->processBlock(view, midi);
        if (wet) {
            int a, n, b, m;
            fifo.prepareToWrite(frames, a, n, b, m);
            if (n + m < frames) overflow = true;
            for (int i = 0; i < n + m; ++i) {
                const float value = 0.5f * (audio.getSample(0, i) + audio.getSample(1, i));
                const int16_t sample = int16_t(std::round((std::isfinite(value) ? juce::jlimit(-1.0f, 1.0f, value) : 0) * 32767));
                const int index = 2 * (i < n ? a + i : b + i - n);
                pcmData[index] = uint8_t(sample & 255);
                pcmData[index + 1] = uint8_t((sample >> 8) & 255);
            }
            fifo.finishedWrite(n + m);
        }
        float peak = 0;
        const float volume = gain;
        for (int i = 0; i < frames; ++i) for (int ch = 0; ch < 2; ++ch) {
            float value = audio.getSample(ch, i) * volume;
            if (!std::isfinite(value)) value = 0;
            peak = juce::jmax(peak, std::abs(value));
            output[i * 2 + ch] = juce::jlimit(-1.0f, 1.0f, value);
        }
        outputPeak = juce::jmax(outputPeak.load(), peak);
    }
    juce::var status() {
        juce::Array<juce::var> plugins, wetOnly;
        for (auto& item : chain) {
            plugins.add(object({{"name", item.effect->getName()}, {"kind", item.effect->kind},
                {"bypass", item.bypass}, {"parameters", item.effect->describeParameters()}}));
            if (!item.bypass && (item.effect->kind == "delay" || item.effect->kind == "reverb")
                && item.effect->getParameters()[2]->getValue() >= 0.99f) wetOnly.add(item.effect->getName());
        }
        auto result = deviceStatus();
        auto* state = result.getDynamicObject();
        auto fields = object({{"running", running.load()}, {"failed", failed.load()},
            {"inputPeak", inputPeak.exchange(0)}, {"outputPeak", outputPeak.exchange(0)},
            {"gain", gain.load()}, {"sampleRate", rate}, {"bufferSize", block.load()},
            {"blockMs", block.load() * 1000.0 / rate}, {"requestedBuffer", requestedBuffer},
            {"plugins", plugins}, {"wetOnly", wetOnly}, {"pluginLatencyMs", 0},
            {"mobile", true}, {"setupNotice", juce::String::fromUTF8("使用系统当前音频路由与系统单声道输入；设备变化后请手动重新开始。")}});
        for (const auto& pair : fields.getDynamicObject()->getProperties())
            state->setProperty(pair.name, pair.value);
        return result;
    }
    int requestedBuffer = 128;
    std::atomic<bool> running{false}, failed{false};
protected:
    double rate = 48000;
    std::atomic<int> block{128};
private:
    struct Item { std::unique_ptr<BuiltinEffect> effect; bool bypass; };
    std::vector<Item> chain;
    std::mutex mutex;
    juce::AudioBuffer<float> audio;
    juce::MidiBuffer midi;
    juce::AbstractFifo fifo{96001};
    std::array<uint8_t, 96001 * 2> pcmData{};
    std::atomic<bool> wet{false}, overflow{false};
    std::atomic<float> inputPeak{0}, outputPeak{0}, gain{0.5f};
};
}
