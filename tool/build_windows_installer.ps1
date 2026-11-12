#Requires -Version 7.0
<#
.SYNOPSIS
    构建 GuitarBook（吉他宝典）Windows 安装包（Inno Setup 6）。

.DESCRIPTION
    本脚本完成一次完整的 Windows 安装包打包流程：
      1. （可选）执行 `flutter build windows --release` 生成 Release 产物；
      2. 校验 Release 目录中必须存在的运行时文件（主程序、原生特效宿主、Flutter 运行时数据）；
      3. 从 pubspec.yaml 读取版本号（或使用 -Version 指定的版本号）；
      4. 定位 Inno Setup 6 的 ISCC.exe；
      5. 调用 ISCC 编译 windows\installer\guitarbook.iss，输出 build\installer\guitarbook_setup_<version>.exe。

    脚本不需要管理员权限，普通用户即可运行。

.PARAMETER SkipFlutterBuild
    跳过 `flutter build windows` 步骤，直接使用已有的
    build\windows\x64\runner\<Configuration> 目录内容打包。
    适用于本地已经有最新 Release 产物、只想重新生成安装包的场景。

.PARAMETER Configuration
    构建配置：Release（默认）、Profile 或 Debug。
    对应的产物目录为 build\windows\x64\runner\<Configuration>。

.PARAMETER OutputDir
    安装包输出目录，相对于仓库根目录，默认 build/installer。

.PARAMETER Version
    安装包版本号（X.Y.Z）。不传时自动从 pubspec.yaml 的 `version: X.Y.Z+N` 中读取。
    显式传入时会作为 ISCC 的 /DAppVersion 参数，并同时传给 Flutter 的 --build-name。

.PARAMETER IsccPath
    ISCC.exe 的完整路径。不传时依次尝试：PATH -> 三个常见安装位置。

.PARAMETER BuildNumber
    可选的 Flutter --build-number（仅当显式提供时才传给 flutter build）。

.EXAMPLE
    pwsh -File tool/build_windows_installer.ps1
    使用 pubspec.yaml 中的版本号，编译 Flutter 并生成 build\installer\guitarbook_setup_1.0.0.exe。

.EXAMPLE
    pwsh -File tool/build_windows_installer.ps1 -SkipFlutterBuild -Version 1.2.3
    跳过 Flutter 构建，用已有 Release 产物打包出 guitarbook_setup_1.2.3.exe。

.NOTES
    需要：Flutter 3.x（Windows desktop 工具链）、Visual Studio 2022（含 MSVC C++ 生成工具）、
    Inno Setup 6.3 或更高版本（需要 x64compatible 架构指令）。
#>
[CmdletBinding()]
param(
    [switch]$SkipFlutterBuild,
    [string]$Configuration = 'Release',
    [string]$OutputDir = 'build/installer',
    [string]$Version,
    [string]$IsccPath,
    [string]$BuildNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# 基础路径与工具函数
# --------------------------------------------------------------------------
$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:IssPath  = Join-Path $script:RepoRoot 'windows\installer\guitarbook.iss'

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-PubspecVersion {
    param([Parameter(Mandatory = $true)][string]$RepoRootPath)
    $pubspecPath = Join-Path $RepoRootPath 'pubspec.yaml'
    if (-not (Test-Path -LiteralPath $pubspecPath)) {
        throw "找不到 pubspec.yaml：$pubspecPath"
    }
    $content = Get-Content -LiteralPath $pubspecPath -Raw
    $match = [regex]::Match($content, '(?m)^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$')
    if (-not $match.Success) {
        throw "无法从 pubspec.yaml 中解析版本号（应形如 ``version: 1.0.0+1``）。"
    }
    $name = $match.Groups[1].Value
    $build = $match.Groups[2].Value
    if (-not [string]::IsNullOrEmpty($build)) {
        return [pscustomobject]@{ Version = $name; BuildNumber = $build }
    }
    return [pscustomobject]@{ Version = $name; BuildNumber = '' }
}

function Get-FlutterExecutable {
    $cmd = Get-Command 'flutter' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        return $cmd.Source
    }
    $flutterRoot = [Environment]::GetEnvironmentVariable('FLUTTER_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($flutterRoot)) {
        $candidate = Join-Path $flutterRoot 'bin\flutter.bat'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-IsccExecutable {
    param([string]$ExplicitPath)

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add($ExplicitPath)
    }

    $onPath = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($null -ne $onPath) {
        $candidates.Add($onPath.Source)
    }

    # 三个常见的 Inno Setup 6 安装位置（按用户 / 按机器）
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $candidates.Add((Join-Path $localAppData 'Programs\Inno Setup 6\ISCC.exe'))

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates.Add((Join-Path $programFiles 'Inno Setup 6\ISCC.exe'))
    }
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates.Add((Join-Path $programFilesX86 'Inno Setup 6\ISCC.exe'))
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

# --------------------------------------------------------------------------
# 1. 确定版本号
# --------------------------------------------------------------------------
Write-Step '检查版本号'
$pubspecVersion = $null
if ([string]::IsNullOrWhiteSpace($Version)) {
    $pubspecVersion = Get-PubspecVersion -RepoRootPath $script:RepoRoot
    $Version = $pubspecVersion.Version
    Write-Ok "版本号来自 pubspec.yaml：$Version（安装包文件名只使用 X.Y.Z 部分）"
} else {
    $pubspecVersion = Get-PubspecVersion -RepoRootPath $script:RepoRoot
    if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
        throw "版本号格式不正确：'$Version'，应为 X.Y.Z 或 X.Y.Z.W。"
    }
    Write-Ok "使用命令行指定的版本号：$Version"
}
$VersionParts = $Version.Split('.')
if ($VersionParts.Count -eq 3) {
    $AppVersionVersion = "$Version.0"
} else {
    $AppVersionVersion = $Version
}
Write-Ok "VersionInfoVersion（4 段数字）：$AppVersionVersion"

# --------------------------------------------------------------------------
# 2. 构建 Flutter Release 产物
# --------------------------------------------------------------------------
$runnerDir = Join-Path $script:RepoRoot ("build\windows\x64\runner\" + $Configuration)

if ($SkipFlutterBuild) {
    Write-Step '跳过 Flutter 构建（-SkipFlutterBuild）'
    Write-Ok "直接使用已有产物：$runnerDir"
} else {
    Write-Step "执行 flutter build windows（$Configuration）"
    $flutterExe = Get-FlutterExecutable
    if ($null -eq $flutterExe) {
        throw "找不到 flutter 命令。请先安装 Flutter 3.x 并把 flutter\bin 加入 PATH，或设置 FLUTTER_ROOT 环境变量。"
    }
    Write-Ok "flutter：$flutterExe"

    $flutterArgs = @('build', 'windows')
    switch ($Configuration.ToLowerInvariant()) {
        'release' { $flutterArgs += '--release' }
        'profile' { $flutterArgs += '--profile' }
        'debug'   { $flutterArgs += '--debug' }
        default   { throw "不支持的 Configuration：$Configuration（可选 Release / Profile / Debug）" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $flutterArgs += @('--build-name', $Version)
    }
    $flutterBuildNumber = $BuildNumber
    if ([string]::IsNullOrWhiteSpace($flutterBuildNumber) -and $null -ne $pubspecVersion -and -not [string]::IsNullOrWhiteSpace($pubspecVersion.BuildNumber)) {
        $flutterBuildNumber = $pubspecVersion.BuildNumber
    }
    if (-not [string]::IsNullOrWhiteSpace($flutterBuildNumber)) {
        $flutterArgs += @('--build-number', $flutterBuildNumber)
    }

    Write-Host ("    命令：" + ($flutterExe + ' ' + ($flutterArgs -join ' '))) -ForegroundColor DarkGray
    Push-Location $script:RepoRoot
    try {
        & $flutterExe @flutterArgs
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build windows 失败，退出码：$LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    Write-Ok 'Flutter 构建完成'
}

# --------------------------------------------------------------------------
# 3. 校验打包内容
# --------------------------------------------------------------------------
Write-Step '校验 Release 产物'
if (-not (Test-Path -LiteralPath $runnerDir -PathType Container)) {
    Write-Fail "找不到构建产物目录：$runnerDir"
    throw "找不到构建产物目录：$runnerDir。请先执行 flutter build windows，或不要使用 -SkipFlutterBuild。"
}

$requiredEntries = @(
    'guitarbook.exe',
    'guitarbook_effects_host.exe',
    'data\app.so',
    'data\icudtl.dat',
    'data\flutter_assets'
)
$missing = New-Object System.Collections.Generic.List[string]
foreach ($entry in $requiredEntries) {
    $full = Join-Path $runnerDir $entry
    if (-not (Test-Path -LiteralPath $full)) {
        $missing.Add($entry)
    }
}
if ($missing.Count -gt 0) {
    Write-Fail ("缺失以下必需文件：" + ($missing -join '、'))
    throw ("Release 产物不完整，缺失：$($missing -join '、')" +
           "`n产物目录：$runnerDir" +
           "`n请重新执行 ``flutter build windows --release`` 后再打包。")
}
Write-Ok "必需文件齐全（guitarbook.exe / guitarbook_effects_host.exe / data\app.so / data\icudtl.dat / data\flutter_assets）"

$licensesDir = Join-Path $runnerDir 'data\licenses'
if (Test-Path -LiteralPath $licensesDir) {
    $licenseFiles = (Get-ChildItem -LiteralPath $licensesDir -File | Measure-Object).Count
    Write-Ok "已包含 data\licenses（$licenseFiles 个授权文件，JUCE / VST3 / ASIO 授权文本）"
} else {
    Write-Warn '未找到 data\licenses 目录，请确认打包内容是否完整。'
}

# build\windows\x64\install 是 JUCE 编译期产物，不应被打包
$installDir = Join-Path $script:RepoRoot 'build\windows\x64\install'
if (Test-Path -LiteralPath $installDir) {
    Write-Ok '已确认 build\windows\x64\install（JUCE 编译期文件）不在打包范围内'
}

# --------------------------------------------------------------------------
# 4. 定位 ISCC.exe
# --------------------------------------------------------------------------
Write-Step '定位 Inno Setup 6（ISCC.exe）'
$iscc = Get-IsccExecutable -ExplicitPath $IsccPath
if ($null -eq $iscc) {
    Write-Fail '未找到 ISCC.exe'
    throw ("未找到 Inno Setup 6 的 ISCC.exe。请安装 Inno Setup 6（>= 6.3）后再试：`n" +
           "    winget install JRSoftware.InnoSetup`n" +
           "或从 https://jrsoftware.org/isdl.php 下载安装；" +
           "也可以用 -IsccPath 参数直接指定 ISCC.exe 的完整路径。")
}
Write-Ok "ISCC：$iscc"

# --------------------------------------------------------------------------
# 5. 编译安装包
# --------------------------------------------------------------------------
Write-Step '编译安装包'
if (-not (Test-Path -LiteralPath $script:IssPath -PathType Leaf)) {
    throw "找不到 Inno Setup 脚本：$script:IssPath"
}

$outputDirAbs = Resolve-AbsolutePath -Path $OutputDir -BasePath $script:RepoRoot
if (-not (Test-Path -LiteralPath $outputDirAbs)) {
    New-Item -ItemType Directory -Path $outputDirAbs -Force | Out-Null
}
Write-Ok "输出目录：$outputDirAbs"

$expectedName = "guitarbook_setup_$Version.exe"
$expectedPath = Join-Path $outputDirAbs $expectedName

# --------------------------------------------------------------------------
# 5.1 中文安装向导翻译（可选，缺失时回退为 Inno 默认英文界面）
# --------------------------------------------------------------------------
Write-Step '检查中文安装向导翻译'
$islPath = Join-Path (Split-Path -Parent $script:IssPath) 'Languages\ChineseSimplified.isl'
$useChineseLang = $false
if (Test-Path -LiteralPath $islPath -PathType Leaf) {
    $islFile = Get-Item -LiteralPath $islPath
    $islHead = ''
    try {
        $islHead = ((Get-Content -LiteralPath $islPath -TotalCount 5 -ErrorAction SilentlyContinue) -join ' ')
    } catch {
        $islHead = ''
    }
    # 有效的 .isl 至少 1KB；若下载失败通常会得到 "404: Not Found" 之类的错误页
    $islValid = ($islFile.Length -ge 1024) -and ($islHead -notmatch '404|Not Found')
    if ($islValid) {
        $useChineseLang = $true
        Write-Ok "使用中文安装向导翻译：$islPath"
    } else {
        Write-Warn ("中文翻译文件不可用（{0} 字节，内容疑似下载错误页），安装向导将使用英文界面。" -f $islFile.Length)
    }
} else {
    Write-Warn "未找到 Languages\ChineseSimplified.isl，安装向导将使用 Inno 默认英文界面。"
}

Push-Location $script:RepoRoot
try {
    $isccArgs = @("/DAppVersion=$Version", "/DAppVersionVersion=$AppVersionVersion", "/O$outputDirAbs")
    if ($useChineseLang) {
        $isccArgs += '/DUseChineseLang=1'
    } else {
        $isccArgs += '/DUseChineseLang=0'
    }
    $isccArgs += $script:IssPath
    & $iscc @isccArgs
    $isccExit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($isccExit -ne 0) {
    Write-Fail "ISCC 编译失败，退出码：$isccExit"
    throw "Inno Setup 编译失败，退出码：$isccExit。请查看上方 ISCC 输出。"
}

if (-not (Test-Path -LiteralPath $expectedPath -PathType Leaf)) {
    $produced = @(Get-ChildItem -LiteralPath $outputDirAbs -Filter 'guitarbook_setup_*.exe' -ErrorAction SilentlyContinue)
    if ($produced.Count -eq 0) {
        throw "ISCC 执行成功但没有找到安装包，输出目录：$outputDirAbs"
    }
    $expectedPath = ($produced | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

# --------------------------------------------------------------------------
# 6. 输出摘要
# --------------------------------------------------------------------------
$installer = Get-Item -LiteralPath $expectedPath
$sizeMb = [math]::Round($installer.Length / 1MB, 2)

Write-Host ''
Write-Host '==================== 打包完成 ====================' -ForegroundColor Green
Write-Host ("安装包路径 : {0}" -f $installer.FullName)
Write-Host ("安装包大小 : {0} MB" -f $sizeMb)
Write-Host ("打包来源   : {0}" -f $runnerDir)
Write-Host ("版本号     : {0}（VersionInfoVersion: {1}）" -f $Version, $AppVersionVersion)
Write-Host ("源脚本     : {0}" -f $script:IssPath)
Write-Host '===================================================='
Write-Host ''
Write-Host '提示：安装包未做代码签名，Windows SmartScreen 可能提示"未知发布者"。' -ForegroundColor Yellow
Write-Host ("      静默安装验证： & ""{0}"" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -f $installer.FullName)
