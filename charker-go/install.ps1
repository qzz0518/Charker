# install.ps1 - install the release build for the current user.
#
#   .\install.ps1                     install build\Charker.exe
#   .\install.ps1 -Uninstall          remove the installed app (keeps user data)
#
# Installs to %LOCALAPPDATA%\Programs\Charker, makes a Desktop shortcut, and
# copies the docs. Run it from the repo root after .\build.ps1 -Mode release.
#
# Why an install step: when the exe is built inside a folder managed by the
# coding agent's sandbox, Windows keeps the sandbox ACLs on the file and the app
# cannot write its WebView2 profile, which shows up as a black window. Copying
# the exe to a normal user folder (and resetting its ACL) fixes that; on a
# normal machine build\Charker.exe runs fine as-is.
[CmdletBinding()]
param(
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Charker'
$exe = Join-Path $installDir 'Charker.exe'

if ($Uninstall) {
  Get-Process Charker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Charker.lnk'
  Remove-Item $lnk -Force -ErrorAction SilentlyContinue
  Write-Host "Charker removed (user data in %APPDATA%\Charker is kept)."
  exit 0
}

$src = Join-Path $here 'build\Charker.exe'
if (-not (Test-Path $src)) {
  throw "build\Charker.exe not found; run .\build.ps1 -Mode release first"
}
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Get-Process Charker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Copy-Item $src $exe -Force
foreach ($f in 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md') {
  $p = Join-Path $here $f
  if (Test-Path $p) { Copy-Item $p $installDir -Force }
}

# Return the file's ACLs to the normal per-user ones (see the comment above).
try {
  & icacls $exe /inheritance:r /grant:r "$($env:USERNAME):(F)" 'NT AUTHORITY\SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null
  & icacls $exe /setintegritylevel Medium | Out-Null
} catch {
  Write-Warning "could not reset the exe ACL: $($_.Exception.Message)"
}

$shell = New-Object -ComObject WScript.Shell
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Charker.lnk'
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $exe
$sc.WorkingDirectory = $installDir
$sc.IconLocation = "$exe,0"
$sc.Description = 'Charker - Anker Prime 160W companion for Windows'
$sc.Save()

Write-Host "Installed $exe"
Write-Host "Desktop shortcut: $lnk"
Write-Host "Tip: turn on demo mode (Devices -> demo) to explore the UI without a charger."
