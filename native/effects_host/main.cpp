#include <juce_audio_utils/juce_audio_utils.h>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>
#include "builtin_effect.h"
#include "builtin_effect_tests.h"

using namespace juce;

static var object(std::initializer_list<std::pair<Identifier, var>> fields) {
    auto* result = new DynamicObject();
    for (const auto& field : fields) result->setProperty(field.first, field.second);
    return var(result);
}

class EditorWindow final : public DocumentWindow {
public:
    EditorWindow(String title, Component* content)
        : DocumentWindow(title, Colours::darkgrey, DocumentWindow::closeButton) {
        setUsingNativeTitleBar(true);
        setContentOwned(content, true);
        centreWithSize(getWidth(), getHeight());
        setVisible(true);
    }
    void closeButtonPressed() override { setVisible(false); }
};

class Host final : public AudioIODeviceCallback {
public:
    Host() { formats.addFormat(std::make_unique<VST3PluginFormat>()); }
    ~Host() override {
        enabled = false;
        devices.removeAudioCallback(this);
        devices.closeAudioDevice();
        settings.reset();
        chain.clear();
    }

    var command(const var& request) {
        auto action = request["command"].toString();
        if (action == "loopStart") {
            const ScopedLock lock(chainLock);
            if (!enabled || failed) throw String::fromUTF8("请先在下方效果器中开始监听，再录音。");
            if (std::abs(rate - 48000.0) > 0.1)
                throw String::fromUTF8("效果器湿声录音需要 48 kHz，请停止监听并在声卡设置中选择 48000 Hz。");
            wetActive = false;
            wetFifo.reset();
            wetOverflow = false;
            wetActive = true;
            return object({{"sampleRate", 48000}});
        } else if (action == "loopStop") {
            const ScopedLock lock(chainLock);
            wetActive = false;
            wetFifo.reset();
            return object({});
        } else if (action == "loopRead") {
            if (!wetActive || !enabled || failed)
                throw String::fromUTF8("效果器监听已停止，请重新开始监听和录音。");
            if (wetOverflow) throw String::fromUTF8("湿声采集缓冲溢出，请停止后重新录音。");
            MemoryBlock pcm;
            int start1, size1, start2, size2;
            wetFifo.prepareToRead(wetFifo.getNumReady(), start1, size1, start2, size2);
            pcm.append(wetSamples.data() + start1 * 2, static_cast<size_t>(size1 * 2));
            pcm.append(wetSamples.data() + start2 * 2, static_cast<size_t>(size2 * 2));
            wetFifo.finishedRead(size1 + size2);
            return object({{"pcm", Base64::toBase64(pcm.getData(), pcm.getSize())}});
        } else if (action == "probe") {
            // Open with monitoring disabled, then release the device even on failure.
            if (enabled) return status();
            try {
                ensureDevice();
                auto* device = devices.getCurrentAudioDevice();
                if (device == nullptr || device->getActiveInputChannels().isZero()
                    || device->getActiveOutputChannels().countNumberOfSetBits() < 2)
                    throw String::fromUTF8("需要有效的音频输入和立体声输出，请检查声卡与系统权限。");
                auto result = status();
                devices.closeAudioDevice();
                result.getDynamicObject()->setProperty("audioOpen", false);
                result.getDynamicObject()->setProperty("available", true);
                return result;
            } catch (...) {
                devices.closeAudioDevice();
                throw;
            }
        } else if (action == "settings") {
            ensureDevice();
            if (!settings) {
                settings = std::make_unique<EditorWindow>(String::fromUTF8("Audio devices / 输入输出设备"),
                    new AudioDeviceSelectorComponent(devices, 1, 1, 2, 2, false, false, false, false));
                settings->setSize(560, 540);
            }
            settings->setVisible(true);
            settings->toFront(true);
        } else if (action == "audioBuffer") {
            if (enabled) throw String::fromUTF8("请先停止监听，再调整缓冲。");
            const int frames = request["frames"];
            if (frames != 64 && frames != 128 && frames != 256 && frames != 512)
                throw String::fromUTF8("缓冲仅支持 64、128、256 或 512 帧。");
            ensureDevice();
            auto* device = devices.getCurrentAudioDevice();
            if (device == nullptr || !device->getAvailableBufferSizes().contains(frames))
                throw String::fromUTF8("当前后端不支持此缓冲，请在声卡设置中选择可用值。");
            const int previous = requestedBuffer;
            const auto oldSetup = devices.getAudioDeviceSetup();
            auto setup = oldSetup;
            setup.bufferSize = frames;
            requestedBuffer = frames;
            prepareAudioEnvironment();
            auto error = devices.setAudioDeviceSetup(setup, true);
            if (error.isNotEmpty()) {
                requestedBuffer = previous;
                prepareAudioEnvironment();
                devices.setAudioDeviceSetup(oldSetup, true);
                throw error;
            }
            setupNotice.clear();
        } else if (action == "start") {
            ensureDevice();
            auto* device = devices.getCurrentAudioDevice();
            if (device == nullptr || device->getActiveInputChannels().isZero()
                || device->getActiveOutputChannels().isZero())
                throw String::fromUTF8("请选择有效的音频输入和输出设备。");
            failed = false;
            enabled = true;
        } else if (action == "stop") {
            enabled = false;
            devices.closeAudioDevice();
            inputPeak = outputPeak = 0;
        } else if (action == "builtin") {
            if (chain.size() >= 8) throw String::fromUTF8("最多添加 8 个效果器。");
            auto plugin = std::make_unique<BuiltinEffect>(request["kind"].toString());
            plugin->setRateAndBufferSizeDetails(rate, block);
            plugin->prepareToPlay(rate, block);
            const ScopedLock lock(chainLock);
            chain.push_back({std::move(plugin), nullptr, false});
        } else if (action == "parameter") {
            int index = request["index"];
            if (index < 0 || index >= static_cast<int>(chain.size())) throw String::fromUTF8("效果器已不存在。");
            auto* builtin = dynamic_cast<BuiltinEffect*>(chain[static_cast<size_t>(index)].plugin.get());
            if (builtin == nullptr) throw String::fromUTF8("请在 VST3 参数窗口调节此插件。");
            builtin->setParameterValue(static_cast<int>(request["parameter"]), static_cast<float>(request["value"]));
        } else if (action == "load") {
            if (chain.size() >= 8) throw String::fromUTF8("第一版最多加载 8 个效果器。");
            auto path = request["path"].toString();
            if (!File::isAbsolutePath(path)) throw String::fromUTF8("请输入插件的绝对路径。");
            File file(path);
            if (!file.exists() || !file.hasFileExtension("vst3"))
                throw String::fromUTF8("请输入本平台 .vst3 文件或插件包的绝对路径。");
            OwnedArray<PluginDescription> descriptions;
            formats.getFormat(0)->findAllTypesForFile(descriptions, file.getFullPathName());
            if (descriptions.isEmpty()) throw String::fromUTF8("没有找到兼容的 VST3 插件，请检查平台与 CPU 架构。");
            if (descriptions[0]->isInstrument) throw String::fromUTF8("第一版不支持虚拟乐器插件。");
            String error;
            auto plugin = formats.createPluginInstance(*descriptions[0], rate, block, error);
            if (!plugin) throw String::fromUTF8("加载失败：") + error;
            if (plugin->isMidiEffect() || plugin->getTotalNumInputChannels() == 0
                || plugin->getTotalNumOutputChannels() == 0
                || plugin->getBusCount(true) == 0 || plugin->getBusCount(false) == 0)
                throw String::fromUTF8("仅支持音频效果器，不支持乐器或 MIDI 插件。");
            plugin->disableNonMainBuses();
            auto layout = plugin->getBusesLayout();
            layout.inputBuses.getReference(0) = AudioChannelSet::stereo();
            layout.outputBuses.getReference(0) = AudioChannelSet::stereo();
            if (!plugin->setBusesLayout(layout)) {
                layout.inputBuses.getReference(0) = AudioChannelSet::mono();
                layout.outputBuses.getReference(0) = AudioChannelSet::mono();
                if (!plugin->setBusesLayout(layout))
                    throw String::fromUTF8("该插件不支持单声道或立体声音频效果链。");
            }
            plugin->setRateAndBufferSizeDetails(rate, block);
            plugin->prepareToPlay(rate, block);
            const ScopedLock lock(chainLock);
            chain.push_back({std::move(plugin), nullptr, false});
        } else if (action == "remove" || action == "bypass" || action == "move" || action == "editor") {
            int index = request["index"];
            if (index < 0 || index >= static_cast<int>(chain.size())) throw String::fromUTF8("效果器已不存在。");
            if (action == "editor") {
                auto& item = chain[static_cast<size_t>(index)];
                if (!item.editor) {
                    auto* editor = item.plugin->createEditorIfNeeded();
                    if (editor == nullptr) editor = new GenericAudioProcessorEditor(*item.plugin);
                    item.editor = std::make_unique<EditorWindow>(item.plugin->getName(), editor);
                }
                item.editor->setVisible(true);
                item.editor->toFront(true);
            } else {
                // Destroy removed plugin/editor after releasing the chain lock.
                Effect removed;
                const ScopedLock lock(chainLock);
                if (action == "remove") {
                    removed = std::move(chain[static_cast<size_t>(index)]);
                    chain.erase(chain.begin() + index);
                }
                else if (action == "bypass") chain[static_cast<size_t>(index)].bypass = static_cast<bool>(request["value"]);
                else {
                    int destination = request["destination"];
                    if (destination < 0 || destination >= static_cast<int>(chain.size())) throw String::fromUTF8("无效排序位置。");
                    auto moved = std::move(chain[static_cast<size_t>(index)]);
                    chain.erase(chain.begin() + index);
                    chain.insert(chain.begin() + destination, std::move(moved));
                }
            }
        } else if (action == "gain") {
            gain = jlimit(0.0f, 1.0f, static_cast<float>(request["value"]));
        } else if (action != "status") {
            throw String::fromUTF8("未知宿主命令。");
        }
        return status();
    }

    // Offline integration mode never opens a sound device.
    void test(const String& path) {
        command(object({{"command", "load"}, {"path", path}}));
        buffer.setSize(2, block);
        std::vector<float> input(static_cast<size_t>(block), 1.0f);
        std::vector<float> left(static_cast<size_t>(block)), right(static_cast<size_t>(block));
        const float* inputs[] = {nullptr, input.data()};
        float* outputs[] = {nullptr, left.data(), right.data()};
        auto check = [&](float expected) {
            enabled = true;
            audioDeviceIOCallbackWithContext(inputs, 2, outputs, 3, block, {});
            for (int i = 0; i < block; ++i)
                if (std::abs(left[static_cast<size_t>(i)] - expected) > 0.00001f
                    || std::abs(right[static_cast<size_t>(i)] - expected) > 0.00001f)
                    throw String("Offline DSP mismatch");
        };
        check(0.125f);
        command(object({{"command", "bypass"}, {"index", 0}, {"value", true}}));
        check(0.5f);
        command(object({{"command", "bypass"}, {"index", 0}, {"value", false}}));
        command(object({{"command", "load"}, {"path", path}}));
        check(0.03125f);
        command(object({{"command", "move"}, {"index", 0}, {"destination", 1}}));
        check(0.03125f);
        command(object({{"command", "remove"}, {"index", 1}}));
        check(0.125f);
        enabled = false;
        audioDeviceIOCallbackWithContext(inputs, 2, outputs, 3, block, {});
        for (float sample : left) if (sample != 0) throw String("Stopped host produced audio");
        command(object({{"command", "remove"}, {"index", 0}}));
        check(0.5f);
        std::cout << "Offline VST3 integration passed" << std::endl;
    }

    void testBuiltinChain() {
        testBuiltinDsp();
        enabled = true; // Exercise structural commands while monitoring is enabled.
        // A non-adjacent move inserts the same instance and preserves intervening order.
        for (const auto* kind : {"amp_clean", "delay", "fuzz"})
            command(object({{"command", "builtin"}, {"kind", kind}}));
        auto* original = chain[0].plugin.get();
        auto* middle = chain[1].plugin.get();
        auto* last = chain[2].plugin.get();
        command(object({{"command", "parameter"}, {"index", 0}, {"parameter", 0}, {"value", 7.0}}));
        command(object({{"command", "bypass"}, {"index", 0}, {"value", true}}));
        command(object({{"command", "move"}, {"index", 0}, {"destination", 2}}));
        if (chain[0].plugin.get() != middle || chain[1].plugin.get() != last || chain[2].plugin.get() != original
            || !chain[2].bypass || dynamic_cast<BuiltinEffect*>(original)->getParameters()[0]->getValue() < 0.69f)
            throw String("Move did not preserve insertion order or instance state");
        command(object({{"command", "move"}, {"index", 2}, {"destination", 0}}));
        if (chain[0].plugin.get() != original || chain[1].plugin.get() != middle || chain[2].plugin.get() != last)
            throw String("Reverse insertion move failed");
        chain.clear();
        command(object({{"command", "builtin"}, {"kind", "compressor"}}));
        command(object({{"command", "builtin"}, {"kind", "fuzz"}}));
        auto render = [&] {
            for (auto& effect : chain) effect.plugin->prepareToPlay(rate, block);
            buffer.setSize(2, block);
            std::vector<float> input(static_cast<size_t>(block)), left(static_cast<size_t>(block)), right(static_cast<size_t>(block));
            const float* inputs[] = {input.data()};
            float* outputs[] = {left.data(), right.data()};
            enabled = true;
            for (int iteration = 0; iteration < 64; ++iteration) {
                for (int i = 0; i < block; ++i)
                    input[static_cast<size_t>(i)] = 0.5f * std::sin(static_cast<float>((iteration * block + i) * 2 * MathConstants<double>::pi * 220 / rate));
                audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, block, {});
            }
            double energy = 0;
            for (float sample : left) energy += sample * sample;
            return energy;
        };
        const double before = render();
        command(object({{"command", "move"}, {"index", 0}, {"destination", 1}}));
        const double after = render();
        if (std::abs(before - after) < 0.001) throw String("Chain reordering did not change processed audio");
        command(object({{"command", "remove"}, {"index", 1}}));
        command(object({{"command", "bypass"}, {"index", 0}, {"value", true}}));
        const double bypassed = render();
        command(object({{"command", "remove"}, {"index", 0}}));
        if (std::abs(render() - bypassed) > 0.0001) throw String("Bypass did not match the empty chain");
        if (!enabled) throw String("Live edits stopped monitoring");
        // Prove the tap captures processed audio independently of monitor gain.
        command(object({{"command", "loopStart"}}));
        buffer.setSize(2, block);
        std::vector<float> input(static_cast<size_t>(block), 0.4f);
        std::vector<float> left(static_cast<size_t>(block)), right(static_cast<size_t>(block));
        const float* inputs[] = {input.data()};
        float* outputs[] = {left.data(), right.data()};
        gain = 0;
        audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, block, {});
        auto captured = command(object({{"command", "loopRead"}}));
        MemoryOutputStream decoded;
        if (!Base64::convertFromBase64(decoded, captured["pcm"].toString())
            || decoded.getDataSize() != static_cast<size_t>(block * 2))
            throw String("Wet PCM size mismatch");
        const auto* pcm = static_cast<const uint8_t*>(decoded.getData());
        for (int i = 0; i < block; ++i) {
            const int value = pcm[i * 2] | (pcm[i * 2 + 1] << 8);
            if (value != 13107 || left[static_cast<size_t>(i)] != 0)
                throw String("Wet capture incorrectly follows monitor gain");
        }
        // A built-in effect must change the recorded samples too.
        command(object({{"command", "builtin"}, {"kind", "overdrive"}}));
        audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, block, {});
        auto processed = command(object({{"command", "loopRead"}}));
        if (processed["pcm"].toString() == captured["pcm"].toString())
            throw String("Wet capture did not include effect processing");
        for (int i = 0; i < 200; ++i)
            audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, block, {});
        bool overflowRejected = false;
        try { command(object({{"command", "loopRead"}})); }
        catch (const String&) { overflowRejected = true; }
        if (!overflowRejected) throw String("Wet overflow silently dropped samples");
        command(object({{"command", "loopStop"}}));
        command(object({{"command", "loopStart"}}));
        if (command(object({{"command", "loopRead"}}))["pcm"].toString().isNotEmpty())
            throw String("Wet restart retained stale audio");
        enabled = false;
        bool stoppedRejected = false;
        try { command(object({{"command", "loopRead"}})); }
        catch (const String&) { stoppedRejected = true; }
        if (!stoppedRejected) throw String("Wet read accepted stopped monitoring");
        std::cout << "Wet Looper capture tests passed" << std::endl;
        std::cout << "Editable built-in chain audio tests passed" << std::endl;
    }

    var status() {
        Array<var> plugins;
        int latency = 0;
        Array<var> wetOnly;
        for (auto& item : chain) {
            auto* builtin = dynamic_cast<BuiltinEffect*>(item.plugin.get());
            plugins.add(object({{"name", item.plugin->getName()}, {"bypass", item.bypass},
                {"kind", builtin ? builtin->kind : String("vst3")},
                {"parameters", builtin ? builtin->describeParameters() : var(Array<var>())}}));
            if (!item.bypass) {
                latency += item.plugin->getLatencySamples();
                if (builtin && (builtin->kind == "delay" || builtin->kind == "reverb")
                    && builtin->getParameters()[2]->getValue() >= 0.99f)
                    wetOnly.add(builtin->getName());
            }
        }
        auto* device = devices.getCurrentAudioDevice();
        bool running = enabled && device != nullptr && !failed;
        double currentRate = device ? device->getCurrentSampleRate() : rate;
        const auto setup = devices.getAudioDeviceSetup();
        return object({{"audioOpen", device != nullptr}, {"backend", devices.getCurrentAudioDeviceType()},
            {"inputDevice", setup.inputDeviceName}, {"outputDevice", setup.outputDeviceName},
            {"requestedBuffer", requestedBuffer}, {"setupNotice", setupNotice},
            {"pipewireQuantum", String::fromUTF8(std::getenv("PIPEWIRE_QUANTUM") ? std::getenv("PIPEWIRE_QUANTUM") : "")},
            {"inputLatencyMs", device ? 1000.0 * device->getInputLatencyInSamples() / currentRate : 0.0},
            {"outputLatencyMs", device ? 1000.0 * device->getOutputLatencyInSamples() / currentRate : 0.0},
            {"pluginLatencyMs", 1000.0 * latency / currentRate},
            {"blockMs", device ? 1000.0 * device->getCurrentBufferSizeSamples() / currentRate : 0.0},
            {"xruns", devices.getXRunCount()}, {"wetOnly", wetOnly},
            {"running", running}, {"failed", failed.load()},
            {"inputPeak", inputPeak.exchange(0)}, {"outputPeak", outputPeak.exchange(0)},
            {"gain", gain.load()}, {"sampleRate", currentRate},
            {"bufferSize", device ? device->getCurrentBufferSizeSamples() : block},
            {"device", device ? device->getName() : String()},
            {"latencyMs", device ? 1000.0 * (device->getInputLatencyInSamples()
                + device->getOutputLatencyInSamples() + latency) / currentRate : 0.0},
            {"cpu", devices.getCpuUsage()}, {"plugins", plugins}});
    }

    void audioDeviceAboutToStart(AudioIODevice* device) override {
        const ScopedLock lock(chainLock);
        wetActive = false;
        rate = device->getCurrentSampleRate();
        block = device->getCurrentBufferSizeSamples();
        buffer.setSize(2, block);
        for (auto& item : chain) {
            item.plugin->releaseResources();
            item.plugin->setRateAndBufferSizeDetails(rate, block);
            item.plugin->prepareToPlay(rate, block);
        }
        failed = false;
    }
    void audioDeviceStopped() override { wetActive = false; enabled = false; inputPeak = outputPeak = 0; }
    void audioDeviceError(const String&) override { wetActive = false; failed = true; enabled = false; }

    void audioDeviceIOCallbackWithContext(const float* const* inputs, int numInputs,
        float* const* outputs, int numOutputs, int samples, const AudioIODeviceCallbackContext&) override {
        for (int ch = 0; ch < numOutputs; ++ch)
            if (outputs[ch]) FloatVectorOperations::clear(outputs[ch], samples);
        const ScopedTryLock lock(chainLock);
        if (!lock.isLocked() || !enabled || failed || samples > buffer.getNumSamples()) return;
        // The device selector enables exactly one instrument input channel.
        const float* input = nullptr;
        for (int ch = 0; ch < numInputs; ++ch)
            if (inputs[ch] != nullptr) { input = inputs[ch]; break; }
        for (int ch = 0; ch < 2; ++ch) {
            if (input) buffer.copyFrom(ch, 0, input, samples);
            else buffer.clear(ch, 0, samples);
        }
        inputPeak = jmax(inputPeak.load(), buffer.getMagnitude(0, 0, samples));
        MidiBuffer midi;
        for (auto& item : chain) {
            if (item.bypass) continue;
            auto channels = item.plugin->getTotalNumOutputChannels();
            float* pointers[] = {buffer.getWritePointer(0), buffer.getWritePointer(1)};
            AudioBuffer<float> view(pointers, channels, samples);
            item.plugin->processBlock(view, midi);
            if (channels == 1) buffer.copyFrom(1, 0, buffer, 0, 0, samples);
            midi.clear();
        }
        if (wetActive) {
            int start1, size1, start2, size2;
            wetFifo.prepareToWrite(samples, start1, size1, start2, size2);
            if (size1 + size2 < samples) wetOverflow = true;
            const float* left = buffer.getReadPointer(0);
            const float* right = buffer.getReadPointer(1);
            for (int i = 0; i < size1 + size2; ++i) {
                const float mixed = left[i] * 0.5f + right[i] * 0.5f;
                const float value = std::isfinite(mixed) ? jlimit(-1.0f, 1.0f, mixed) : 0.0f;
                const auto sample = static_cast<int16_t>(std::round(value * 32767.0f));
                const int index = (i < size1 ? start1 + i : start2 + i - size1) * 2;
                wetSamples[static_cast<size_t>(index)] = static_cast<uint8_t>(sample & 0xff);
                wetSamples[static_cast<size_t>(index + 1)] = static_cast<uint8_t>((sample >> 8) & 0xff);
            }
            wetFifo.finishedWrite(size1 + size2);
        }
        float peak = 0;
        float volume = gain;
        int activeOutput = 0;
        for (int ch = 0; ch < numOutputs; ++ch) {
            if (!outputs[ch]) continue;
            const float* source = buffer.getReadPointer((activeOutput++) % 2);
            for (int i = 0; i < samples; ++i) {
                float value = source[i] * volume;
                if (!std::isfinite(value)) value = 0;
                peak = jmax(peak, std::abs(value));
                outputs[ch][i] = jlimit(-1.0f, 1.0f, value);
            }
        }
        outputPeak = jmax(outputPeak.load(), peak);
    }
private:
    void prepareAudioEnvironment() {
       #if JUCE_LINUX
        // pw_stream reads this at node creation. Its force request only lives
        // for the active node; never mutate persistent/server metadata settings.
        if (!externalPipewireQuantum) {
            const auto value = String(requestedBuffer) + "/48000";
            setenv("PIPEWIRE_QUANTUM", value.toRawUTF8(), 1);
        }
       #endif
    }
    void ensureDevice() {
        if (devices.getCurrentAudioDevice() != nullptr) return;
        if (!initialised) {
            String error;
           #if JUCE_LINUX
            const int original = requestedBuffer;
            for (int frames : {requestedBuffer, 256, 512}) {
                if (frames < original) continue;
                requestedBuffer = frames;
                prepareAudioEnvironment();
                AudioDeviceManager::AudioDeviceSetup preferred;
                preferred.sampleRate = 48000;
                preferred.bufferSize = frames;
                error = devices.initialise(1, 2, nullptr, true, {}, &preferred);
                if (error.isEmpty()) break;
                devices.closeAudioDevice();
            }
            if (error.isNotEmpty()) {
                requestedBuffer = original;
                prepareAudioEnvironment();
            }
            if (requestedBuffer != original && error.isEmpty())
                setupNotice = String::fromUTF8("低缓冲打开失败，已回退至 ") + String(requestedBuffer) + String::fromUTF8(" 帧。");
           #else
            error = devices.initialise(1, 2, nullptr, true);
           #endif
            if (error.isNotEmpty()) throw error;
            devices.addAudioCallback(this);
            initialised = true;
        } else devices.restartLastAudioDevice();
        if (devices.getCurrentAudioDevice() == nullptr) throw String::fromUTF8("无法打开声卡，请检查设备与系统音频设置。");
    }
    struct Effect {
        std::unique_ptr<AudioProcessor> plugin;
        std::unique_ptr<EditorWindow> editor;
        bool bypass;
    };
    AudioDeviceManager devices;
    AudioPluginFormatManager formats;
    CriticalSection chainLock;
    std::vector<Effect> chain;
    std::unique_ptr<EditorWindow> settings;
    // Single audio-thread producer / message-thread consumer, two seconds max.
    AbstractFifo wetFifo{96001};
    std::array<uint8_t, 96001 * 2> wetSamples{};
    std::atomic<bool> wetActive{false}, wetOverflow{false};
    AudioBuffer<float> buffer;
    double rate = 48000;
    int block = 512;
   #if JUCE_LINUX
    int requestedBuffer = 128;
   #else
    int requestedBuffer = 512;
   #endif
    const bool externalPipewireQuantum = std::getenv("PIPEWIRE_QUANTUM") != nullptr;
    String setupNotice;
    bool initialised = false;
    std::atomic<bool> enabled{false}, failed{false};
    std::atomic<float> inputPeak{0}, outputPeak{0}, gain{0.5f};
};

int main(int argc, char** argv) {
    ScopedJuceInitialiser_GUI gui;
    Host host;
    if (argc == 2 && String(argv[1]) == "--test-builtins") {
        try { host.testBuiltinChain(); return 0; }
        catch (const String& error) { std::cerr << error << std::endl; return 1; }
    }
    if (argc == 3 && String(argv[1]) == "--test") {
        try { host.test(String::fromUTF8(argv[2])); return 0; }
        catch (const String& error) { std::cerr << error << std::endl; return 1; }
    }
    std::thread reader([&host] {
        std::string line;
        while (std::getline(std::cin, line)) {
            auto request = JSON::parse(String::fromUTF8(line.c_str()));
            MessageManager::callAsync([&host, request] {
                var response;
                try { response = object({{"id", request["id"]}, {"result", host.command(request)}}); }
                catch (const String& error) { response = object({{"id", request["id"]}, {"error", error}}); }
                catch (const std::exception& error) { response = object({{"id", request["id"]}, {"error", String(error.what())}}); }
                std::cout << JSON::toString(response, true) << std::endl;
            });
        }
        MessageManager::callAsync([] { MessageManager::getInstance()->stopDispatchLoop(); });
    });
    MessageManager::getInstance()->runDispatchLoop();
    reader.join();
    return 0;
}
