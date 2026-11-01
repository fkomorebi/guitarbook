# Guitarbook · 吉他宝典

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md)

A Flutter guitar toolkit for practicing and improvising: build a groove with the drum machine, layer phrases with the Looper, and shape your sound with live effects.

## Drum machine × Looper × Effects

- **Drum machine:** 12 simplified practice grooves—rock, funk, blues, pop, folk, punk, metal, disco, reggae, hip-hop, jazz swing and Latin. Edit kick, snare and hi-hat in a one-bar, 16-step 4/4 sequencer; set 30–240 BPM, swing, track mutes and playback volume.
- **Looper:** record a first loop from 0.3 to 30 seconds and build up to 6 layers. Undo the latest layer, stop/resume or clear everything. Smart first-layer recording measures background noise, starts when you play and trims the ends after about two seconds of silence. Bind keyboard keys or a USB footswitch that sends keyboard input.
- **Live effects:** fuzz, compressor, reverb, overdrive, delay and switchable manual/automatic wah, plus four original amp styles: American clean, British chime, British rock and modern high gain. Chain up to 8 instances, drag to reorder, adjust independent parameters and bypass pedals. Linux and Windows also load locally installed, compatible VST3 effects, and can use a gamepad's analog trigger as a wah expression pedal. A desktop browser build offers the same built-in pedals and amps (implemented in this round; automated whole-page testing passed, real-hardware tone pending; no VST3 and no wet Looper).
- **One workspace:** open the drum machine from the home screen to access drums, Looper and effects together, with separate volume controls. On Android, iOS, Linux and Windows, the Looper captures the processed signal after the effects chain; monitoring must be active and the actual sample rate must be 48 kHz.

The toolkit also includes a standard-tuning guitar tuner, metronome, scale fretboard and beginner chord lessons. README translations do not imply a translated app interface.

## Platform status

Implementation and verification are separate. Existing platform projects do not guarantee device compatibility. Status below reflects the project records as of **2026-11-01**.

| Platform | Drums / Looper / session recording | Live effects / processed recording | Recorded verification |
| --- | --- | --- | --- |
| Android | Integrated | Built-ins and amps | Debug APK built; basic permission, monitoring and background flows checked on an x86_64 emulator; real audio interfaces pending |
| iOS | Integrated | Built-ins and amps | Native code integrated; Xcode build and device testing pending |
| Windows | Integrated | Built-ins, amps, VST3 and gamepad-trigger wah expression | Build and real-device testing pending (gamepad input layer not built or run) |
| macOS | Integrated; raw-input recording | Unavailable | Build and device testing pending |
| Linux | Integrated | Built-ins, amps, VST3 and gamepad-trigger wah expression | Debug build, offline DSP and silent interface/buffer checks passed; real playing, gamepad hardware/permissions and physical round-trip latency pending |
| Web | Integrated; raw-input recording | Built-in pedals and amps in a desktop browser (implemented in this round; automated whole-page testing passed; no VST3, no wet Looper) | Release build passed; automated browser tests passed, real-device audio testing pending |

## Start playing

1. Run from source, then open the drum machine workspace. Choose a groove and press the start control.
2. For live effects, connect your guitar to an audio interface and headphones to that same interface. Start at low headphone volume. The workspace checks devices silently; press the monitoring control to hear your guitar. The standalone effects page attempts monitoring automatically.
3. On supported effects platforms, start monitoring at 48 kHz before recording the first Looper layer. On macOS/Web, allow microphone access and use interface direct monitoring if needed. Press the main Looper control again to finish a layer and play it back; press again to overdub.
4. Default shortcuts: **Space** records/overdubs, **S** stops/resumes, **Z** undoes the latest layer, **X** clears all layers. Customize bindings in Looper settings; the app must have focus. Smart recording applies only to the first layer.

Use headphones to avoid feedback and recording the backing track. Drums require no microphone permission; recording, tuning and live effects require audio-input access. Android requires API 24 or later. Apple platforms require microphone permission; Windows must allow microphone access. Linux raw-input recording requires `parecord`, `pactl` and `ffmpeg`. Web requires HTTPS or localhost, microphone permission and a user gesture to unlock audio.

Add “哇音 Wah” and drag its position knob to sweep 350–2200 Hz (position 0–1, default 0.5). Resonance Q is 0.5–8 (2), mix 0–1 (1), and output 0–1 (0.7). Switch between manual (default) and automatic modes on the pedal. Automatic mode exposes speed (0.1–5 Hz, default 1) and depth (0–1, default 0.8), sweeping around the position setting. On Linux and Windows desktop, an optional gamepad analog trigger can drive the wah position as an expression pedal (see below). Wah shares Android/iOS/Linux/Windows DSP; device listening remains unverified.

Mobile effects use the current system audio route and mono input, with no in-app route picker or external VST3 support. Desktop device settings allow input/output and buffer selection; Windows does not bundle the ASIO SDK. Bluetooth is not a low-latency reference output.

Desktop browser effects (this round's implementation): a desktop browser (Chrome / Edge) offers the same built-in pedals and amps through Web Audio's AudioWorklet, with the DSP ported from the native C++/JUCE code to JavaScript. Connect the guitar to an audio interface and headphones to that same interface, turn off the interface's direct monitoring, then press the monitoring control and grant microphone access — the browser needs that user gesture to unlock audio, and the page must be served over HTTPS or localhost. Limits: latency follows the browser I/O buffer (typically 20–40 ms, versus about 16 ms for the native 128-frame path), output goes to the system default device only and cannot be switched inside the page, the input channel cannot be chosen, there is no VST3 or device-settings window, the Looper records the dry signal instead of the processed chain, and reloading or crashing the page loses the whole chain. The browser reverb is a Freeverb-equivalent implementation and does not match the native JUCE Reverb sample for sample. Verification (2026-11-02): `dart analyze lib` reports no issues and `flutter build web --release` succeeds with `effects_worklet.js` bundled next to the app. A whole-page automated run (real build/web output in desktop Chrome 156 with a fake microphone device) passed 29 / 29 checks — entering the page from the home screen starts monitoring on its own, the AudioContext runs at 48 kHz, getUserMedia is called with echo cancellation, noise suppression and automatic gain control disabled on a mono track, the AudioWorkletNode `guitarbook-effects` is created, level meters report, the output equals the input scaled by the 50 % output volume, adding the overdrive pedal updates the chain to 1/8, and a page that was never activated shows the Chinese gesture prompt until the monitoring control starts the chain. The automated environment reports fake-device latency (baseLatency 10.7 ms, outputLatency 54–85 ms) that is not a real-device baseline; real guitar tone, measured round-trip latency and Edge remain pending.

## Gamepad trigger expression pedal (Linux / Windows)

On Linux and Windows desktop, a gamepad's analog trigger can act as a wah expression pedal. The feature is off by default: add “哇音 Wah”, enable the “gamepad trigger → wah pedal” card below the pedalboard, choose the left or right trigger and the target wah instance, and optionally invert and calibrate its range. Trigger readings are written to the wah position parameter (350–2200 Hz) at a 25 ms throttle. Position is only written while the target wah is in manual mode, monitoring is running and a trigger reading exists; automatic wah mode, stopped monitoring, no wah in the chain or no selected target skip writes and explain why in the card. Disabling the switch or leaving the page releases the input device.

Linux reads `/dev/input/event*` directly: gamepads with an analog trigger axis are discovered from `/proc/bus/input/devices`, hot-plug reconnection is supported, and the driver's actual axis range is read when available (commonly 0–255 or 0–1023). Most desktop distributions grant access to the logged-in user automatically; if access is denied, add the user to the `input` group (`sudo usermod -aG input $USER`, then log in again) or install a udev rule for the controller. Flatpak/Snap sandboxes may block `/dev/input`. Windows polls XInput for the left/right trigger (0–255) and recognises XInput-compatible (Xbox-family) controllers only; PlayStation controllers need Steam Input or DS4Windows mapping first. Android, iOS, macOS and Web do not read gamepad input and show an unsupported note.

Verification (2026-11-01): static analysis passed; the full Flutter suite passes with 151 tests (42 new); a Linux debug build succeeded. Tests cover evdev event and `/proc` parsing, axis-range decoding, Linux input-layer errors and reconnection, normalisation/calibration/inversion, and the effects page's 25 ms throttled writes, automatic-mode skip, no-target and unsupported-platform hints, and a 320 px double-text-scale layout. This machine has no `/dev/input` and no physical gamepad, so the Linux input layer was verified with synthetic events and regular-file paths only; **real hardware, desktop permissions and listening results remain unverified**. The Windows input layer has not been built or run, and other platforms are not integrated. Bluetooth connections and third-party controller axis mappings are also unverified.

## Session recording

The workspace recorder mixes drums, Looper playback and live input into a 48 kHz mono WAV. Select 8–128 MiB (default 32 MiB, about 5.8 minutes); once full, it overwrites the oldest audio. Stop to preview or save. Starting again replaces the unsaved take. Backgrounding stops recording; leaving clears unsaved audio. Effects platforms require monitoring at 48 kHz; live input is captured after effects, before monitor volume. Drums and Looper gains affect the mix. Use headphones; loud mixes clip. Drum and Looper stems are phase-anchored on the first recorded block, advanced by the recorded input frames and drift-corrected slowly (at most 0.2% per block), re-anchoring only when the engine position jumps more than 100 ms; this avoids the per-block timeline tearing caused by the engine's 512-frame (about 10.7 ms) position quantization. Multiple engines are not hardware synchronized, and a fixed first-block offset of up to one buffer remains.

Native saves go to `Guitarbook Recordings` inside the application documents directory, with the path shown. iOS enables Files access; Android currently uses private app storage, removed on uninstall, without a share sheet or folder chooser. Web starts a browser download. Preview/export and playback use memory beyond the recording limit. Device audio and file-access checks remain pending; see the Chinese README for current automated checks.

## Current limits

Drums and Looper run independently: there is no automatic beat synchronization, quantization or time stretching. Unsaved audio stays in local memory and is cleared when leaving the workspace; the session recorder can save a mixed WAV. Audio is not uploaded. Effect chains, device choices and workspace settings are not persisted. Backgrounding stops playback/monitoring; returning does not restart it automatically. No MIDI or global background shortcuts are integrated. The gamepad trigger is used only for wah expression, not for Looper pedal bindings.

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
