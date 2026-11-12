# 箱琴 Marimba 效果器规格（跨端权威规格）

本文件是「箱琴（Marimba）」内置效果器在 **桌面 / 移动端 C++ 内核**（`native/effects_host/builtin_effect.h`）
与 **网页端 AudioWorklet DSP**（`web/effects_worklet.js`）之间的**唯一权威规格**。

两端实现必须：

1. 使用同一个 `kind` 名称 `marimba`；
2. 使用相同的参数顺序、名称、量程、默认值与单位；
3. 使用本文件列出的**完全相同的常量**与**完全相同的算法步骤**；
4. 在同一采样率、同一输入下输出误差不超过 `1e-4`（浮点与随机噪声序列均需一致）。

> 与 `docs/pitch_shifter_spec.md` 同等地位：任何一端改动都必须同步另一端与本文件。

---

## 1. 功能定位

把吉他的音高「翻译」成木琴（马林巴）音色：检测输入的音高与起音，用击槌式加法合成重新演奏该音高，
干声保持不变，湿声是木琴的模态音色。

* 不是音高移调（不改旋律音高关系），而是**音色替换 / 叠加**。
* 不是打击采样触发（不需要 MIDI），而是**跟随输入音高自动演奏**。

---

## 2. 参数（顺序即下标，三端必须一致）

| 下标 | id | 中文名 | 最小 | 最大 | 默认 | 单位 |
|---|---|---|---|---|---|---|
| 0 | `transpose` | 移调 | -12 | 12 | 0 | 半音 |
| 1 | `decay` | 衰减 | 0.2 | 4 | 1.2 | s |
| 2 | `tone` | 音色 | 0 | 1 | 0.6 | （无） |
| 3 | `sensitivity` | 触发 | 0 | 1 | 0.5 | （无） |
| 4 | `mix` | 干湿比 | 0 | 1 | 1 | （无） |
| 5 | `level` | 输出 | 0 | 1 | 0.8 | （无） |

* 标题（title）：`箱琴 Marimba`。
* 参数含义：
  * **移调**：木琴音相对检测到的音高再做半音偏移，范围 ±12 半音。
  * **衰减**：基频分音衰减 60 dB 所需时间（秒）。越大余音越长。
  * **音色**：0 = 纯基频（圆润、接近正弦），1 = 高次分音丰富（明亮、接近真实木琴）。
  * **触发**：起音检测灵敏度。越大越容易触发（对安静音符、噪声更敏感）。
  * **干湿比**：木琴湿声占比。0 = 完全干声（纯吉他，**无额外延迟**），1 = 只有木琴。
  * **输出**：整体输出增益，作用于干湿混合之后。

---

## 3. 常量

全部为**编译期/运行期计算的浮点常量**，两端必须使用相同公式与相同运算顺序。

| 名称 | 公式 | 说明 |
|---|---|---|
| `analysisDecimation` | `4` | 抽取倍数 |
| `analysisRate` | `rate / 4.0` | 音高分析采样率 |
| `minFrequency` | `75.0` | 可检测最低频率（约 E2 82.4 Hz 之下留余量） |
| `maxFrequency` | `1100.0` | 可检测最高频率 |
| `maxLag` | `max(3, (int) floor(analysisRate / minFrequency))` | YIN 最大滞后（下限 3，实际 44.1 kHz 及以上为 147/160/320） |
| `lagMin` | `max(2, (int) floor(analysisRate / maxFrequency))` | YIN 最小滞后 |
| `captureLength` | `4 * maxLag` | 捕获缓冲长度（抽取域采样点） |
| `yinWindowLength` | `captureLength - maxLag` | YIN 差分窗口长度 = `3 * maxLag` |
| `decimatorAlpha` | `1 - exp(-2*PI*0.09)` | 抽取低通单极点系数（4 级级联，fc = 0.09*rate） |
| `fastRelease` | `exp(-1 / (rate * 0.010))` | 快包络释放（10 ms） |
| `shortAlpha` | `1 - exp(-1 / (rate * 0.006))` | 短时能量平滑系数（6 ms） |
| `longAlpha` | `1 - exp(-1 / (rate * 0.060))` | 长时能量平滑系数（60 ms） |
| `energyRatio` | `1.6` | 起音判定：短时能量需超过长时能量的倍数 |
| `rearmRatio` | `1.02` | 重新武装：短时能量回落到长时能量的该倍数以内后，才允许检测下一次起音（防止持续音被反复触发成连奏） |
| `refractorySamples` | `(int) (rate * 0.015)` | 起音不应期（15 ms） |
| `onsetThreshold` | `0.05 * pow(0.1, sensitivity)` | 起音绝对阈值（峰值包络） |
| `velocityReference` | `0.30` | 力度换算参考幅度（分母取捕获窗口内的峰值幅度） |
| `velocityFloor` / `velocityCeiling` | `0.25` / `1.0` | 力度上下限 |
| `voiceCount` | `4` | 同时发声的木琴声部数 |
| `partialCount` | `5` | 分音数 |
| `voiceGain` | `0.20` | 单声部分音整体增益（槌击噪声**不**乘该系数） |
| `clickGain` | `0.08` | 槌击噪声初始增益（`clickAmp` 初值 = `clickGain * velocity`） |
| `clickAlpha` | `1 - exp(-2*PI*0.20)` | 槌击噪声高通用低通系数 |
| `clickDecay` | `exp(-1 / (rate * 0.008))` | 槌击噪声衰减（8 ms） |
| `yinThreshold` | `0.15` | YIN 绝对阈值 |
| `energyFloor` | `0.002` | 捕获窗口 RMS 下限 |
| `voiceEndLevel` | `1e-4` | 声部结束阈值（分音包络） |
| `decayTauBase` | `1 / log(1000)` = `0.1447648…` | 衰减参数 → 基频时间常数系数 |

分音表（`partialCount = 5`）：

| p | 频率比 `ratio` | 基值 `base` | 音色增量 `delta` | 衰减系数 `partialDecayFactor` |
|---|---|---|---|---|
| 0 | 1.0 | 1.00 | 0.00 | 1.00 |
| 1 | 2.0 | 0.06 | 0.10 | 0.55 |
| 2 | 3.0 | 0.03 | 0.12 | 0.42 |
| 3 | 4.0 | 0.05 | 0.30 | 0.30 |
| 4 | 6.0 | 0.00 | 0.07 | 0.22 |

* 分音有效幅度 = `base[p] + delta[p] * tone`（线性插值）。
* 分音 p 的衰减时间常数 `tau[p] = (decay / log(1000)) * decayFactor[p]` 秒；
  每采样衰减系数 `decayCoef[p] = exp(-1 / (rate * tau[p]))`。

随机噪声（槌击声）必须用**两端完全一致**的伪随机序列，以便浮点比对：

```
state: uint32, 初始 22222，prepareToPlay 时复位
每采样一次：
  state ^= state << 13;  state ^= state >> 17;  state ^= state << 5;   // xorshift32，uint32 溢出回绕
  noise = ((state & 0xFFFFFF) / 8388607.5) - 1.0;                      // [-1, 1)
```

---

## 4. 逐采样处理流程

每个输入采样点依次执行（左右声道先混为单声道做分析，湿声再按原样加回两声道）：

```
1. x = 0.5 * (inL + inR)                     // 分析用单声道输入
2. a = abs(x)
   fastEnv = max(a, fastEnv * fastRelease)
   power = a * a
   shortEnergy += shortAlpha * (power - shortEnergy)
   longEnergy  += longAlpha  * (power - longEnergy)
3. 起音检测（短时能量相对长时能量突增 = 标准能量比起音检测）：
   // 3.1 重新武装：一次起音触发后必须等能量回落到长时能量附近，才允许下一次起音
   if (!armed && shortEnergy <= longEnergy * rearmRatio) armed = true
   // 3.2 起音判定（捕获进行中忽略新的起音，保证音符起点固定）
   if (armed && !capturing && fastEnv > onsetThreshold
       && shortEnergy > longEnergy * energyRatio
       && samplesSinceOnset >= refractorySamples) {
       samplesSinceOnset = 0
       armed = false
       capturing = true; captureCount = 0; capturePeak = 0
   }
   samplesSinceOnset++
   if (capturing && a > capturePeak) capturePeak = a
   （复位时 `samplesSinceOnset` 的初值取 `refractorySamples`，使**首次起音立即可触发**；
   `armed` 初值为 `true`；
   不应期只用于抑制同一次拨弦的连续重复触发。）
4. 4 倍抽取（4 级单极点低通级联）：
   d1 += decimatorAlpha * (x - d1)
   d2 += decimatorAlpha * (d1 - d2)
   d3 += decimatorAlpha * (d2 - d3)
   d4 += decimatorAlpha * (d3 - d4)
   decimPhase++
   if (decimPhase == analysisDecimation) {
       decimPhase = 0
       if (capturing) {
           captureBuffer[captureCount++] = d4
           if (captureCount == captureLength) {
               capturing = false
               f = detectPitch(captureBuffer, captureLength)   // 见 §5
               if (f > 0) {
                    // 力度取捕获窗口内的峰值幅度（比起音瞬间的包络更稳）
                    velocity = clamp(capturePeak / velocityReference, velocityFloor, velocityCeiling)
                    triggerVoice(f * pow(2, transpose / 12), velocity)
                }
           }
       }
   }
5. 声部合成（最多 voiceCount 个）：
   noise = nextNoise()
   for 每个活动声部 v：
       sum = 0
       for p in 0..partialCount-1:
           v.phase[p] += v.phaseStep[p]
           if (v.phase[p] >= 2*PI) v.phase[p] -= 2*PI
           sum += v.amp[p] * (base[p] + delta[p] * tone) * sin(v.phase[p])
           v.amp[p] *= decayCoef[p]
       v.clickLP += clickAlpha * (noise - v.clickLP)
       click = (noise - v.clickLP) * v.clickAmp
       v.clickAmp *= clickDecay
       wet += sum * voiceGain + click
       若 v.amp[0] < voiceEndLevel 且 v.clickAmp < voiceEndLevel → v.active = false
6. 输出（左右声道各自）：
   outL = (inL * (1 - mix) + wet * mix) * level
   outR = (inR * (1 - mix) + wet * mix) * level
```

### 4.1 `triggerVoice(frequency, velocity)`

```
若无空闲声部 → 抢占「最早触发」的声部（age 最小者）
v.active = true; v.frequency = frequency; v.age = nextVoiceAge++
for p: v.phase[p] = 0; v.amp[p] = 1.0
v.clickAmp = clickGain * velocity
v.clickLP = 0
for p: v.phaseStep[p] = 2*PI * frequency * ratio[p] / rate
```

### 4.2 衰减参数的实时变化

`decay` 变化时（`|decay - lastDecay| > 1e-6`）重新计算 `decayCoef[p]`（全局共享，已发出的声部立即采用新衰减）。
`tone` 直接实时参与每个采样的幅度计算，无需状态。

---

## 5. YIN 音高检测（移植自 `lib/features/tuner/pitch_detector.dart`）

在抽取域（`analysisRate`）上做 YIN，输入是长度 `captureLength` 的捕获缓冲：

```
detectPitch(buf, length):
    maxLag = max(3, floor(analysisRate / minFrequency))
    if (maxLag < 3 || length <= maxLag) return 0
    window = length - maxLag
    // 去均值 + 能量门限
    mean = sum(buf) / length
    energy = sum((buf[i] - mean)^2) / length
    if (sqrt(energy) < energyFloor) return 0
    // 差分 + 累积均值归一化
    cumulative = 0
    difference[0] = 1
    for lag = 1 .. maxLag:
        sum = 0
        for i = 0 .. window-1:
            d = buf[i] - buf[i+lag];  sum += d*d
        cumulative += sum
        difference[lag] = (cumulative == 0) ? 1 : sum * lag / cumulative
    // 首个低于阈值的谷
    lag = lagMin
    while (lag < maxLag - 1):
        if (difference[lag] >= yinThreshold) { lag++; continue }
        while (lag + 1 < maxLag && difference[lag+1] < difference[lag]) lag++
        if (lag >= maxLag) return 0
        left = difference[lag-1]; center = difference[lag]; right = difference[lag+1]
        denominator = left - 2*center + right
        offset = (denominator == 0) ? 0 : 0.5 * (left - right) / denominator
        return analysisRate / (lag + offset)
    return 0
```

---

## 6. 时序与延迟

* 捕获窗口 `captureLength` 个抽取采样点 ≈ `4 * maxLag / analysisRate` = **53.3 ms**（与采样率无关）。
* 因此木琴湿声比起音**固有约 53 ms 的延迟**（与「移调」效果器湿声相对干声有延迟的既有约定一致）。
  **干声不做延迟补偿**，以保证吉他本身零附加延迟、干湿比 = 0 时完全没有延迟。
* 声部最长持续时间 ≈ `decay * 1.333` 秒（`decay` 取最大值 4 s 时约 5.3 s），
  故 `getTailLengthSeconds()` 取 **6.0**。
* 音符起点 = **首个起音** + 捕获窗口。捕获进行中检测到的新起音会被忽略（不重启捕获），
  以保证延迟稳定在 53.3 ms；代价是捕获窗口内（约 53 ms）发生的拨弦可能被丢弃。
* 一次起音触发后，必须等短时能量回落到长时能量的 `rearmRatio`（1.02）以内才会重新武装，
  因此持续音（长音、pad）只会被触发一次，不会连奏。

---

## 7. 已知限制

* 只能识别 75 Hz – 1100 Hz 的音高（约 E2 – 16 品以上的 1 弦 E），超出范围不发声。
* 一次起音只演奏一个音；滑音、揉弦、推弦不会被实时跟随（每次重新起音才会更新音高）。
* 捕获窗口（约 53 ms）内发生的拨弦会被忽略，不会立即发声。
* 强力和弦的多个起音会同时触发多个声部（最多 4 个），可能出现轻微叠加过载。
* 极安静的拨弦可能检测不到起音（可用「触发」参数提高灵敏度）。
* 乐器本身的高次谐波会被当成整体音高的一部分，YIN 取基频，通常结果正确。

---

## 8. 验收标准

两端（C++ / JS）都必须满足：

1. 静音输入 → 输出恒为 0。
2. 参数取极值反复切换 40 块 → 输出无 NaN / Inf，且不产生爆音。
3. 输入 220 Hz 正弦（0.3 幅度）→ 在约 53 ms 后出现一个音高接近 220 Hz 的木琴音（误差 < 5 音分）。
4. `mix = 0` 且 `level = 1` → 输出与输入逐样本完全一致（零附加延迟、无变化）；`level` 作用于最终输出（干湿混合之后），因此非 1 的 `level` 会同时缩放干声。
5. `level = 0` → 输出静音。
6. `transpose` 改变 → 输出音高相应改变（约 1 个八度 ≈ ±1200 音分）。
7. `decay` 改变 → 余音长度明显改变。
8. 两端在 44100 / 48000 / 96000 Hz 下的输出逐样本误差 ≤ `1e-4`。
9. 两个实例并行处理同一输入互不干扰（状态独立）。
