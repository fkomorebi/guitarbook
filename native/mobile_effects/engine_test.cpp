#include "engine.h"
#include "../effects_host/builtin_effect_tests.h"
#include <iostream>
#include <thread>

using namespace guitarbook;
class TestEngine final : public Engine {
public:
    void open() override { prepare(sampleRate, 128); }
    void close() override { stopped(failed); }
    juce::var deviceStatus() override { return object({{"audioOpen", running.load()}}); }
    double sampleRate = 48000;
};
void require(bool value, const char* message) { if (!value) throw juce::String(message); }
void rejects(TestEngine& engine, juce::var request) {
    bool rejected = false;
    try { engine.command(request); } catch (const juce::String&) { rejected = true; }
    require(rejected, "Expected command rejection");
}
int main() {
    try {
        testBuiltinDsp();
        TestEngine engine;
        std::array<float, 128> input{};
        std::array<float, 256> output{};
        input.fill(0.4f);
        rejects(engine, object({{"command", "loopStart"}}));
        engine.command(object({{"command", "probe"}}));
        require(!engine.running, "Probe left monitoring running");
        engine.command(object({{"command", "start"}}));
        engine.command(object({{"command", "gain"}, {"value", 0}}));
        engine.command(object({{"command", "loopStart"}}));
        engine.process(input.data(), 128, output.data(), 128);
        for (float value : output) require(value == 0, "Monitor gain not applied");
        const auto dry = engine.command(object({{"command", "loopRead"}}))["pcm"].toString();
        juce::MemoryOutputStream decoded;
        require(juce::Base64::convertFromBase64(decoded, dry) && decoded.getDataSize() == 256, "PCM size mismatch");
        auto* bytes = static_cast<const uint8_t*>(decoded.getData());
        require((bytes[0] | (bytes[1] << 8)) == 13107, "Wet tap followed monitor gain");
        engine.command(object({{"command", "builtin"}, {"kind", "overdrive"}}));
        engine.process(input.data(), 128, output.data(), 128);
        require(engine.command(object({{"command", "loopRead"}}))["pcm"].toString() != dry, "Effect missing from recording");
        engine.command(object({{"command", "bypass"}, {"index", 0}, {"value", true}}));
        engine.process(input.data(), 128, output.data(), 128);
        require(engine.command(object({{"command", "loopRead"}}))["pcm"].toString() == dry, "Bypass changed input");
        engine.command(object({{"command", "builtin"}, {"kind", "amp_modern"}}));
        engine.command(object({{"command", "parameter"}, {"index", 1}, {"parameter", 0}, {"value", 7.0}}));
        engine.command(object({{"command", "move"}, {"index", 0}, {"destination", 1}}));
        auto plugins = engine.status()["plugins"];
        require(plugins[0]["kind"].toString() == "amp_modern" && bool(plugins[1]["bypass"]), "Move lost instance state");
        require(float(plugins[0]["parameters"][0]["value"]) == 7, "Move lost parameters");
        for (int i = 0; i < 800; ++i) engine.process(input.data(), 128, output.data(), 128);
        rejects(engine, object({{"command", "loopRead"}}));
        engine.command(object({{"command", "loopStop"}}));
        require(engine.running, "Stopping tap stopped monitoring");
        engine.command(object({{"command", "loopStart"}}));
        require(engine.command(object({{"command", "loopRead"}}))["pcm"].toString().isEmpty(), "Tap restart retained old data");
        // Exercise realtime processing while the UI edits the chain and reads PCM.
        std::atomic<bool> render{true};
        std::thread audio([&] { while (render) engine.process(input.data(), 128, output.data(), 128); });
        for (int i = 0; i < 100; ++i) {
            engine.command(object({{"command", "parameter"}, {"index", 0}, {"parameter", 0}, {"value", double(i % 10)}}));
            engine.command(object({{"command", "builtin"}, {"kind", "delay"}}));
            engine.command(object({{"command", "remove"}, {"index", 2}}));
            engine.command(object({{"command", "loopStop"}}));
            engine.command(object({{"command", "loopStart"}}));
        }
        render = false;
        audio.join();
        engine.command(object({{"command", "stop"}}));
        rejects(engine, object({{"command", "loopRead"}}));
        engine.sampleRate = 44100;
        engine.command(object({{"command", "start"}}));
        rejects(engine, object({{"command", "loopStart"}}));
        for (int i = 2; i < 8; ++i) engine.command(object({{"command", "builtin"}, {"kind", "fuzz"}}));
        rejects(engine, object({{"command", "builtin"}, {"kind", "delay"}}));
        rejects(engine, object({{"command", "load"}, {"path", "/tmp/plugin.vst3"}}));
        rejects(engine, object({{"command", "move"}, {"index", 0}, {"destination", 8}}));
        std::cout << "Mobile chain, wet capture, lifecycle and concurrent edits passed\n";
        return 0;
    } catch (const juce::String& error) { std::cerr << error << '\n'; return 1; }
}
