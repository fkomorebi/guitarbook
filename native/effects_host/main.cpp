#include <juce_audio_utils/juce_audio_utils.h>
#include <array>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>
#include "builtin_effect.h"
#include "builtin_effect_tests.h"
#include "plugin_scanner.h"

using namespace juce;

static var object(std::initializer_list<std::pair<Identifier, var>> fields) {
    auto* result = new DynamicObject();
    for (const auto& field : fields) result->setProperty(field.first, field.second);
    return var(result);
}

// The answers are written from the message thread and from the plugin scan,
// so the protocol output has to be serialised.
static std::mutex outputMutex;

static void writeResponse(const var& response) {
    const auto text = JSON::toString(response, true);
    std::lock_guard<std::mutex> lock(outputMutex);
    std::cout << text << std::endl;
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
    Host() {
        formats.addFormat(std::make_unique<VST3PluginFormat>());
#if GUITARBOOK_VST2_ENABLED
        // The VST2 SDK is optional, so this format only exists in the builds
        // that were configured with GUITARBOOK_ENABLE_VST2.
        formats.addFormat(std::make_unique<VSTPluginFormat>());
#endif
    }
    ~Host() override {
        enabled = false;
        devices.removeAudioCallback(this);
        devices.closeAudioDevice();
        settings.reset();
        chain.clear();
        for (auto& worker : scanWorkers)
            if (worker.joinable()) worker.join();
    }

    // Picks the plugin format by file extension: .vst3 is always available,
    // .dll needs a build that was compiled with the VST2 SDK.
    AudioPluginFormat* formatForExtension(const String& extension) {
        for (int index = 0; index < formats.getNumFormats(); ++index) {
            auto* format = formats.getFormat(index);
            if (extension == ".vst3" && format->getName() == "VST3") return format;
            if (extension == ".dll" && format->getName() == "VST") return format;
        }
        return nullptr;
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
            // The user may install a driver in the window, so rescan on open.
            deviceBackendsScanned = false;
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
            // Never inherit silence measured before this session: the device
            // may just have been re-opened, and the first blocks after a
            // (re)connect can arrive empty while the converter settles.
            inputPeak = outputPeak = 0;
            silentBlocks = 0;
            failed = false;
            enabled = true;
            monitorRequested = true;
        } else if (action == "stop") {
            enabled = false;
            monitorRequested = false;
            devices.closeAudioDevice();
            inputPeak = outputPeak = 0;
            silentBlocks = 0;
        } else if (action == "reopen") {
            // Force a fresh device open: recovers a capture that went silent
            // after the interface was re-enumerated, renamed or unplugged.
            const bool resume = enabled;
            enabled = false;
            devices.closeAudioDevice();
            silentBlocks = 0;
            ensureDevice();
            failed = false;
            enabled = resume;
        } else if (action == "inputChannel") {
            // Pick the input channel that carries the instrument: "auto" follows
            // the loudest channel, a fixed index keeps that one.
            if (request["auto"].isBool() && static_cast<bool>(request["auto"])) {
                monitoredChannel = -1;
            } else {
                const int index = request["index"];
                if (index < 0 || index >= maxMonitoredInputs)
                    throw String::fromUTF8("无效的输入通道。");
                monitoredChannel = index;
            }
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
            const auto extension = file.getFileExtension().toLowerCase();
            auto* format = formatForExtension(extension);
            if (format == nullptr)
                throw String::fromUTF8(extension == ".dll"
                    ? "当前构建未启用 VST2 加载（需要 Steinberg VST2 SDK），请改用 .vst3 插件。"
                    : "请输入本平台 .vst3 文件或插件包的绝对路径。");
            if (!file.exists()) throw String::fromUTF8("请输入本平台 .vst3 文件或插件包的绝对路径。");
            OwnedArray<PluginDescription> descriptions;
            format->findAllTypesForFile(descriptions, file.getFullPathName());
            if (descriptions.isEmpty())
                throw String::fromUTF8("没有找到兼容的 ") + format->getName() + String::fromUTF8(" 插件，请检查平台与 CPU 架构。");
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

    // The plugin scan loads third party modules in a child process, so it may
    // take a while. It is started here and the answer is sent as soon as the
    // scan is done, the message thread stays free in the meantime.
    void scanAsync(const var& request) {
        const auto id = request["id"];
        const auto paths = PluginScanner::extractPaths(request);
        pendingScans.fetch_add(1);
        auto worker = std::thread([this, id, paths] {
            const auto result = PluginScanner::scanInChildProcess(paths);
            MessageManager::callAsync([this, id, result] {
                writeResponse(object({{"id", id}, {"result", result.toVar()}}));
                pendingScans.fetch_sub(1);
                if (inputFinished.load() && pendingScans.load() == 0)
                    MessageManager::getInstance()->stopDispatchLoop();
            });
        });
        std::lock_guard<std::mutex> lock(scanWorkerLock);
        scanWorkers.push_back(std::move(worker));
    }

    // The answer of a scan is sent after the command line was read, so the
    // message loop has to stay alive until the running scans are done.
    void inputEnded() {
        inputFinished = true;
        MessageManager::callAsync([this] {
            if (pendingScans.load() == 0) MessageManager::getInstance()->stopDispatchLoop();
        });
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

    // The device selector only offers ASIO when the host was compiled with
    // JUCE_ASIO=1, so report the available backends and the ASIO drivers that
    // were found. Scanning the drivers walks the registry, so the result is
    // cached and refreshed whenever the device window is opened.
    struct DeviceBackends {
        Array<var> types;
        Array<var> asioDrivers;
    };

    DeviceBackends deviceBackends() {
        if (!deviceBackendsScanned) {
            deviceBackendsCache.types.clear();
            deviceBackendsCache.asioDrivers.clear();
            for (auto* type : devices.getAvailableDeviceTypes()) {
                if (type == nullptr) continue;
                deviceBackendsCache.types.add(type->getTypeName());
                if (type->getTypeName() == "ASIO") {
                    type->scanForDevices();
                    for (const auto& name : type->getDeviceNames(false))
                        deviceBackendsCache.asioDrivers.add(name);
                }
            }
            deviceBackendsScanned = true;
        }
        return deviceBackendsCache;
    }

    var status() {
        // The user may have switched device or driver in the settings window.
        widenInputChannels();
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
        // A device that vanished or errored is reopened in the background so the
        // user does not have to restart monitoring by hand. Only live monitoring
        // (started through "start" on a real device) may recover this way.
        if (enabled && monitorRequested && initialised
            && (devices.getCurrentAudioDevice() == nullptr || failed.load()))
            tryRecoverDevice();
        auto* device = devices.getCurrentAudioDevice();
        bool running = enabled && device != nullptr && !failed;
        double currentRate = device ? device->getCurrentSampleRate() : rate;
        const auto setup = devices.getAudioDeviceSetup();
        const double blockMs = device ? 1000.0 * device->getCurrentBufferSizeSamples() / currentRate : 0.0;
        return object({{"audioOpen", device != nullptr}, {"backend", devices.getCurrentAudioDeviceType()},
            {"deviceTypes", var(deviceBackends().types)},
            {"asioDrivers", var(deviceBackends().asioDrivers)},
            {"inputDevice", setup.inputDeviceName}, {"outputDevice", setup.outputDeviceName},
            {"requestedBuffer", requestedBuffer}, {"setupNotice", setupNotice},
            {"pipewireQuantum", String::fromUTF8(std::getenv("PIPEWIRE_QUANTUM") ? std::getenv("PIPEWIRE_QUANTUM") : "")},
            {"inputLatencyMs", device ? 1000.0 * device->getInputLatencyInSamples() / currentRate : 0.0},
            {"outputLatencyMs", device ? 1000.0 * device->getOutputLatencyInSamples() / currentRate : 0.0},
            {"pluginLatencyMs", 1000.0 * latency / currentRate},
            {"blockMs", blockMs},
            {"xruns", devices.getXRunCount()}, {"wetOnly", wetOnly},
            {"running", running}, {"failed", failed.load()},
            {"inputPeak", inputPeak.exchange(0)}, {"outputPeak", outputPeak.exchange(0)},
            {"gain", gain.load()}, {"sampleRate", currentRate},
            {"bufferSize", device ? device->getCurrentBufferSizeSamples() : block},
            {"device", device ? device->getName() : String()},
            {"inputChannels", device ? device->getActiveInputChannels().countNumberOfSetBits() : 0},
            {"inputChannelNames", var(inputChannelNames())},
            {"inputChannelLevels", var(inputChannelLevels())},
            {"activeInputChannel", activeChannel.load()},
            {"autoInputChannel", monitoredChannel.load() < 0},
            {"outputChannels", device ? device->getActiveOutputChannels().countNumberOfSetBits() : 0},
            // 3 s of continuous digital silence: long enough that a freshly
            // (re)opened device is not flagged before it delivers audio.
            {"noInputSignal", running && blockMs > 0.0 && silentBlocks.load() * blockMs >= 3000.0},
            {"latencyMs", device ? 1000.0 * (device->getInputLatencyInSamples()
                + device->getOutputLatencyInSamples() + latency) / currentRate : 0.0},
            {"cpu", devices.getCpuUsage()}, {"vst2Supported", PluginScanner::vst2Supported()},
            {"plugins", plugins}});
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
        // A new device session (re-open, re-enumeration, settings change) must
        // not be reported as dead capture before it delivered its first block.
        silentBlocks = 0;
        inputPeak = outputPeak = 0;
    }
    void audioDeviceStopped() override {
        wetActive = false;
        inputPeak = outputPeak = 0;
        // `enabled` is kept on purpose: swapping the device inside the settings
        // window must not end monitoring, and `running` already requires an
        // open device.
    }
    void audioDeviceError(const String&) override { wetActive = false; failed = true; }

    void audioDeviceIOCallbackWithContext(const float* const* inputs, int numInputs,
        float* const* outputs, int numOutputs, int samples, const AudioIODeviceCallbackContext&) override {
        for (int ch = 0; ch < numOutputs; ++ch)
            if (outputs[ch]) FloatVectorOperations::clear(outputs[ch], samples);
        const ScopedTryLock lock(chainLock);
        if (!lock.isLocked() || !enabled || failed || samples > buffer.getNumSamples()) return;
        // The instrument is usually plugged into another input than the
        // interface's first one, so every opened channel is measured and the
        // one carrying the signal is monitored.
        for (int ch = 0; ch < numInputs && ch < maxMonitoredInputs; ++ch) {
            if (inputs[ch] == nullptr) continue;
            float channelPeak = 0.0f;
            for (int i = 0; i < samples; ++i)
                channelPeak = jmax(channelPeak, std::abs(inputs[ch][i]));
            auto& hold = channelPeaks[static_cast<size_t>(ch)];
            hold.store(jmax(hold.load() * 0.995f, channelPeak));
        }
        const int requested = monitoredChannel.load();
        const int channel = requested >= 0 && requested < numInputs
            ? requested
            : loudestChannel(numInputs);
        activeChannel = channel;
        const float* input = (channel >= 0 && channel < numInputs) ? inputs[channel] : nullptr;
        for (int ch = 0; ch < 2; ++ch) {
            if (input) buffer.copyFrom(ch, 0, input, samples);
            else buffer.clear(ch, 0, samples);
        }
        const auto magnitude = buffer.getMagnitude(0, 0, samples);
        inputPeak = jmax(inputPeak.load(), magnitude);
        // Only *digital* silence means the capture stream carries no audio at
        // all (system default input is a loopback/monitor node, wrong node,
        // dead stream). A real converter input always keeps a noise floor well
        // above zero even when nothing is played, so quiet passages and the
        // pauses between notes must not count as a broken input.
        if (magnitude > 0.0f) silentBlocks = 0;
        else if (silentBlocks.load() < 1000000) silentBlocks += 1;
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
    // The default setup only opens the interface's first input, but the
    // instrument usually sits on another one. A few channels are opened so the
    // host can measure them and monitor the one that carries the signal.
    void widenInputChannels() {
        auto* device = devices.getCurrentAudioDevice();
        if (device == nullptr) return;
        const auto setup = devices.getAudioDeviceSetup();
        const auto key = devices.getCurrentAudioDeviceType() + "|" + setup.inputDeviceName
            + "|" + setup.outputDeviceName;
        // A driver that refuses the wider layout must not be retried forever.
        if (key == widenedKey) return;
        widenedKey = key;
        const int available = device->getInputChannelNames().size();
        if (available <= 1) return;
        for (int wanted : {jmin(available, 8), jmin(available, 4), 2}) {
            if (wanted <= 1) break;
            auto wider = setup;
            wider.useDefaultInputChannels = false;
            wider.inputChannels.clear();
            wider.inputChannels.setRange(0, wanted, true);
            if (devices.setAudioDeviceSetup(wider, true).isEmpty()) return;
            // The driver rejected this width: restore what it does accept.
            devices.setAudioDeviceSetup(setup, true);
        }
    }
    // The channel with the strongest signal. The current one is kept while it
    // stays clearly louder, so the monitor does not jump between inputs
    // between two notes.
    int loudestChannel(int numInputs) const {
        int best = -1;
        float bestLevel = 0.0f;
        for (int ch = 0; ch < numInputs && ch < maxMonitoredInputs; ++ch) {
            const auto level = channelPeaks[static_cast<size_t>(ch)].load();
            if (level > bestLevel) { bestLevel = level; best = ch; }
        }
        const int current = activeChannel.load();
        if (current >= 0 && current < numInputs) {
            const auto level = channelPeaks[static_cast<size_t>(current)].load();
            if (level > 0.0f && level * 1.5f > bestLevel) return current;
        }
        return best;
    }
    // The opened input channels and their levels, reported in the same order.
    Array<var> inputChannelNames() const {
        Array<var> names;
        auto* device = devices.getCurrentAudioDevice();
        if (device == nullptr) return names;
        const auto available = device->getInputChannelNames();
        const auto active = device->getActiveInputChannels();
        for (int ch = 0; ch < available.size() && ch < maxMonitoredInputs; ++ch)
            if (active[ch]) names.add(available[ch]);
        return names;
    }
    Array<var> inputChannelLevels() const {
        Array<var> levels;
        auto* device = devices.getCurrentAudioDevice();
        const auto active = device == nullptr ? BigInteger(0) : device->getActiveInputChannels();
        for (int ch = 0; ch < maxMonitoredInputs; ++ch)
            if (active[ch]) levels.add(static_cast<double>(channelPeaks[static_cast<size_t>(ch)].load()));
        return levels;
    }
    void ensureDevice() {
        if (devices.getCurrentAudioDevice() != nullptr) return;
        if (initialised) {
            // The saved device may have disappeared (USB interface re-enumerated,
            // renamed or unplugged); reopening it can silently fail, so fall back
            // to a fresh initialisation when it does not come back.
            devices.restartLastAudioDevice();
            if (devices.getCurrentAudioDevice() != nullptr) return;
            devices.closeAudioDevice();
            initialised = false;
        }
        if (callbackAdded) {
            devices.removeAudioCallback(this);
            callbackAdded = false;
        }
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
        callbackAdded = true;
        initialised = true;
        if (devices.getCurrentAudioDevice() == nullptr) throw String::fromUTF8("无法打开声卡，请检查设备与系统音频设置。");
        widenInputChannels();
    }
    void tryRecoverDevice() {
        const auto now = juce::Time::getHighResolutionTicks();
        if (lastRecoveryAttempt != 0) {
            const auto elapsedMs = (now - lastRecoveryAttempt) * 1000
                / juce::Time::getHighResolutionTicksPerSecond();
            if (elapsedMs < 2000) return;
        }
        lastRecoveryAttempt = now;
        if (devices.getCurrentAudioDevice() != nullptr) devices.closeAudioDevice();
        try {
            ensureDevice();
            failed = false;
        } catch (...) {
            failed = true;
        }
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
    DeviceBackends deviceBackendsCache;
    bool deviceBackendsScanned = false;
    bool initialised = false;
    bool callbackAdded = false;
    bool monitorRequested = false;
    juce::int64 lastRecoveryAttempt = 0;
    // Consecutive blocks of exact digital silence; see audioDeviceIOCallback.
    std::atomic<int> silentBlocks{0};
    std::atomic<bool> enabled{false}, failed{false};
    std::atomic<float> inputPeak{0}, outputPeak{0}, gain{0.5f};
    // The plugin scans run outside the message thread and are joined when the
    // host shuts down.
    std::mutex scanWorkerLock;
    std::vector<std::thread> scanWorkers;
    // The number of scans that still have to be answered and the state of the
    // command line, they keep the message loop alive.
    std::atomic<int> pendingScans{0};
    std::atomic<bool> inputFinished{false};
    // Instrument inputs: the guitar is usually not on the interface's first
    // input, so a few channels are opened and measured.
    static constexpr int maxMonitoredInputs = 8;
    std::atomic<int> monitoredChannel{-1};   // -1 = follow the loudest channel
    std::atomic<int> activeChannel{-1};
    std::array<std::atomic<float>, maxMonitoredInputs> channelPeaks{};
    String widenedKey;
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
    if (argc == 3 && String(argv[1]) == "--scan") {
        // Scan child process: the parent starts this executable to read the
        // plugin metadata in a separate process, so a broken plugin module
        // cannot take the host down. The result is one JSON line.
        try {
            const auto request = JSON::parse(File(String::fromUTF8(argv[2])).loadFileAsString());
            const auto result = PluginScanner::scanInProcess(PluginScanner::extractPaths(request));
            writeResponse(result.toVar());
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what() << std::endl;
            return 1;
        }
    }
    std::thread reader([&host] {
        std::string line;
        while (std::getline(std::cin, line)) {
            auto request = JSON::parse(String::fromUTF8(line.c_str()));
            if (request["command"].toString() == "scan") {
                // The answer is sent later, the scan must not block the
                // message thread.
                host.scanAsync(request);
                continue;
            }
            MessageManager::callAsync([&host, request] {
                var response;
                try { response = object({{"id", request["id"]}, {"result", host.command(request)}}); }
                catch (const String& error) { response = object({{"id", request["id"]}, {"error", error}}); }
                catch (const std::exception& error) { response = object({{"id", request["id"]}, {"error", String(error.what())}}); }
                writeResponse(response);
            });
        }
        host.inputEnded();
    });
    MessageManager::getInstance()->runDispatchLoop();
    reader.join();
    return 0;
}
