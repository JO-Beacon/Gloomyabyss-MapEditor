# 打包 Windows 发布版。
# 用法：pwsh -File tool/package_windows.ps1 [-Out dist]
param([string]$Out = "dist")

$ErrorActionPreference = "Stop"

flutter build windows --release --no-tree-shake-icons
if ($LASTEXITCODE -ne 0) { throw "构建失败" }

$src = "build/windows/x64/runner/Release"
$dst = Join-Path $Out "GloomyabyssMapEditor"

if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
New-Item -ItemType Directory -Path $dst | Out-Null

Copy-Item "$src\*" $dst -Recurse -Force
Copy-Item LICENSE, NOTICE, THIRD-PARTY-NOTICES.md $dst -Force
Copy-Item licenses $dst -Recurse -Force

Write-Host "打包完成：$dst"
