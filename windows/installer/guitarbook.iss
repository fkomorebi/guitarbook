; ============================================================================
;  GuitarBook / 吉他宝典 —— Windows 安装包脚本 (Inno Setup 6)
; ----------------------------------------------------------------------------
;  【如何手动编译】
;    1. 安装 Inno Setup 6（>= 6.3，6.4 亦可）：
;         winget install JRSoftware.InnoSetup
;       或从 https://jrsoftware.org/isdl.php 下载安装。
;    2. 在仓库根目录执行（推荐，带版本号覆盖）：
;         "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" ^
;           /DAppVersion=1.0.0 ^
;           /O"<仓库绝对路径>\build\installer" ^
;           "windows\installer\guitarbook.iss"
;       若省略 /O，则使用本脚本中的 OutputDir=..\..\build\installer（相对本脚本目录）。
;    3. 更推荐使用封装脚本（会自动编译 Flutter、执行校验、定位 ISCC）：
;         pwsh -File tool/build_windows_installer.ps1
;
;  【打包来源目录】
;    ..\..\build\windows\x64\runner\Release  （即 Flutter Windows release 产物）
;    该目录下的全部内容都会按原样整体打包（递归），包括：
;      - guitarbook.exe              主程序
;      - guitarbook_effects_host.exe  原生 JUCE VST3 宿主（必需！）
;      - flutter_windows.dll / flutter_soloud_plugin.dll / record_windows_plugin.dll
;      - FLAC.dll / ogg.dll / opus.dll / vorbis*.dll（音频编解码依赖）
;      - data\app.so / data\icudtl.dat / data\flutter_assets\ / data\licenses\
;        （licenses 内含 JUCE / VST3 / ASIO 的授权文本，必须随包分发）
;    注意：不要打包 build\windows\x64\install（里面是 JUCE 编译期头文件与静态库，
;          运行时不需要）；本脚本只引用 Release 目录，天然不会包含它。
;
;  【重要：原生特效宿主必须与主程序同目录】
;    guitarbook_effects_host.exe 会被主程序以同目录相对路径拉起，用于加载
;    VST3 插件。若它不在 guitarbook.exe 旁边，特效链路会直接失败。
;    打包时整个 Release 目录必须原样复制，不要挑选文件。
;
;  【编码】本文件必须保存为 "UTF-8 with BOM"，Inno Setup 才能正确识别中文。
; ============================================================================

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; VersionInfoVersion 必须是 4 段纯数字（X.Y.Z.W）。
; 默认由 AppVersion 推导："1.0.0" -> "1.0.0.0"。
; 若需要 4 段版本号，请显式传入： ISCC /DAppVersion=1.0.0 /DAppVersionVersion=1.0.0.5
#ifndef AppVersionVersion
  #define AppVersionVersion AppVersion + ".0"
#endif

#define MyAppName        "吉他宝典 GuitarBook"
#define MyAppExeName     "guitarbook.exe"
#define MyAppPublisher   "com.komorebi"

[Setup]
AppId={{56C273E3-DC17-4DA7-8F7A-F280E3291BBA}
AppName={#MyAppName}
AppVerName={#MyAppName} {#AppVersion}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\GuitarBook
DefaultGroupName=吉他宝典
DisableProgramGroupPage=yes
DisableWelcomePage=no
UninstallDisplayIcon={app}\guitarbook.exe
SetupIconFile=..\runner\resources\app_icon.ico
OutputDir=..\..\build\installer
OutputBaseFilename=guitarbook_setup_{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
VersionInfoVersion={#AppVersionVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} 安装程序
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoTextVersion={#AppVersion}

; ---------------------------------------------------------------------------
; 【安装向导语言】中文（简体）
;   翻译文件：windows\installer\Languages\ChineseSimplified.isl
;             （路径相对于本 .iss 所在目录；UTF-8 with BOM）
;   Inno Setup 官方发行版不自带中文 .isl（6.7.4 的 Languages 目录只有阿拉伯语..乌克兰语），
;   故本项目在仓库内自带一份（[Messages] 键与 6.7.4 的 Default.isl 完全一致，296/296）。
;   默认启用中文向导。若该文件缺失或损坏，构建脚本 tool\build_windows_installer.ps1 会传入
;   /DUseChineseLang=0 跳过本段，安装向导自动回退为 Inno 默认英文界面。
;   应用自身的名称（吉他宝典 / 卸载 GuitarBook）始终是中文，与向导语言无关。
; ---------------------------------------------------------------------------
#ifndef UseChineseLang
  #define UseChineseLang 1
#endif
#if UseChineseLang = 1
[Languages]
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "quicklaunchicon"; Description: "{cm:CreateQuickLaunchIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 整个 Release 目录原样打包（递归），不要挑选文件。
; guitarbook_effects_host.exe 与 data\licenses\ 必须保留。
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\吉他宝典"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autoprograms}\吉他宝典\卸载 GuitarBook"; Filename: "{uninstallexe}"
Name: "{autodesktop}\吉他宝典 GuitarBook"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userappdata}\Microsoft\Internet Explorer\Quick Launch\吉他宝典 GuitarBook.lnk"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: quicklaunchicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\*.log"
Type: filesandordirs; Name: "{app}\logs"
Type: filesandordirs; Name: "{app}\*.tmp"
Type: files; Name: "{app}\Uninstall GuitarBook.lnk"
