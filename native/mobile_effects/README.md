# 移动端内置效果器

Android 通过 Oboe（JUCE 8.0.12 随附的 1.9.0）全双工回调运行；iOS 通过 RemoteIO 运行。两端共用 `engine.h` 与 `../effects_host/builtin_effect.h`，不创建桌面宿主进程、不加载 VST3。Flutter 仅传控制命令、电平和有界湿声 PCM，不参与实时音频处理。

- 控制操作由平台主线程串行执行；音频回调只尝试获取效果链锁，编辑期间可能短暂静音。
- 音频输入为系统当前路由提供的单声道输入，不提供独立通道选择。输出为立体声。
- 湿声取点在效果链后、监听音量前；48 kHz、PCM16 小端、单声道，FIFO 最多两秒。非 48 kHz、停止监听、输入错误或溢出均明确拒绝录音。
- 页面会话使用独立 ID；销毁某会话不影响其他会话。进入后台、路由变化和音频中断停止监听，回前台手动恢复。
- Android 请求设备原生采样率、共享低延迟输出；显示实际回调帧数和输出队列大小，二者不同。输入输出时钟漂移及所有设备的低延迟能力仍需设备验证。
- iOS 请求 Measurement + PlayAndRecord、48 kHz 和低缓冲，实际参数由系统决定。停止仅关闭 RemoteIO，避免停用工作台其他回放引擎共享的 AVAudioSession。

## 构建

Android：`flutter build apk --debug --target-platform android-arm64`。需要 NDK 与 CMake 3.22.1。CMake 下载固定版本且校验 SHA256 的 JUCE 源码，使用其随附 Oboe；可用 `FETCHCONTENT_SOURCE_DIR_JUCE` 覆盖源码用于离线构建。

iOS：在 macOS/Xcode 执行 `flutter build ios --debug --no-codesign`。Xcode 的 Prepare Effects 阶段运行 `tool/prepare_ios_effects.sh`，将同版本、同校验和的 JUCE 解压到 `.dart_tool/guitarbook-native/JUCE-8.0.12`。支持先运行脚本再离线构建，不需要 CocoaPods；工程编译 JUCE headless 模块及 Objective-C++ 桥接。JUCE / Oboe 许可随 Flutter assets 分发并注册到应用许可证。

## 离线验证

在 Linux（无需声卡、不开麦克风）执行：

```sh
cmake -S native/mobile_effects -B build/mobile-effects-test -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build/mobile-effects-test -j 2
ctest --test-dir build/mobile-effects-test --output-on-failure
flutter test
```

也可给 CMake 加 `-DFETCHCONTENT_SOURCE_DIR_JUCE=/绝对路径/JUCE` 复用已有源码。

离线测试包含十种效果 DSP（含可切换手动 / 自动的哇音），以及移动端链路的探测后释放、监听音量零时仍录入湿声、实际处理与旁通、移动保留参数、八节限制、FIFO 溢出和重启清空、监听停止后拒绝读取、非 48 kHz 拒绝录音、实时渲染与 UI 编辑并发。

真机验收需分别验证录音拒绝/授权重试、授权期间后台或离页、声卡插拔、音频焦点/来电、后台停止与手动恢复、同声卡有线输入输出、Looper 与鼓机同时播放、完整链稳定性和物理回环延迟。离线测试、构建或模拟器运行不代替这些结果。当前验证结果见项目 README 与 docs/FEATURES.md。
