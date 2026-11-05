# 移调效果器（kind = `pitch`）DSP 规格（C++ / Web AudioWorklet 双实现共用）

本文件是 C++（`native/effects_host/builtin_effect.h`）与 JS（`web/effects_worklet.js`）两端实现的**唯一权威依据**，与功能设计文档 `docs/FEATURES.md` 的「移调效果器」小节配套使用（功能范围与验收条件以 FEATURES.md 为准，逐样本算法以本文件为准）。
两端必须实现完全相同的算法、相同的参数顺序、相同的常量，使同一输入在两端得到数值一致的结果（浮点误差 ≤ 1e-4）。

---

## 1. 参数表（顺序即 `parameters` 数组下标，两端必须一致）

| 下标 | id       | 名称     | 最小值 | 最大值 | 初始值 | 单位 |
| ---- | -------- | -------- | ------ | ------ | ------ | ---- |
| 0    | semitone | 移调     | -12    | 12     | 0      | 半音 |
| 1    | mix      | 干湿比   | 0      | 1      | 1      |      |
| 2    | level    | 输出     | 0      | 1      | 1      |      |

效果器标题：`移调 Pitch`。

语义：
- `semitone`：移调半音数。0 = 原声；正数升调；负数降调。移调比例 `ratio = 2^(semitone/12)`，因此 ±12 半音 = ±1 个八度。
- `mix`：湿声（移调后的信号）占比，1 = 全湿，0 = 全干（直通）。
- `level`：整体输出增益，作用于最终输出（与 fuzz/overdrive/wah 的输出旋钮一致）。

---

## 2. 状态

每个效果器实例持有（两端一致）：

| 状态 | 类型 | 说明 |
| ---- | ---- | ---- |
| `delay` | int | `D = ceil(rate * 0.03)`（48k → 1440；44.1k → 1323；96k → 2880） |
| `length` | int | `M = D * 2`（环形缓冲长度，两声道各一份） |
| `time` | double | 当前采样时刻，恒在 `[0, M)` 区间内循环 |
| `head[2]` | double | 两个读头位置，恒在 `[0, M)` 区间内循环 |
| `active` | int | 当前使用的读头（0 或 1） |
| `fade` | int | 淡变计数；`-1` 表示当前不在淡变中；否则 `0..F-1` |
| `blend` | double | 直通融合系数，`1` = 全干直通，`0` = 全湿移调声 |
| `filter[2][2]` | double | 每声道二阶（一阶级联）低通状态 |

`prepareToPlay` / 初始化时全部复位：
`delay = ceil(rate*0.03)`、`length = 2*delay`、缓冲区清零、`time = 0`、`head[0] = head[1] = 0`、`active = 0`、`fade = -1`、`blend = 1.0`（0 半音时直通）、`filter` 全 0。

---

## 3. 常量

| 名称 | 值 | 说明 |
| ---- | -- | ---- |
| `D` | `ceil(rate * 0.03)` | 基准延迟（≈30 ms） |
| `M` | `2 * D` | 环形缓冲长度 |
| `minDelay` | `D / 2.0` | 触发切换的下限 |
| `maxDelay` | `D * 1.5` | 触发切换的上限 |
| `F` | `256` | 交叉淡变长度（采样） |
| `blendStep` | `1 - exp(-1 / (rate * 0.015))` | 直通融合系数的一阶平滑步长（15 ms 时间常数） |
| `filterAlpha` | `1 - exp(-2 * pi * 0.4 * rate / rate)` → 等价 `1 - exp(-2*pi*0.4)`，即固定截止 0.4 × 采样率 | 湿声柔化低通（与采样率无关的归一化写法：截止频率 = 0.4 × rate） |

> 说明：`filterAlpha` 的标准写法为 `1 - exp(-2 * pi * cutoff / rate)`，其中 `cutoff = 0.4 * rate`，因此 `filterAlpha = 1 - exp(-2 * pi * 0.4)`，为一个与采样率无关的常量。

---

## 4. 每采样处理流程

参数平滑沿用现有机制：每采样先取 `values[i]`（C++ 为 `smooth[i].getNextValue()`，JS 为已有的 `this.smooth` 机制），再执行下列步骤。**共享状态（time/head/active/fade/blend）的更新每采样只做一次，两个声道共用**（保证立体声像不偏移）。

设当前采样输入为 `in[ch]`，采样率为 `rate`。

### 步骤 A：参数换算（每采样一次）

```
semitone = values[0]
mix      = values[1]
level    = values[2]

ratio      = 2^(semitone / 12)                 // pow(2.0, semitone/12.0)
target     = (|semitone| < 0.01) ? 1.0 : 0.0   // 0 半音 → 直通
blend     += (target - blend) * blendStep
wetGain    = mix * (1 - blend)
```

### 步骤 B：写入与切换（每采样一次）

```
for ch in 0..1:
    buffer[ch][(int) time] = in[ch]        // time 为整数值的 double，落在 [0, M)
time = mod(time + 1.0, M)                 // mod(x, M) = x - floor(x / M) * M，结果在 [0, M)
now = time - 1.0                          // 刚刚写入的采样所处时刻（可能为 -1，下一次 mod 后归一）
now = mod(now, M)                         // 归一到 [0, M)

delay = mod(now - head[active], M)        // 当前读头落后多少采样，取值范围 (0, M)
if (delay < minDelay):
    next = 1 - active
    head[next] = mod(now - (delay + D), M) // 立刻把新读头拉远 D 个采样
    fade = 0
    active = next
else if (delay > maxDelay):
    next = 1 - active
    head[next] = mod(now - (delay - D), M) // 立刻把新读头拉近 D 个采样
    fade = 0
    active = next
```

> 等价说明：`delay` 随 `ratio` 变化——升调（ratio > 1）时读头追近，`delay` 递减；降调时 `delay` 递增；`ratio == 1` 时 `delay` 恒定、不产生切换。

### 步骤 C：读取与混合（每声道）

```
for ch in 0..1:
    wet = read(ch, head[active])
    if (fade >= 0):
        old  = read(ch, head[1 - active])
        t    = fade / (F - 1)             // 0 → 1 线性
        wet  = old * (1 - t) + wet * t
    // 湿声二阶低通（每声道独立状态）
    filter[ch][0] += filterAlpha * (wet - filter[ch][0])
    filter[ch][1] += filterAlpha * (filter[ch][0] - filter[ch][1])
    wet = filter[ch][1]
    out[ch] = (in[ch] * (1 - wetGain) + wet * wetGain) * level
```

### 步骤 D：推进（每采样一次）

```
if (fade >= 0):
    fade += 1
    if (fade >= F): fade = -1
head[0] = mod(head[0] + ratio, M)
head[1] = mod(head[1] + ratio, M)
```

### 读取函数

```
read(ch, position):
    base = floor(position)                 // position ∈ [0, M)
    frac = position - base
    first  = (int) base                    // ∈ [0, M)
    second = (first + 1) % M
    return buffer[ch][first] * (1 - frac) + buffer[ch][second] * frac
```

---

## 5. 行为约定（两端都必须满足）

1. **0 半音完全直通**：`semitone = 0` 时 `blend → 1`，`wetGain → 0`，输出 `= in * level`，无额外延迟、无梳状失真（切换到 0 半音时 `blend` 有 15 ms 平滑，中间会短暂出现轻微梳状过渡，属预期）。
2. **无符号翻转**：`ratio ∈ [0.5, 2]`（因为 `semitone ∈ [-12, 12]`），所有读位置始终落在 `[now - M + 1, now]` 内，环形缓冲不会读到自己未写过的位置。
3. **切换无爆音**：切换瞬间 `fade` 从 0 开始做 256 采样的线性交叉淡化，旧读头继续推进，新读头接管。
4. **延迟量**：湿声路径延迟约 `D`（≈30 ms）；直通路径无延迟。
5. **确定性**：相同输入序列与参数序列 → 相同输出序列（无随机、无依赖外部状态）。
6. **多实例隔离**：两个实例的状态互不影响。

---

## 6. 需要新增/修改的位置

### C++：`native/effects_host/builtin_effect.h`
- 构造器：新增 `kind == "pitch"` 分支，按 §1 顺序 `add("semitone", "移调", -12, 12, 0, "半音")`、`add("mix", "干湿比", 0, 1, 1, "")`、`add("level", "输出", 0, 1, 1, "")`，并设置标题「移调 Pitch」。
- `prepareToPlay`：按 §2 复位 pitch 状态与缓冲。
- `processBlock`：新增 `pitch` 分支，按 §4 处理（与 delay/reverb 一样提前 `return`）。
- `getTailLengthSeconds()`：`pitch` 返回 `0.1`（湿声路径约 30 ms 延迟）。

### JS：`web/effects_worklet.js`
- `createEffectDefinition('pitch')`：按 §1 顺序返回参数表 `{name, min, max, value, unit}`。
- `class BuiltinEffect`：构造函数里初始化 pitch 状态；`reset(sampleRate)` 里按 §2 复位；`processBlock` 的 `switch (kind)` 新增 `case 'pitch'` 分支，按 §4 处理。
- `BUILTIN_KINDS` 数组：在末尾追加 `'pitch'`。

### 测试
- `native/effects_host/builtin_effect_tests.h`：把 `pitch` 纳入所有 kinds 的静音/有限性遍历，并新增针对 §5 的数值断言。
- `tool/effects_worklet_test.js`：`ALL_KINDS` 追加 `'pitch'`，并镜像同样的数值断言。
