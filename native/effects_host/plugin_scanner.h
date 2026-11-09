#pragma once

#include <juce_audio_utils/juce_audio_utils.h>

#include <vector>

// Scans the VST2/VST3 plugins that are installed on this machine.
//
// The scan never runs inside the message thread of the host: loading a broken
// third party plugin can crash the process, so the actual work happens in a
// child process that is started with "--scan <request file>". The child prints
// exactly one JSON line with the result and exits.
namespace PluginScanner {

/** One plugin of a scan result. */
struct PluginEntry {
    juce::String format;      // "vst3" or "vst2"
    juce::String name;
    juce::String vendor;
    juce::String version;
    juce::String category;
    juce::String path;         // absolute path of the plugin file or bundle
    bool isInstrument = false;
    bool loadable = false;     // true when this build can really load the plugin
    juce::String note;         // empty when there is nothing to report
};

/** The result of a scan; mirrors the JSON payload of the "scan" command. */
struct ScanResult {
    juce::String platform;
    bool vst2Supported = false;
    juce::StringArray directories;   // the directories that were really scanned
    std::vector<PluginEntry> plugins;
    juce::StringArray errors;
    juce::int64 durationMs = 0;

    /** Converts the result into the JSON payload of the "scan" command. */
    juce::var toVar() const;

    /** Reads a result back from the JSON payload of the "scan" command. */
    static ScanResult fromVar(const juce::var& value);
};

/** True when this build was compiled with VST2 (Steinberg SDK) support. */
bool vst2Supported();

/** Scans the default locations plus the given extra paths in this process. */
ScanResult scanInProcess(const juce::StringArray& extraPaths);

/** Scans by re-launching this executable in "--scan" mode. Never throws. */
ScanResult scanInChildProcess(const juce::StringArray& extraPaths);

/** Reads the "paths" field of a scan request (a string or an array of strings). */
juce::StringArray extractPaths(const juce::var& request);

}  // namespace PluginScanner
