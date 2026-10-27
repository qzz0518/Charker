# build.ps1 - build Charker for Windows with Go.
#
#   .\build.ps1                 dev build   -> build\charker-dev.exe
#   .\build.ps1 -Mode release   release exe -> build\Charker.exe
#
# The version is the macOS app's: CFBundleShortVersionString in
# ..\Resources\Info.plist, so both platforms ship the same number.
#
# The dev build keeps the console, the WebView2 inspector and the charkerdev
# hooks in dev.go. The release build is a GUI exe with MyGo's production flag.
[CmdletBinding()]
param(
  [ValidateSet('dev', 'release')] [string]$Mode = 'dev',
  [string]$OutDir = 'build'
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here $OutDir
New-Item -ItemType Directory -Force -Path $out | Out-Null

$plist = [xml](Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $here) 'Resources\Info.plist'))
function PlistString($key) { $plist.SelectSingleNode("/plist/dict/key[.='$key']/following-sibling::*[1]").InnerText }
$version = PlistString 'CFBundleShortVersionString'
$identifier = PlistString 'CFBundleIdentifier'
if (-not $version) { throw 'CFBundleShortVersionString not found in Resources\Info.plist' }

Push-Location $here
try {
  if ($Mode -eq 'dev') {
    $exe = Join-Path $out 'charker-dev.exe'
    & go build -trimpath -tags charkerdev -ldflags "-X main.version=$version-dev" -o $exe .
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    Write-Host "built $exe ($version-dev)"
  }
  else {
    $exe = Join-Path $out 'Charker.exe'
    $ld = @(
      '-s', '-w', '-H=windowsgui',
      '-X', 'github.com/egoist/mygo.production=1',
      '-X', 'github.com/egoist/mygo.packageName=Charker',
      '-X', "github.com/egoist/mygo.packageVersion=$version",
      '-X', "github.com/egoist/mygo.packageIdentifier=$identifier",
      '-X', "main.version=$version"
    ) -join ' '
    & go build -trimpath -ldflags $ld -o $exe .
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    Write-Host "built $exe ($version)"
  }
}
finally {
  Pop-Location
}
