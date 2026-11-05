# 用 Inno Setup 7 打 Windows 安装包。
# 用法：pwsh -File tool/build_installer.ps1 -AppVersion 0.1.0+1
param(
  [Parameter(Mandatory = $true)]
  [string] $AppVersion,

  [string] $SourceDir = "build\windows\x64\runner\Release",
  [string] $OutputDir = "dist",
  [string] $InnoSetupCompiler = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$installerScript = Join-Path $repoRoot "installer\GloomyabyssMapEditor.iss"
$iconSource = Join-Path $repoRoot "windows\runner\resources\app_icon.ico"

if (-not (Test-Path $installerScript)) {
  throw "Installer script not found: $installerScript"
}
if (-not (Test-Path $SourceDir)) {
  throw "Windows release bundle not found: $SourceDir"
}
if (-not (Test-Path $iconSource)) {
  throw "Icon source not found: $iconSource"
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 7\ISCC.exe"),
    "C:\Program Files\Inno Setup 7\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 7\ISCC.exe"
  )
  $InnoSetupCompiler = $candidates |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler) -or
    -not (Test-Path $InnoSetupCompiler)) {
  throw "Inno Setup 7 compiler not found. Install Inno Setup 7 or pass -InnoSetupCompiler."
}

$InnoSetupCompiler = (Resolve-Path $InnoSetupCompiler).Path
if (-not $InnoSetupCompiler.EndsWith("\Inno Setup 7\ISCC.exe", [StringComparison]::OrdinalIgnoreCase)) {
  throw "Inno Setup 7 is required. Refusing compiler: $InnoSetupCompiler"
}

$sourceResolved = (Resolve-Path $SourceDir).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputResolved = (Resolve-Path $OutputDir).Path

$arguments = @(
  "/DAppVersion=$AppVersion",
  "/DSourceDir=$sourceResolved",
  "/DOutputDir=$outputResolved",
  "/DIconSource=$iconSource"
)

$zhLang = Join-Path (Split-Path -Parent $InnoSetupCompiler) "Languages\ChineseSimplified.isl"
if (Test-Path $zhLang) {
  $arguments += "/DChineseMessagesFile=$zhLang"
}

$arguments += $installerScript

& $InnoSetupCompiler @arguments
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compiler failed with exit code $LASTEXITCODE"
}
