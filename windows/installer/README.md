# Windows 安装包（Inno Setup 6）

本目录用于把 Flutter 应用的 Windows Release 产物打包成可分发的安装程序。

| 文件 | 说明 |
| --- | --- |
| `guitarbook.iss` | Inno Setup 6 安装脚本（UTF-8 **带 BOM**，Inno 依赖 BOM 识别中文） |
| `Languages/ChineseSimplified.isl` | 仓库内置的中文（简体）安装向导翻译（UTF-8 带 BOM），Inno 官方发行版不含中文语言文件 |
| `README.md` | 本说明文档 |

---

## 1. 前置条件

| 依赖 | 版本要求 | 用途 |
| --- | --- | --- |
| [Inno Setup 6](https://jrsoftware.org/isdl.php) | **6.3 或更高**（已在 6.7.4 实测通过） | 编译 `.iss` 生成安装包。6.3 之前不支持 `x64compatible` 架构指令 |
| Flutter | 3.x（含 Windows desktop 工具链） | 生成 `build/windows/x64/runner/Release` 产物 |
| Visual Studio | 2022（含 "使用 C++ 的桌面开发" / MSVC 工具链） | Flutter 编译 Windows 原生插件（`flutter_soloud_plugin`、`record_windows_plugin`、JUCE 宿主） |

安装 Inno Setup：

```powershell
winget install JRSoftware.InnoSetup
```

默认安装位置（脚本会自动查找）：`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`、`C:\Program Files\Inno Setup 6\ISCC.exe`、`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`。

---

## 2. 一条命令完成打包

在**仓库根目录**执行：

```powershell
pwsh -File tool/build_windows_installer.ps1
```

该脚本会依次完成：

1. `flutter build windows --release`（除非加 `-SkipFlutterBuild`）；
2. 校验 Release 产物是否包含 `guitarbook.exe`、`guitarbook_effects_host.exe`、`data/app.so`、`data/icudtl.dat`、`data/flutter_assets`；
3. 从 `pubspec.yaml` 的 `version: X.Y.Z+N` 读取版本号（只取 `X.Y.Z`）；
4. 自动定位 `ISCC.exe`；
5. 调用 ISCC 编译 `windows/installer/guitarbook.iss`；
6. 打印安装包路径、大小与打包来源目录。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `-SkipFlutterBuild` | 跳过 Flutter 构建，直接用已有的 `build/windows/x64/runner/Release` 打包 |
| `-Configuration Release\|Profile\|Debug` | 构建配置，默认 `Release` |
| `-OutputDir build/installer` | 安装包输出目录（相对仓库根目录），默认 `build/installer` |
| `-Version 1.2.3` | 指定安装包版本号；不传则取 `pubspec.yaml` |
| `-IsccPath "C:\...\ISCC.exe"` | 指定 ISCC.exe 路径 |
| `-BuildNumber 7` | 可选，传给 Flutter 的 `--build-number` |

示例：

```powershell
# 只重新打包，不重新构建 Flutter
pwsh -File tool/build_windows_installer.ps1 -SkipFlutterBuild

# 指定版本号
pwsh -File tool/build_windows_installer.ps1 -Version 1.2.3
```

---

## 3. 手动调用 ISCC

```powershell
# 在仓库根目录执行
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
    /DAppVersion=1.0.0 `
    /O"$PWD\build\installer" `
    "windows\installer\guitarbook.iss"
```

- `/DAppVersion=1.0.0`：安装包版本号，决定输出文件名 `guitarbook_setup_1.0.0.exe`。
- `/O<目录>`：输出目录。省略时使用脚本内的 `OutputDir=..\..\build\installer`（相对 `.iss` 所在目录）。
- `/DAppVersionVersion=1.0.0.0`：可选，用于指定 4 段数字版本（写入 Windows 版本信息）。不传时由 `AppVersion` 自动推导（`1.0.0` → `1.0.0.0`）。
- `/DUseChineseLang=0`：可选。默认安装向导为**中文**（读取 `windows/installer/Languages/ChineseSimplified.isl`）；传 `0` 则跳过 `[Languages]` 段，向导回退为 Inno 默认英文界面。`tool/build_windows_installer.ps1` 会在翻译文件缺失或损坏时自动传 `0`。

---

## 4. 输出

```
build/installer/guitarbook_setup_<version>.exe
```

例如 `build\installer\guitarbook_setup_1.0.0.exe`。`build/` 目录已在 `.gitignore` 中，不会进入版本库。

安装包默认行为：

- 安装目录：`%LOCALAPPDATA%\Programs\GuitarBook`（普通用户即可安装，**不需要管理员权限 / 不弹 UAC**）；在安装向导中可改选"为所有用户安装"。
- 开始菜单程序组：`吉他宝典`，其中含"卸载 GuitarBook"。
- 桌面快捷方式与快速启动栏快捷方式：默认**不勾选**，可在安装时勾选。
- 安装完成后自动启动 `guitarbook.exe`（静默安装 `/VERYSILENT` 时不启动）。

---

## 5. 安装与卸载验证（推荐：双击安装包走图形向导）

推荐用法是**双击 `guitarbook_setup_<version>.exe` 按向导安装**：一路「下一步」即装到 `%LOCALAPPDATA%\Programs\GuitarBook`，不需要管理员权限、不弹 UAC；卸载走「开始菜单 → 吉他宝典 → 卸载 GuitarBook」或「设置 → 应用 → 已安装的应用 → 卸载」。

若需要脚本化安装，再使用下面的静默参数：

```powershell
$setup = ".\build\installer\guitarbook_setup_1.0.0.exe"

# 静默安装到默认目录（当前用户）
& $setup /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
Start-Sleep -Seconds 5

# 确认文件已就位
$app = "$env:LOCALAPPDATA\Programs\GuitarBook"
Test-Path "$app\guitarbook.exe"
Test-Path "$app\guitarbook_effects_host.exe"
Test-Path "$app\data\app.so"
Test-Path "$app\data\licenses"

# 静默卸载
& "$app\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

> `guitarbook_effects_host.exe` 是原生 JUCE VST3 宿主，必须与 `guitarbook.exe` 位于同一目录，否则特效链路无法工作。安装包会把整个 Release 目录原样复制，**不要手工挑选文件**。
> `data\licenses\` 内含 JUCE / VST3 / ASIO 的授权文本，必须随安装包分发。
> 静默安装在自动化沙箱进程（如 CI 流水线、助手代理进程）里可能被系统拒绝写「用户开始菜单目录」与 `HKCU\...\Uninstall` 卸载注册表键，表现为退出码 4 并自动回滚；这是该环境对安装器进程的限制，不是安装包缺陷（同一环境下任何 Inno Setup 安装包，包括最小对照包，都会复现同样的拒绝）。普通交互会话中按图形向导安装不受影响。

---

## 6. 注意事项

- **安装包未做代码签名**。Windows SmartScreen 可能弹出"Windows 已保护你的电脑 / 未知发布者"，选择"更多信息 → 仍要运行"即可。正式分发建议接入代码签名证书。
- **安装向导语言为中文（简体）**，翻译文件为 `windows/installer/Languages/ChineseSimplified.isl`（UTF-8 带 BOM）。Inno Setup 官方发行版只内置阿拉伯语..乌克兰语，没有中文，故本仓库自带一份；其 `[Messages]` 键与 Inno Setup 6.7.4 的 `Default.isl` 完全一致（296 / 296，无缺无多），已用 6.7.4 实测编译通过。若该文件缺失或损坏，封装脚本会自动以英文向导回退，不会中断打包。
- `build/windows/x64/install`（JUCE 编译期头文件与静态库）**不会**被打包，它不在 Release 目录内。
- `.iss` 文件必须保持 UTF-8 **带 BOM**；若用编辑器保存成无 BOM，中文会乱码。
- 修改安装逻辑后，请同步更新本文件与仓库根目录的 `README.md` / `docs/FEATURES.md`。
