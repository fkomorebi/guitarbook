#define JUCE_CORE_INCLUDE_JNI_HELPERS 1
#include "engine.h"
#include <oboe/Oboe.h>
#include <oboe/FullDuplexStream.h>
#include <jni.h>

class AndroidEngine final : public guitarbook::Engine, public oboe::FullDuplexStream,
                            public oboe::AudioStreamErrorCallback {
public:
    ~AndroidEngine() override { close(); }
    void check(oboe::Result result) {
        if (result != oboe::Result::OK) throw juce::String::fromUTF8("音频设备打开失败：") + oboe::convertToText(result);
    }
    void open() override {
        oboe::AudioStreamBuilder builder;
        builder.setDirection(oboe::Direction::Output)
            ->setFormat(oboe::AudioFormat::Float)
            ->setChannelCount(2)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Shared)
            ->setUsage(oboe::Usage::Media)
            ->setDataCallback(this)
            ->setErrorCallback(this);
        check(builder.openStream(output));
        oboe::AudioStreamBuilder inputBuilder;
        inputBuilder.setDirection(oboe::Direction::Input)
            ->setFormat(oboe::AudioFormat::Float)
            ->setFormatConversionAllowed(true)
            ->setChannelCount(1)
            ->setChannelConversionAllowed(true)
            ->setSampleRate(output->getSampleRate())
            ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Shared)
            ->setInputPreset(oboe::InputPreset::Unprocessed);
        check(inputBuilder.openStream(input));
        const auto size = output->setBufferSizeInFrames(requestedBuffer);
        if (!size) check(size.error());
        prepare(output->getSampleRate(), output->getFramesPerBurst());
        setInputStream(input.get());
        setOutputStream(output.get());
        check(oboe::FullDuplexStream::start());
    }
    void close() override {
        stopped(failed);
        // Close the output first: its callback is the only reader of input.
        if (output) { output->requestStop(); output->close(); }
        if (input) { input->requestStop(); input->close(); }
        setOutputStream(nullptr);
        setInputStream(nullptr);
        output.reset();
        input.reset();
    }
    bool onError(oboe::AudioStream*, oboe::Result) override {
        // Let the UI/lifecycle owner close both streams; no automatic restart.
        stopped(true);
        return true;
    }
    oboe::DataCallbackResult onBothStreamsReady(const void* in, int inFrames, void* out, int frames) override {
        process(static_cast<const float*>(in), inFrames, static_cast<float*>(out), frames);
        return running ? oboe::DataCallbackResult::Continue : oboe::DataCallbackResult::Stop;
    }
    oboe::ResultWithValue<int32_t> readInput(int32_t frames) override {
        auto result = oboe::FullDuplexStream::readInput(frames);
        if (!result) stopped(true);
        return result;
    }
    juce::var deviceStatus() override {
        if (failed && output) close();
        int xruns = -1;
        if (output && !failed) {
            auto count = output->getXRunCount();
            if (count) xruns = count.value();
        }
        return guitarbook::object({{"audioOpen", output != nullptr && !failed},
            {"backend", "Oboe"}, {"device", "Android system route"},
            {"inputDevice", input ? juce::String(input->getDeviceId()) : juce::String()},
            {"outputDevice", output ? juce::String(output->getDeviceId()) : juce::String()},
            {"xruns", xruns}, {"latencyAvailable", false}, {"cpuAvailable", false},
            {"outputBufferFrames", output ? output->getBufferSizeInFrames() : 0}});
    }
private:
    std::shared_ptr<oboe::AudioStream> input, output;
};

extern "C" JNIEXPORT jlong JNICALL
Java_com_komorebi_guitarbook_EffectsChannel_nativeCreate(JNIEnv* env, jobject, jobject context) {
    // Match JUCE's Java bootstrap: class/method bindings must exist before
    // Thread::initialiseJUCE constructs its application lifecycle watcher.
    static std::once_flag initialised;
    std::call_once(initialised, [&] {
        juce::JNIClassBase::initialiseAllClasses(env, context);
        juce::Thread::initialiseJUCE(env, context);
    });
    return reinterpret_cast<jlong>(new AndroidEngine());
}
extern "C" JNIEXPORT jstring JNICALL
Java_com_komorebi_guitarbook_EffectsChannel_nativeCommand(JNIEnv* env, jobject, jlong handle, jstring json) {
    const char* chars = env->GetStringUTFChars(json, nullptr);
    const auto request = juce::String::fromUTF8(chars);
    env->ReleaseStringUTFChars(json, chars);
    auto response = reinterpret_cast<AndroidEngine*>(handle)->dispatch(request);
    // NewStringUTF uses modified UTF-8, while JUCE produces standard UTF-8.
    const auto utf16 = response.toUTF16();
    return env->NewString(reinterpret_cast<const jchar*>(utf16.getAddress()), response.length());
}
extern "C" JNIEXPORT void JNICALL
Java_com_komorebi_guitarbook_EffectsChannel_nativeDispose(JNIEnv*, jobject, jlong handle) {
    delete reinterpret_cast<AndroidEngine*>(handle);
}
