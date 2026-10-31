# Guitarbook · 吉他宝典

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md)

A Flutter guitar toolkit for practicing and improvising: build a groove with the drum machine, layer phrases with the Looper, and shape your sound with live effects.

## Drum machine × Looper × Effects

- **Drum machine:** 12 simplified practice grooves—rock, funk, blues, pop, folk, punk, metal, disco, reggae, hip-hop, jazz swing and Latin. Edit kick, snare and hi-hat in a one-bar, 16-step 4/4 sequencer; set 30–240 BPM, swing, track mutes and playback volume.
- **Looper:** record a first loop from 0.3 to 30 seconds and build up to 6 layers. Undo the latest layer, stop/resume or clear everything. Smart first-layer recording measures background noise, starts when you play and trims the ends after about two seconds of silence. Bind keyboard keys or a USB footswitch that sends keyboard input.
- **Live effects:** fuzz, compressor, reverb, overdrive, delay and switchable manual/automatic wah, plus four original amp styles: American clean, British chime, British rock and modern high gain. Chain up to 8 instances, drag to reorder, adjust independent parameters and bypass pedals. Linux and Windows also load locally installed, compatible VST3 effects.
- **One workspace:** open the drum machine from the home screen to access drums, Looper and effects together, with separate volume controls. On Android, iOS, Linux and Windows, the Looper captures the processed signal after the effects chain; monitoring must be active and the actual sample rate must be 48 kHz.

The toolkit also includes a standard-tuning guitar tuner, metronome, scale fretboard and beginner chord lessons. README translations do not imply a translated app interface.

## Platform status

Implementation and verification are separate. Existing platform projects do not guarantee device compatibility. Status below reflects the project records as of **2026-10-29**.

| Platform | Drums / Looper / session recording | Live effects / processed recording | Recorded verification |
| --- | --- | --- | --- |
| Android | Integrated | Built-ins and amps | Debug APK built; basic permission, monitoring and background flows checked on an x86_64 emulator; real audio interfaces pending |
| iOS | Integrated | Built-ins and amps | Native code integrated; Xcode build and device testing pending |
| Windows | Integrated | Built-ins, amps and VST3 | Build and real-device testing pending |
| macOS | Integrated; raw-input recording | Unavailable | Build and device testing pending |
| Linux | Integrated | Built-ins, amps and VST3 | Debug build, offline DSP and silent interface/buffer checks passed; real playing and physical round-trip latency pending |
| Web | Integrated; raw-input recording | Unavailable | Release build passed; browser/device audio testing pending |

## Start playing

1. Run from source, then open the drum machine workspace. Choose a groove and press the start control.
2. For live effects, connect your guitar to an audio interface and headphones to that same interface. Start at low headphone volume. The workspace checks devices silently; press the monitoring control to hear your guitar. The standalone effects page attempts monitoring automatically.
3. On supported effects platforms, start monitoring at 48 kHz before recording the first Looper layer. On macOS/Web, allow microphone access and use interface direct monitoring if needed. Press the main Looper control again to finish a layer and play it back; press again to overdub.
4. Default shortcuts: **Space** records/overdubs, **S** stops/resumes, **Z** undoes the latest layer, **X** clears all layers. Customize bindings in Looper settings; the app must have focus. Smart recording applies only to the first layer.

Use headphones to avoid feedback and recording the backing track. Drums require no microphone permission; recording, tuning and live effects require audio-input access. Android requires API 24 or later. Apple platforms require microphone permission; Windows must allow microphone access. Linux raw-input recording requires `parecord`, `pactl` and `ffmpeg`. Web requires HTTPS or localhost, microphone permission and a user gesture to unlock audio.

Add “哇音 Wah” and drag its position knob to sweep 350–2200 Hz (position 0–1, default 0.5). Resonance Q is 0.5–8 (2), mix 0–1 (1), and output 0–1 (0.7). Switch between manual (default) and automatic modes on the pedal. Automatic mode exposes speed (0.1–5 Hz, default 1) and depth (0–1, default 0.8), sweeping around the position setting. Expression-pedal control is not included. Wah shares Android/iOS/Linux/Windows DSP; device listening remains unverified.

Mobile effects use the current system audio route and mono input, with no in-app route picker or external VST3 support. Desktop device settings allow input/output and buffer selection; Windows does not bundle the ASIO SDK. Bluetooth is not a low-latency reference output.

## Session recording

The workspace recorder mixes drums, Looper playback and live input into a 48 kHz mono WAV. Select 8–128 MiB (default 32 MiB, about 5.8 minutes); once full, it overwrites the oldest audio. Stop to preview or save. Starting again replaces the unsaved take. Backgrounding stops recording; leaving clears unsaved audio. Effects platforms require monitoring at 48 kHz; live input is captured after effects, before monitor volume. Drums and Looper gains affect the mix. Use headphones; loud mixes clip. Drum and Looper stems are phase-anchored on the first recorded block, advanced by the recorded input frames and drift-corrected slowly (at most 0.2% per block), re-anchoring only when the engine position jumps more than 100 ms; this avoids the per-block timeline tearing caused by the engine's 512-frame (about 10.7 ms) position quantization. Multiple engines are not hardware synchronized, and a fixed first-block offset of up to one buffer remains.

Native saves go to `Guitarbook Recordings` inside the application documents directory, with the path shown. iOS enables Files access; Android currently uses private app storage, removed on uninstall, without a share sheet or folder chooser. Web starts a browser download. Preview/export and playback use memory beyond the recording limit. Device audio and file-access checks remain pending; see the Chinese README for current automated checks.

## Current limits

Drums and Looper run independently: there is no automatic beat synchronization, quantization or time stretching. Unsaved audio stays in local memory and is cleared when leaving the workspace; the session recorder can save a mixed WAV. Audio is not uploaded. Effect chains, device choices and workspace settings are not persisted. Backgrounding stops playback/monitoring; returning does not restart it automatically. No MIDI or global background shortcuts are integrated.

Built-in amps use original algorithms and simple cabinet filtering, without IR convolution or oversampling. Third-party plugins must match the host OS and CPU architecture; they are not bundled. Driver-reported latency is not a physical round-trip measurement. Real-device sound, USB interface compatibility and long-running stability still need verification.

## Run from source

No official installer or hosted app is currently provided. Install Flutter with Dart matching `pubspec.yaml` (currently `^3.12.0`) and the target platform toolchain.

```bash
flutter doctor
flutter pub get
flutter devices
flutter run -d <device-id>
```

Desktop targets can use `linux`, `windows` or `macos`; Web can use `chrome`. iOS builds require macOS and Xcode. Native effects builds fetch JUCE 8.0.12 on first build and require CMake/C++ tooling; Android also needs the NDK and CMake 3.22.1. Follow the dependency licensing requirements, including JUCE's AGPLv3/commercial terms.

See the [detailed Chinese setup and usage guide](README.md), [desktop effects host guide](native/effects_host/README.md), [mobile effects guide](native/mobile_effects/README.md) and [current feature design](docs/FEATURES.md) for dependencies, diagnostics and verification records.

## PRs welcome

Contributions to drum grooves and sound, Looper workflow and synchronization, effects DSP, platform support, accessibility, translations and documentation are welcome! Open an issue first for substantial design changes.

1. Read [AGENTS.md](AGENTS.md) and [docs/FEATURES.md](docs/FEATURES.md).
2. Run `flutter analyze` and `flutter test`; include relevant native build/test results for audio changes.
3. Update affected README translations and feature designs when behavior changes. State which platforms/devices were tested and what remains unverified.

Device reports are valuable too: include your OS, audio interface, sample rate/buffer, reproduction steps and results. Please do not include third-party plugins, restricted sound assets or personal recordings in contributions.
