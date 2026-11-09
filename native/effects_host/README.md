# 原生实时效果器宿主

Linux / Windows 共用的 JUCE 8.0.12 内置 / VST3 宿主。Flutter 桌面构建会编译该目标，并将程序安装在主程序旁。音频在本进程的设备回调中处理；stdin/stdout 使用逐行 JSON，传命令、电平及有界 Looper PCM 分块。插件诊断应使用 stderr。

每次请求包含 `id` 和 `command`；响应保留 `id`，返回 `result` 状态或 `error`。命令包括 `probe`（停止监听时静音打开输入/立体声输出并关闭，成功返回 `available: true`；监听中只返回当前状态）、`status`、`settings`、`start`、`stop`、`load`（`path`）、`remove`/`editor`（`index`）、`bypass`（`index`/`value`）、`move`（`index`/`destination`）、`gain`（`value`）、`audioBuffer`（`frames`：64/128/256/512，仅停止时接受）、`builtin`（`kind`：wah/fuzz/compressor/reverb/overdrive/delay/pitch/amp_clean/amp_chime/amp_crunch/amp_modern）、`parameter`（`index`/`parameter`/物理范围内的 `value`）。`move` 将源实例插入目标下标，中间实例相对顺序不变（跨多个位置时也不交换首尾），保留参数与旁通。状态中的 `plugins` 同时包含内置与 VST3；内置条目含 `kind` 和参数范围/当前值。stdin 关闭时释放设备、插件与窗口并退出。Windows 上宿主编译进 JUCE 的 ASIO 后端（`JUCE_ASIO=1`，仅 Windows 分支），设备选择窗口里可选择用户已安装的 ASIO 驱动；`status` 因此额外上报 `deviceTypes`（可用后端）与 `asioDrivers`（枚举到的 ASIO 驱动名，枚举需要读注册表，结果缓存，打开设备窗口时重新扫描）。ASIO 驱动由声卡厂商提供，宿主不附带驱动；JUCE 的 ASIO 后端使用内置的 Steinberg ASIO SDK 接口头文件，其许可随应用分发为 `data/licenses/ASIO-SDK-LICENSE.txt`。宿主默认按声卡的多路输入打开设备（最多 4 路：`useDefaultInputChannels = false` + 显式通道掩码，驱动拒绝该宽度时回退并恢复原配置），在音频回调里逐路测量峰值，默认自动跟随信号最强的一路（当前通道强 1.5 倍时保持，避免演奏间隙跳路）；新增 `inputChannel` 命令（`auto: true` 自动跟随 / `index` 固定第 i 路，越界报错），`status` 因此额外上报 `inputChannelNames`（已打开的输入通道名）、`inputChannelLevels`（各路瞬时电平）、`activeInputChannel`（当前监听通道序号，无信号为 -1）与 `autoInputChannel`（是否自动跟随）。

新增 `scan` 命令用于列出本机已安装的 VST3/VST2 插件，请求可带 `paths`（字符串或字符串数组，作为默认目录之外的补充目录或单个插件文件）。响应的 `result` 只含 `platform`（`windows`/`linux`/`macos`）、`vst2Supported`（本构建是否带 VST2 支持）、`directories`（实际扫描过且存在的目录）、`plugins`（每项为 `format`/`name`/`vendor`/`version`/`category`/`path`（绝对路径）/`isInstrument`/`loadable`/`note`）、`errors`（读取失败原因）与 `durationMs`。`loadable` 表示本构建确实能加载该插件：VST3 效果为 true，虚拟乐器为 false；默认构建（未启用 Steinberg VST2 SDK）仍会列出 VST2 模块，但 `loadable` 为 false，`note` 说明原因，无问题时为空字符串。扫描在独立子进程中完成（宿主自启动 `--scan <请求文件>`，子进程输出一行 JSON），坏插件不会拖垮宿主；命令在后台线程执行、结果异步返回，因此响应顺序可能与请求顺序不同，调用方需按 `id` 匹配。`status` 同样上报 `vst2Supported`。`load` 按扩展名选择插件格式（`.vst3` → VST3，`.dll` → VST2），默认构建遇到 `.dll` 会返回明确错误提示改用 `.vst3`。

可单独构建。JUCE 依赖不再用 git 克隆，改为下载按标签 `8.0.12` 固定、SHA-256 校验（`dec1a8ba…cf102`）的源码包，不需要 git 网络访问；源码包放在共享缓存 `.dart_tool/guitarbook-native/downloads/`，解压后的源码放在 `.dart_tool/guitarbook-native/JUCE-8.0.12/`（与 iOS 辅助脚本 `tool/prepare_ios_effects.sh` 同一目录）。配置时若发现解压副本已存在，构建直接复用，重复构建与离线构建都不需要联网。Windows 上可先运行 `pwsh -File tool/prepare_juce_sources.ps1` 填充缓存（脚本读取系统代理，可用 `-Proxy`、`-Url` 覆盖，校验 SHA-256 后解压，已缓存时跳过）；受限网络也可配置 `-DGUITARBOOK_JUCE_URL=<镜像地址>` 使用镜像（校验值不变，镜像必须提供同一份源码包）。缓存之外的本地源码仍可附加 `-DFETCHCONTENT_SOURCE_DIR_JUCE=/绝对路径/JUCE` 使用。VST2 支持是可选构建项：JUCE 8 不再自带 VST2 SDK 头文件，需要 VST2 的构建追加 `-DGUITARBOOK_ENABLE_VST2=ON -DGUITARBOOK_VST2_SDK_DIR=<SDK 目录>`（目录须含 `pluginterfaces/vst2.x/aeffect.h`，缺目录或缺头文件时配置阶段直接报错），此时 `status` 与 `scan` 的 `vst2Supported` 为 true，VST2 效果可被 `load` 加载；SDK 不会被复制进仓库，许可由使用者自行负责。Windows 构建时 MSVC 需以 `/utf-8` 编译（源文件含中文字面量），且 CMake 安装前缀须为绝对路径，否则 JUCE 模块头文件安装会失败（`file INSTALL cannot make directory`），相关设置见 `windows/CMakeLists.txt` 与宿主 CMakeLists。平台依赖和使用限制见项目 README。

```bash
cmake -S native/effects_host -B build/effects-host -DCMAKE_BUILD_TYPE=Debug -DGUITARBOOK_EFFECTS_TESTS=ON
cmake --build build/effects-host --config Debug --parallel 2
```

Linux 离线集成验证（需要图形显示服务；不会打开音频设备）：

```bash
build/effects-host/guitarbook_effects_host_artefacts/Debug/guitarbook_effects_host --test "$(pwd)/build/effects-host/guitarbook_test_gain_artefacts/Debug/VST3/Guitarbook Test Gain.vst3"
GUITARBOOK_EFFECTS_HOST="$(pwd)/build/effects-host/guitarbook_effects_host_artefacts/Debug/guitarbook_effects_host" dart run tool/check_effects_host.dart "$(pwd)/build/effects-host/guitarbook_test_gain_artefacts/Debug/VST3/Guitarbook Test Gain.vst3"
```

第一项验证真实 VST3 发现、处理、串联、旁通、移除、非首通道及停止静音；第二项通过应用实际使用的 Dart 后端验证进程通信、参数窗口、错误后的效果链保留与关闭释放。测试插件仅作确定性测试，不随正式应用安装，不代表第三方插件兼容性验证。Windows 可用相应 `.exe` 与绝对路径执行离线测试，并已于 2026-11-08 在 Windows 上完成首次验证：Debug 构建通过，`guitarbook_effects_host.exe --test-builtins` 输出 `Built-in DSP tests passed`、`Wet Looper capture tests passed`、`Editable built-in chain audio tests passed`（退出码 0）；JSON 协议往返正常，中文参数名（如「Fuzz 法兹」「现代高增益箱头」）无乱码。宿主 exe 随应用安装到主程序旁 `build/windows/x64/runner/Debug/`。Windows 上已验证宿主能打开本机 Focusrite USB 声卡并上报多路输入（2026-11-08，`status` 返回 `"inputChannels": 2` 与两路通道名，此前只会打开 1 路）；真实吉他演奏的监听与听感、监听音量、实际延迟，以及第三方 VST3 插件的发现与加载仍未验证（离线测试只覆盖内置效果）。

宿主超时或崩溃会丢失内存效果链。扫描、插件 UI 与处理位于同一宿主进程，插件之间不隔离。第一版不保存状态、不做延迟补偿；Looper 接收效果链后、监听音量前的湿声 PCM。实际延迟与听感需分别在 Linux / Windows 声卡上验证；Windows 侧目前只有构建与离线测试结果，尚无真实声卡验证。


七类单块（含移调）、四种原创箱头算法及实际可编辑链音频测试（无声卡采集）：

```bash
build/effects-host/guitarbook_effects_host_artefacts/Debug/guitarbook_effects_host --test-builtins
```

哇音参数依次为位置、共振 Q、干湿比、输出、自动模式（0 手动 / 1 自动）、速度、深度；默认手动，自动模式为围绕位置的正弦扫频。

箱头六参数依次为增益、低频、中频、高频、主音量、箱体混合；箱体 0 关闭简易滤波，不含 IR。

覆盖箱头互异、六控制实际音频变化与实例隔离、44.1/48/96 kHz、参数极值、静音与有限输出、延迟回声时刻/反馈、压缩静态比例、混响干湿/尾音、实例隔离，以及真实宿主回调中的排序和旁通。参数变更原子写入并平滑，添加、加载、排序和移除可在监听中执行，不重启音频设备；插件准备在入链前完成，链锁忙时音频回调输出静音，结构切换可能短暂断音。离线测试在 enabled 状态下验证内置添加/排序/移除与 VST3 加载/排序/移除，不代表真实声卡无缝切换。`tool/check_effects_host.dart` 同时检查重复内置参数独立、混合链排序与八节上限。


Linux 默认请求 48000 Hz / 128 帧，首次失败尝试 256、512 并报告回退。只为宿主活动节点设置 PIPEWIRE_QUANTUM；外部环境变量优先，不改服务器 metadata。参数面板显示实际缓冲、后端、分项延迟、xrun 和全湿效果诊断。JACK 在找到 jack/jack.h 时可编译启用，否则使用 ALSA。

真实设备静音检查（会打开麦克风/声卡，但不会启用监听或保存音频）：

```bash
python3 tool/check_linux_audio_latency.py
```

该脚本验证 128/256 帧及 48 kHz、抓取 pw-top 供核对，并确认停止关闭设备、全局 settings metadata 不变。本机旧版默认驱动报告约 69.7 ms，改为 128 帧后报告 16 ms；实际物理往返延迟仍需外部回环测量，短暂静音检查不代表长期实时演奏稳定。

Looper 协议：`loopStart` 要求已监听且实际采样率为 48000 Hz，清空 FIFO 并开始采集；`loopRead` 返回 `{pcm: Base64}`，为效果链后、监听音量前的左右平均 PCM16 小端单声道；`loopStop` 关闭采集分支且不停止监听。FIFO 预分配两秒容量，满时明确报错，不静默丢帧。读取由界面每 20 ms 发起且不重叠，设备重启或停止使采集失效；录音仅驻留本机内存。`--test-builtins` 同时验证湿声包含效果、监听音量独立、缓冲溢出与重启清空。
