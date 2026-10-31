# 原生实时效果器宿主

Linux / Windows 共用的 JUCE 8.0.12 内置 / VST3 宿主。Flutter 桌面构建会编译该目标，并将程序安装在主程序旁。音频在本进程的设备回调中处理；stdin/stdout 使用逐行 JSON，传命令、电平及有界 Looper PCM 分块。插件诊断应使用 stderr。

每次请求包含 `id` 和 `command`；响应保留 `id`，返回 `result` 状态或 `error`。命令包括 `probe`（停止监听时静音打开输入/立体声输出并关闭，成功返回 `available: true`；监听中只返回当前状态）、`status`、`settings`、`start`、`stop`、`load`（`path`）、`remove`/`editor`（`index`）、`bypass`（`index`/`value`）、`move`（`index`/`destination`）、`gain`（`value`）、`audioBuffer`（`frames`：64/128/256/512，仅停止时接受）、`builtin`（`kind`：wah/fuzz/compressor/reverb/overdrive/delay/amp_clean/amp_chime/amp_crunch/amp_modern）、`parameter`（`index`/`parameter`/物理范围内的 `value`）。`move` 将源实例插入目标下标，中间实例相对顺序不变（跨多个位置时也不交换首尾），保留参数与旁通。状态中的 `plugins` 同时包含内置与 VST3；内置条目含 `kind` 和参数范围/当前值。stdin 关闭时释放设备、插件与窗口并退出。

可单独构建；首次需下载 JUCE，也可附加 `-DFETCHCONTENT_SOURCE_DIR_JUCE=/绝对路径/JUCE` 使用本地源码。平台依赖和使用限制见项目 README。

```bash
cmake -S native/effects_host -B build/effects-host -DCMAKE_BUILD_TYPE=Debug -DGUITARBOOK_EFFECTS_TESTS=ON
cmake --build build/effects-host --config Debug --parallel 2
```

Linux 离线集成验证（需要图形显示服务；不会打开音频设备）：

```bash
build/effects-host/guitarbook_effects_host_artefacts/Debug/guitarbook_effects_host --test "$(pwd)/build/effects-host/guitarbook_test_gain_artefacts/Debug/VST3/Guitarbook Test Gain.vst3"
GUITARBOOK_EFFECTS_HOST="$(pwd)/build/effects-host/guitarbook_effects_host_artefacts/Debug/guitarbook_effects_host" dart run tool/check_effects_host.dart "$(pwd)/build/effects-host/guitarbook_test_gain_artefacts/Debug/VST3/Guitarbook Test Gain.vst3"
```

第一项验证真实 VST3 发现、处理、串联、旁通、移除、非首通道及停止静音；第二项通过应用实际使用的 Dart 后端验证进程通信、参数窗口、错误后的效果链保留与关闭释放。测试插件仅作确定性测试，不随正式应用安装，不代表第三方插件兼容性验证。Windows 可用相应 `.exe` 与绝对路径执行离线测试，但目前尚未在 Windows 验证。

宿主超时或崩溃会丢失内存效果链。扫描、插件 UI 与处理位于同一宿主进程，插件之间不隔离。第一版不保存状态、不做延迟补偿；Looper 接收效果链后、监听音量前的湿声 PCM。实际延迟与听感需分别在 Linux / Windows 声卡上验证。


六类单块、四种原创箱头算法及实际可编辑链音频测试（无声卡采集）：

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
