<#
.SYNOPSIS
  Download and unpack the pinned JUCE sources shared by the native backends.

.DESCRIPTION
  The desktop effects host and the mobile backend both build against JUCE
  8.0.12. This script fills the shared cache in .dart_tool/guitarbook-native so
  later builds (and offline builds) reuse the unpacked sources instead of
  downloading them again.

  The archive is verified against the pinned SHA-256 before it is published, so
  a truncated or tampered download never becomes the cached source tree.

  On Windows the system proxy is honoured automatically: the script reads the
  WinINET proxy settings and uses them for the download. Use -Proxy to
  override the proxy and -Url to point at a mirror of the same archive.

.PARAMETER Tag
  JUCE release tag to fetch. Default 8.0.12.

.PARAMETER Url
  Archive URL. Defaults to the upstream codeload tarball for $Tag.

.PARAMETER Proxy
  Proxy to download through, for example http://127.0.0.1:10808. Defaults to
  the https_proxy environment variable and then the Windows system proxy.

.PARAMETER Destination
  Cache root. Defaults to .dart_tool/guitarbook-native in the repository.

.EXAMPLE
  pwsh -File tool/prepare_juce_sources.ps1

.EXAMPLE
  pwsh -File tool/prepare_juce_sources.ps1 -Proxy http://127.0.0.1:10808
#>
[CmdletBinding()]
param(
  [string] $Tag = '8.0.12',
  [string] $Url = '',
  [string] $Proxy = '',
  [string] $Sha256 = '',
  [string] $Destination = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The checksum is pinned next to the CMake declarations so all three callers
# verify the same bytes.
$knownHashes = @{
  '8.0.12' = 'dec1a8baee5aaec4502b717a421b850e257ab7e9c2efd03766185ec1957cf102'
}

if (-not $Sha256) {
  if (-not $knownHashes.ContainsKey($Tag)) {
    throw "No pinned SHA-256 for JUCE $Tag. Pass -Sha256 explicitly."
  }
  $Sha256 = $knownHashes[$Tag]
}

if (-not $Url) {
  $Url = "https://codeload.github.com/juce-framework/JUCE/tar.gz/refs/tags/$Tag"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Destination) {
  $Destination = Join-Path $repoRoot '.dart_tool/guitarbook-native'
}
$downloadDir = Join-Path $Destination 'downloads'
$sourceDir = Join-Path $Destination "JUCE-$Tag"
$archivePath = Join-Path $downloadDir "JUCE-$Tag.tar.gz"

function Get-SystemProxy {
  # WinINET keeps the proxy the user already configured for the browser.
  try {
    $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($settings.ProxyEnable -eq 1 -and $settings.ProxyServer) {
      $server = [string]$settings.ProxyServer
      # The value can be "host:port" or "http=host:port;https=host:port".
      $entry = if ($server.Contains('=')) {
        ($server -split ';' | Where-Object { $_ -match '^https=' } | Select-Object -First 1)
      } else {
        $server
      }
      if (-not $entry) { $entry = ($server -split ';' | Select-Object -First 1) }
      if ($entry) {
        $hostPort = ($entry -replace '^(https?)=', '')
        if ($hostPort -notmatch '://') { $hostPort = "http://$hostPort" }
        return $hostPort
      }
    }
  } catch {
    # No readable proxy settings: fall back to direct download.
  }
  return $null
}

function Get-ArchiveHash([string] $path) {
  return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Expand-ArchiveTarGz([string] $archive, [string] $target) {
  # Prefer the bsdtar that ships with Windows: it needs no MSYS runtime and
  # works from any shell.
  $systemTar = Join-Path $env:SystemRoot 'System32/tar.exe'
  $tar = $null
  if (Test-Path $systemTar) { $tar = $systemTar }
  if (-not $tar) { $tar = (Get-Command tar.exe -ErrorAction SilentlyContinue) }
  if (-not $tar) { $tar = (Get-Command tar -ErrorAction SilentlyContinue) }
  if ($tar) {
    $tarPath = if ($tar -is [string]) { $tar } else { $tar.Source }
    & $tarPath -xzf $archive -C $target
    if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $archive" }
    return
  }
  # PowerShell 7 on .NET 7+ can read tar archives directly.
  if (-not ('System.Formats.Tar.TarReader' -as [type])) {
    throw 'No tar extractor available. Install the Windows bsdtar (tar.exe) or use Git Bash.'
  }
  [System.Formats.Tar.TarFile]::ExtractToDirectory($archive, $target, $true)
}

if (Test-Path (Join-Path $sourceDir 'modules/juce_core/juce_core.h')) {
  Write-Host "JUCE $Tag already unpacked at $sourceDir"
  exit 0
}

New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

$effectiveProxy = $Proxy
if (-not $effectiveProxy) {
  foreach ($name in @('https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $effectiveProxy = $value; break }
  }
}
if (-not $effectiveProxy) { $effectiveProxy = Get-SystemProxy }
if ($effectiveProxy) {
  Write-Host "Using proxy $effectiveProxy"
} else {
  Write-Host 'No proxy configured; downloading directly.'
}

$needDownload = $true
if (Test-Path $archivePath) {
  $existingHash = Get-ArchiveHash $archivePath
  if ($existingHash -eq $Sha256.ToLowerInvariant()) {
    Write-Host "Archive already present and verified: $archivePath"
    $needDownload = $false
  } else {
    Write-Warning "Cached archive hash mismatch; downloading again."
    Remove-Item $archivePath -Force
  }
}

if ($needDownload) {
  $staging = Join-Path $downloadDir "JUCE-$Tag.tar.gz.part"
  $attempts = 3
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    try {
      Write-Host "Downloading JUCE $Tag (attempt $attempt/$attempts) ..."
      if ($effectiveProxy) {
        Invoke-WebRequest -Uri $Url -OutFile $staging -Proxy $effectiveProxy -UseBasicParsing -MaximumRedirection 5
      } else {
        Invoke-WebRequest -Uri $Url -OutFile $staging -UseBasicParsing -MaximumRedirection 5
      }
      break
    } catch {
      if ($attempt -eq $attempts) { throw }
      Start-Sleep -Seconds (5 * $attempt)
    }
  }
  $downloadedHash = Get-ArchiveHash $staging
  if ($downloadedHash -ne $Sha256.ToLowerInvariant()) {
    Remove-Item $staging -Force -ErrorAction SilentlyContinue
    throw "Checksum mismatch for $Url (expected $Sha256, got $downloadedHash)"
  }
  Move-Item -Path $staging -Destination $archivePath -Force
}

# Publish only a complete, verified extraction.
$stagingDir = Join-Path $Destination "juce-unpack-$Tag"
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
try {
  Expand-ArchiveTarGz $archivePath $stagingDir
  $extracted = Join-Path $stagingDir "JUCE-$Tag"
  if (-not (Test-Path (Join-Path $extracted 'modules/juce_core/juce_core.h'))) {
    throw "Extracted archive does not contain JUCE-$Tag sources."
  }
  if (Test-Path $sourceDir) { Remove-Item $sourceDir -Recurse -Force }
  Move-Item -Path $extracted -Destination $sourceDir
  Write-Host "JUCE $Tag unpacked at $sourceDir"
} finally {
  if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
}
