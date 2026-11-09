#include "plugin_scanner.h"

#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>

#if JUCE_WINDOWS
#include <windows.h>
#endif

namespace PluginScanner {

using namespace juce;

namespace {

var makeObject(std::initializer_list<std::pair<Identifier, var>> fields) {
    auto* result = new DynamicObject();
    for (const auto& field : fields) result->setProperty(field.first, field.second);
    return var(result);
}

String currentPlatform() {
#if JUCE_WINDOWS
    return "windows";
#elif JUCE_MAC
    return "macos";
#else
    return "linux";
#endif
}

/** Paths are compared without case on Windows, but case sensitive elsewhere. */
bool samePath(const String& a, const String& b) {
#if JUCE_WINDOWS
    return a.equalsIgnoreCase(b);
#else
    return a == b;
#endif
}

void addUnique(StringArray& array, const String& value) {
    if (value.isEmpty()) return;
    for (const auto& item : array)
        if (samePath(item, value)) return;
    array.add(value);
}

/** The directories that are scanned by default, plus the extra module files. */
struct ScanPlan {
    StringArray vst3Directories;
    StringArray vst2Directories;
    StringArray vst3Files;   // single plugin files that were asked for explicitly
    StringArray vst2Files;
};

ScanPlan defaultPlan() {
    ScanPlan plan;
#if JUCE_WINDOWS
    const auto programFiles = SystemStats::getEnvironmentVariable("ProgramFiles", String());
    const auto programFilesX86 = SystemStats::getEnvironmentVariable("ProgramFiles(x86)", String());
    const auto localAppData = SystemStats::getEnvironmentVariable("LOCALAPPDATA", String());

    if (programFiles.isNotEmpty()) {
        const auto root = File(programFiles);
        addUnique(plan.vst3Directories, root.getChildFile("Common Files").getChildFile("VST3").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("Common Files").getChildFile("VST2").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("Steinberg").getChildFile("VSTPlugins").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("VSTPlugins").getFullPathName());
    }
    if (programFilesX86.isNotEmpty()) {
        const auto root = File(programFilesX86);
        addUnique(plan.vst3Directories, root.getChildFile("Common Files").getChildFile("VST3").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("Common Files").getChildFile("VST2").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("Steinberg").getChildFile("VSTPlugins").getFullPathName());
        addUnique(plan.vst2Directories, root.getChildFile("VSTPlugins").getFullPathName());
    }
    if (localAppData.isNotEmpty())
        addUnique(plan.vst3Directories,
                  File(localAppData).getChildFile("Programs").getChildFile("Common Files").getChildFile("VST3").getFullPathName());
#elif JUCE_MAC
    const auto home = File::getSpecialLocation(File::homeDirectory);
    addUnique(plan.vst3Directories, "/Library/Audio/Plug-Ins/VST3");
    addUnique(plan.vst3Directories, home.getChildFile("Library/Audio/Plug-Ins/VST3").getFullPathName());
    addUnique(plan.vst2Directories, "/Library/Audio/Plug-Ins/VST2");
    addUnique(plan.vst2Directories, home.getChildFile("Library/Audio/Plug-Ins/VST2").getFullPathName());
#else
    const auto home = File::getSpecialLocation(File::homeDirectory);
    addUnique(plan.vst3Directories, "/usr/lib/vst3");
    addUnique(plan.vst3Directories, "/usr/local/lib/vst3");
    addUnique(plan.vst3Directories, home.getChildFile(".vst3").getFullPathName());
    addUnique(plan.vst2Directories, "/usr/lib/vst2");
    addUnique(plan.vst2Directories, "/usr/local/lib/vst2");
    addUnique(plan.vst2Directories, home.getChildFile(".vst2").getFullPathName());
#endif
    return plan;
}

#if JUCE_WINDOWS

/** The version information of a Windows module. */
struct ModuleVersion {
    String productName, companyName, productVersion, fileVersion;
};

/**
    A single block of a VS_VERSIONINFO resource.

    The Windows function "VerQueryValue" cannot be used to read the version
    information of an arbitrary module: some modules declare a broken block
    length, which makes the function walk past the end of the buffer and loop
    forever. The resource is therefore parsed here directly, always staying
    inside the bytes of the resource.
*/
struct VersionBlock {
    const BYTE* key = nullptr;
    const BYTE* value = nullptr;
    size_t valueBytes = 0;
    const BYTE* children = nullptr;
    const BYTE* next = nullptr;
};

WORD readVersionWord(const BYTE* position) {
    return (WORD) (position[0] | ((WORD) position[1] << 8));
}

/** Reads one block of the resource, returning false when the block is broken. */
bool readVersionBlock(const BYTE* limit, const BYTE* offset, VersionBlock& block) {
    if (offset == nullptr || offset + 6 > limit)
        return false;

    const auto length = readVersionWord(offset);
    const auto valueLength = readVersionWord(offset + 2);
    const auto type = readVersionWord(offset + 4);

    if (length < 6)
        return false;

    const BYTE* keyEnd = offset + 6;
    while (keyEnd + 2 <= limit) {
        if (readVersionWord(keyEnd) == 0) {
            keyEnd += 2;
            break;
        }

        keyEnd += 2;
    }

    if (keyEnd > limit)
        return false;

    const auto valueBytes = (size_t) (type == 1 ? valueLength * 2 : valueLength);
    const BYTE* valueStart = (const BYTE*) ((((size_t) keyEnd) + 3) & ~3ull);

    if (valueStart + valueBytes > limit)
        return false;

    const BYTE* next = offset + length;

    if (next <= offset || next > limit)
        return false;

    block.key = offset + 6;
    block.value = valueStart;
    block.valueBytes = valueBytes;
    block.children = valueStart + valueBytes;
    block.next = next;
    return true;
}

bool versionBlockIsNamed(const VersionBlock& block, const wchar_t* name) {
    return block.key != nullptr && wcscmp(reinterpret_cast<const wchar_t*> (block.key), name) == 0;
}

/** Finds the direct child block with the given name. */
bool findVersionChild(const BYTE* limit, const BYTE* children, const wchar_t* name, VersionBlock& found) {
    const BYTE* offset = children;

    while (offset != nullptr && offset + 6 <= limit) {
        VersionBlock block;

        if (! readVersionBlock(limit, offset, block))
            break;

        if (versionBlockIsNamed(block, name)) {
            found = block;
            return true;
        }

        offset = block.next;
    }

    return false;
}

/** Finds a string value (for example "ProductName") inside a string table. */
String findVersionString(const BYTE* limit, const BYTE* children, const wchar_t* name) {
    const BYTE* offset = children;

    while (offset != nullptr && offset + 6 <= limit) {
        VersionBlock block;

        if (! readVersionBlock(limit, offset, block))
            break;

        if (versionBlockIsNamed(block, name) && block.valueBytes >= sizeof(wchar_t))
            return String(reinterpret_cast<const wchar_t*> (block.value));

        offset = block.next;
    }

    return {};
}

/** Reads ProductName, CompanyName and the versions of a DLL. */
ModuleVersion readModuleVersion(const String& path) {
    ModuleVersion version;

    const auto wide = path.toWideCharPointer();
    const auto module = LoadLibraryExW(wide, nullptr, LOAD_LIBRARY_AS_DATAFILE);

    if (module == nullptr)
        return version;

    HRSRC resource = FindResourceW(module, MAKEINTRESOURCEW(1), MAKEINTRESOURCEW(16));

    if (resource != nullptr) {
        const auto handle = LoadResource(module, resource);
        const auto size = SizeofResource(module, resource);
        const auto* data = (const BYTE*) LockResource(handle);

        if (data != nullptr && size > 0) {
            const BYTE* limit = data + size;
            VersionBlock root;

            if (readVersionBlock(limit, data, root)) {
                if (root.valueBytes >= sizeof(VS_FIXEDFILEINFO)) {
                    const auto* fixed = (const VS_FIXEDFILEINFO*) root.value;
                    version.fileVersion = String(fixed->dwFileVersionMS >> 16) + "." + String(fixed->dwFileVersionMS & 0xffff) + "."
                                          + String(fixed->dwFileVersionLS >> 16) + "." + String(fixed->dwFileVersionLS & 0xffff);
                    version.productVersion = String(fixed->dwProductVersionMS >> 16) + "." + String(fixed->dwProductVersionMS & 0xffff) + "."
                                             + String(fixed->dwProductVersionLS >> 16) + "." + String(fixed->dwProductVersionLS & 0xffff);
                }

                VersionBlock stringInfo;

                if (findVersionChild(limit, root.children, L"StringFileInfo", stringInfo)) {
                    const BYTE* table = stringInfo.children;

                    while (table != nullptr && table + 6 <= limit) {
                        VersionBlock tableBlock;

                        if (! readVersionBlock(limit, table, tableBlock))
                            break;

                        const auto productName = findVersionString(limit, tableBlock.children, L"ProductName");
                        if (productName.isNotEmpty()) version.productName = productName;

                        const auto companyName = findVersionString(limit, tableBlock.children, L"CompanyName");
                        if (companyName.isNotEmpty()) version.companyName = companyName;

                        const auto productVersion = findVersionString(limit, tableBlock.children, L"ProductVersion");
                        if (productVersion.isNotEmpty()) version.productVersion = productVersion;

                        table = tableBlock.next;
                    }
                }
            }
        }
    }

    FreeLibrary(module);
    return version;
}

/**
    Reads the VST2 modules that the Steinberg SDK registered.

    The value name of "SOFTWARE\Steinberg\VST\ActivePlugins" is the path of the
    module, some installers store the path in the data of the value instead.
*/
void readRegisteredVst2Modules(StringArray& modules) {
    struct Location {
        HKEY root;
        const wchar_t* subKey;
    };
    const Location locations[] = {
        {HKEY_LOCAL_MACHINE, L"SOFTWARE\\Steinberg\\VST\\ActivePlugins"},
        {HKEY_CURRENT_USER, L"SOFTWARE\\Steinberg\\VST\\ActivePlugins"}};

    for (const auto& location : locations) {
        // The VST2 SDK is installed by 32 bit installers, so the 32 bit view of
        // the registry has to be checked as well.
        for (const auto view : {DWORD(0), DWORD(KEY_WOW64_32KEY)}) {
            HKEY key = nullptr;
            if (::RegOpenKeyExW(location.root, location.subKey, 0, KEY_READ | view, &key) != ERROR_SUCCESS) continue;
            for (int index = 0;; ++index) {
                wchar_t name[1024] = {};
                DWORD nameLength = static_cast<DWORD>(sizeof(name) / sizeof(wchar_t));
                DWORD type = 0, dataSize = 0;
                if (::RegEnumValueW(key, index, name, &nameLength, nullptr, &type, nullptr, &dataSize) != ERROR_SUCCESS) break;
                std::vector<wchar_t> data(dataSize / sizeof(wchar_t) + 2, 0);
                DWORD dataLength = static_cast<DWORD>(data.size() * sizeof(wchar_t));
                nameLength = static_cast<DWORD>(sizeof(name) / sizeof(wchar_t));
                if (::RegEnumValueW(key, index, name, &nameLength, nullptr, &type,
                                   reinterpret_cast<LPBYTE>(data.data()), &dataLength) != ERROR_SUCCESS)
                    continue;
                for (const auto& candidate : {String(name), String(data.data())}) {
                    if (candidate.isEmpty() || !candidate.containsIgnoreCase(".dll")) continue;
                    if (!File::isAbsolutePath(candidate)) continue;
                    addUnique(modules, File(candidate).getFullPathName());
                }
            }
            ::RegCloseKey(key);
        }
    }
}

#endif

/** The file extension of a VST2 module on this platform. */
String vst2Extension() {
#if JUCE_WINDOWS
    return ".dll";
#else
    return ".so";
#endif
}

/** Collects the VST3 plugins of the given directories. */
void scanVst3(const StringArray& directories, const StringArray& files,
              std::vector<PluginEntry>& plugins, StringArray& errors) {
    VST3PluginFormat format;
    FileSearchPath searchPath;
    for (const auto& directory : directories) searchPath.add(File(directory), -1);

    StringArray found;
    try {
        // The search has to be recursive: vendors such as Neural DSP keep their
        // plugins in a sub folder of the VST3 directory.
        found = format.searchPathsForPlugins(searchPath, true, false);
    } catch (const std::exception&) {
        errors.add(String::fromUTF8("搜索 VST3 插件目录时出错。"));
        return;
    }
    for (const auto& file : files) found.add(file);

    for (const auto& path : found) {
        OwnedArray<PluginDescription> descriptions;
        try {
            // Reading the details of a VST3 may load the module, so this must
            // only happen inside the scan child process.
            format.findAllTypesForFile(descriptions, path);
        } catch (const std::exception&) {
            errors.add(String::fromUTF8("读取 VST3 插件信息失败：") + path);
            continue;
        }
        if (descriptions.isEmpty()) continue;

        PluginEntry entry;
        entry.format = "vst3";
        entry.path = File(path).getFullPathName();
        entry.name = descriptions[0]->name;
        entry.vendor = descriptions[0]->manufacturerName;
        entry.version = descriptions[0]->version;
        entry.category = descriptions[0]->category;
        entry.isInstrument = descriptions[0]->isInstrument;
        if (entry.name.isEmpty()) entry.name = File(path).getFileNameWithoutExtension();
        entry.loadable = !entry.isInstrument;
        if (entry.isInstrument) entry.note = String::fromUTF8("虚拟乐器插件暂不支持加载。");
        plugins.push_back(entry);
    }
}

/** Adds one VST2 module to the result. */
void addVst2Entry(const String& path, std::vector<PluginEntry>& plugins) {
    PluginEntry entry;
    entry.format = "vst2";
    entry.path = File(path).getFullPathName();
    entry.name = File(path).getFileNameWithoutExtension();
    entry.isInstrument = false;

#if GUITARBOOK_VST2_ENABLED
    // With the VST2 SDK available JUCE can read the real metadata of the module.
    VSTPluginFormat format;
    OwnedArray<PluginDescription> descriptions;
    try {
        format.findAllTypesForFile(descriptions, entry.path);
    } catch (const std::exception&) {
    }
    if (!descriptions.isEmpty()) {
        if (descriptions[0]->name.isNotEmpty()) entry.name = descriptions[0]->name;
        entry.vendor = descriptions[0]->manufacturerName;
        entry.version = descriptions[0]->version;
        entry.category = descriptions[0]->category;
        entry.isInstrument = descriptions[0]->isInstrument;
    }
#else
   #if JUCE_WINDOWS
    // Without the SDK the module cannot be loaded, so the metadata is taken
    // from the version resources of the file instead.
    const auto version = readModuleVersion(entry.path);
    if (version.productName.isNotEmpty()) entry.name = version.productName;
    entry.vendor = version.companyName;
    if (version.productVersion.isNotEmpty()) entry.version = version.productVersion;
    else if (version.fileVersion.isNotEmpty()) entry.version = version.fileVersion;
   #endif
#endif

    StringArray notes;
    if (!vst2Supported()) notes.add(String::fromUTF8("当前构建未启用 VST2 加载（需要 Steinberg VST2 SDK）"));
    if (entry.isInstrument) notes.add(String::fromUTF8("虚拟乐器插件暂不支持加载。"));
    entry.note = notes.joinIntoString("；");
    entry.loadable = vst2Supported() && !entry.isInstrument;
    plugins.push_back(entry);
}

/** Collects the VST2 modules of the given directories and module files. */
void scanVst2(const StringArray& directories, const StringArray& files,
              std::vector<PluginEntry>& plugins) {
    const auto extension = vst2Extension();
    for (const auto& directory : directories) {
        const File folder(directory);
        if (!folder.isDirectory()) continue;
        for (DirectoryEntry entry : RangedDirectoryIterator (folder, false, "*")) {
            const auto file = entry.getFile();
            if (!file.existsAsFile()) continue;
            if (!file.getFileExtension().equalsIgnoreCase(extension)) continue;
            addVst2Entry(file.getFullPathName(), plugins);
        }
    }
    for (const auto& file : files) addVst2Entry(file, plugins);
}

/** VST3 first, then VST2; inside a format the plugins are sorted by name. */
bool entryLess(const PluginEntry& a, const PluginEntry& b) {
    const auto rank = [](const String& format) { return format == "vst3" ? 0 : 1; };
    const auto rankA = rank(a.format), rankB = rank(b.format);
    if (rankA != rankB) return rankA < rankB;
    return a.name.compareIgnoreCase(b.name) < 0;
}

/** Returns the first JSON object of the given output. */
var parseFirstJsonObject(const String& output) {
    int start = 0;
    while (start <= output.length()) {
        auto end = output.indexOfChar('\n', start);
        if (end < 0) end = output.length();
        const auto line = output.substring(start, end).trim();
        if (line.startsWith("{")) {
            const auto parsed = JSON::parse(line);
            if (parsed.isObject()) return parsed;
        }
        if (end >= output.length()) break;
        start = end + 1;
    }
    return {};
}

}  // namespace

bool vst2Supported() {
#if GUITARBOOK_VST2_ENABLED
    return true;
#else
    return false;
#endif
}

var ScanResult::toVar() const {
    Array<var> pluginValues;
    for (const auto& plugin : plugins)
        pluginValues.add(makeObject({{"format", plugin.format}, {"name", plugin.name}, {"vendor", plugin.vendor},
            {"version", plugin.version}, {"category", plugin.category}, {"path", plugin.path},
            {"isInstrument", plugin.isInstrument}, {"loadable", plugin.loadable}, {"note", plugin.note}}));
    return makeObject({{"platform", platform}, {"vst2Supported", PluginScanner::vst2Supported()},
        {"directories", var(directories)}, {"plugins", var(pluginValues)}, {"errors", var(errors)},
        {"durationMs", durationMs}});
}

ScanResult ScanResult::fromVar(const var& value) {
    ScanResult result;
    if (!value.isObject()) return result;
    const auto* source = dynamic_cast<const DynamicObject*> (value.getObject());
    if (source == nullptr)
        return result;
    result.platform = source->getProperty("platform").toString();
    result.vst2Supported = static_cast<bool>(source->getProperty("vst2Supported"));
    result.durationMs = static_cast<int64>(source->getProperty("durationMs"));
    if (auto* items = source->getProperty("directories").getArray())
        for (const auto& item : *items) result.directories.add(item.toString());
    if (auto* items = source->getProperty("errors").getArray())
        for (const auto& item : *items) result.errors.add(item.toString());
    if (auto* items = source->getProperty("plugins").getArray())
        for (const auto& item : *items) {
            if (!item.isObject()) continue;
            const auto* plugin = dynamic_cast<const DynamicObject*> (item.getObject());
            if (plugin == nullptr)
                continue;
            PluginEntry entry;
            entry.format = plugin->getProperty("format").toString();
            entry.name = plugin->getProperty("name").toString();
            entry.vendor = plugin->getProperty("vendor").toString();
            entry.version = plugin->getProperty("version").toString();
            entry.category = plugin->getProperty("category").toString();
            entry.path = plugin->getProperty("path").toString();
            entry.isInstrument = static_cast<bool>(plugin->getProperty("isInstrument"));
            entry.loadable = static_cast<bool>(plugin->getProperty("loadable"));
            entry.note = plugin->getProperty("note").toString();
            result.plugins.push_back(entry);
        }
    return result;
}

StringArray extractPaths(const var& request) {
    StringArray paths;
    const auto value = request["paths"];
    if (auto* items = value.getArray()) {
        for (const auto& item : *items) {
            const auto text = item.toString().trim();
            if (text.isNotEmpty()) paths.add(text);
        }
    } else {
        const auto text = value.toString().trim();
        if (text.isNotEmpty()) paths.add(text);
    }
    return paths;
}

ScanResult scanInProcess(const StringArray& extraPaths) {
    const auto started = Time::getMillisecondCounter();
    ScanResult result;
    result.platform = currentPlatform();
    result.vst2Supported = vst2Supported();

    auto plan = defaultPlan();
#if JUCE_WINDOWS
    readRegisteredVst2Modules(plan.vst2Files);
#endif

    // The requested paths are scanned on top of the default locations.
    for (const auto& path : extraPaths) {
        const File file(path);
        if (!file.exists()) {
            result.errors.add(String::fromUTF8("路径不存在：") + path);
            continue;
        }
        if (file.isDirectory()) {
            addUnique(plan.vst3Directories, file.getFullPathName());
            addUnique(plan.vst2Directories, file.getFullPathName());
        } else if (file.getFileExtension().equalsIgnoreCase(".vst3")) {
            addUnique(plan.vst3Files, file.getFullPathName());
        } else {
            addUnique(plan.vst2Files, file.getFullPathName());
        }
    }

    // Only the directories that really exist are reported as scanned.
    StringArray vst3Directories, vst2Directories;
    for (const auto& directory : plan.vst3Directories)
        if (File(directory).isDirectory()) addUnique(vst3Directories, directory);
    for (const auto& directory : plan.vst2Directories)
        if (File(directory).isDirectory()) addUnique(vst2Directories, directory);
    for (const auto& directory : vst3Directories) addUnique(result.directories, directory);
    for (const auto& directory : vst2Directories) addUnique(result.directories, directory);

    scanVst3(vst3Directories, plan.vst3Files, result.plugins, result.errors);
    scanVst2(vst2Directories, plan.vst2Files, result.plugins);

    // The same plugin may be found in more than one directory.
    std::vector<PluginEntry> unique;
    for (const auto& entry : result.plugins) {
        bool duplicate = false;
        for (const auto& existing : unique)
            if (samePath(existing.path, entry.path)) {
                duplicate = true;
                break;
            }
        if (!duplicate) unique.push_back(entry);
    }
    result.plugins = unique;
    std::stable_sort(result.plugins.begin(), result.plugins.end(), entryLess);

    result.durationMs = Time::getMillisecondCounter() - started;
    return result;
}

ScanResult scanInChildProcess(const StringArray& extraPaths) {
    const auto started = Time::getMillisecondCounter();
    ScanResult result;
    result.platform = currentPlatform();
    result.vst2Supported = vst2Supported();

    const auto requestFile = File::createTempFile(".json");
    {
        FileOutputStream stream(requestFile);
        if (!stream.openedOk()) {
            result.errors.add(String::fromUTF8("无法创建插件扫描请求文件。"));
            result.durationMs = Time::getMillisecondCounter() - started;
            return result;
        }
        const auto request = JSON::toString(makeObject({{"paths", var(extraPaths)}}), true);
        stream.write(request.toRawUTF8(), request.getNumBytesAsUTF8());
        stream.flush();
    }

    StringArray arguments;
    arguments.add(File::getSpecialLocation(File::currentExecutableFile).getFullPathName());
    arguments.add("--scan");
    arguments.add(requestFile.getFullPathName());

    ChildProcess child;
    if (!child.start(arguments, ChildProcess::wantStdOut | ChildProcess::wantStdErr)) {
        result.errors.add(String::fromUTF8("无法启动插件扫描子进程。"));
        requestFile.deleteFile();
        result.durationMs = Time::getMillisecondCounter() - started;
        return result;
    }

    // The output of the child is drained while it runs, otherwise a full pipe
    // would block the child. The bytes are collected raw and decoded once at
    // the end: a String built from a char* would read them as 8 bit
    // characters and destroy every non ASCII character.
    std::mutex mutex;
    std::string output;
    std::atomic<bool> readerFinished {false};
    std::thread reader([&] {
        char buffer[4096] = {};
        for (;;) {
            const auto read = child.readProcessOutput(buffer, sizeof(buffer));
            if (read <= 0) break;
            std::lock_guard<std::mutex> lock(mutex);
            output.append(buffer, static_cast<size_t>(read));
        }
        readerFinished = true;
    });

    // The reader is inside the handle of the child process, so the process must
    // not be reaped from this thread while the reader is still running. The
    // reader only stops when the child has ended, so waiting for it is the
    // same as waiting for the child.
    const auto deadline = Time::getMillisecondCounter() + 120000;
    while (! readerFinished.load() && Time::getMillisecondCounter() < deadline)
        Thread::sleep(20);

    const auto timedOut = ! readerFinished.load();
    if (timedOut) {
        child.kill();
        result.errors.add(String::fromUTF8("插件扫描超时。"));
    }

    reader.join();
    const auto exitCode = static_cast<int>(child.getExitCode());
    // Now that nobody reads the pipe any more the child can be reaped.
    child.waitForProcessToFinish(2000);
    requestFile.deleteFile();

    String captured;
    {
        std::lock_guard<std::mutex> lock(mutex);
        captured = String::createStringFromData (output.data(), static_cast<int> (output.size()));
    }

    const auto parsed = parseFirstJsonObject(captured);
    if (parsed.isObject()) {
        auto childResult = ScanResult::fromVar(parsed);
        if (childResult.platform.isEmpty()) childResult.platform = result.platform;
        childResult.vst2Supported = result.vst2Supported;
        if (childResult.durationMs <= 0) childResult.durationMs = Time::getMillisecondCounter() - started;
        return childResult;
    }

    // The child crashed or printed nothing usable.
    if (result.errors.isEmpty())
        result.errors.add(String::fromUTF8("插件扫描子进程没有返回结果（退出码 ")
                           + String(exitCode) + String::fromUTF8("）。"));
    result.durationMs = Time::getMillisecondCounter() - started;
    return result;
}

}  // namespace PluginScanner
