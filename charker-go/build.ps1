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
#
# Both also build the Apple Home helper (..\Matter, Rust) and put
# charker-matter.exe next to the exe; -SkipMatter leaves it out. That needs
# rustup with the MSVC toolchain (Visual Studio Build Tools); rustup picks the
# Rust version from ..\Matter\rust-toolchain.toml. Without MSVC, cross-build
# it on Linux/WSL with mingw-w64 and copy the exe next to Charker.exe:
#   rustup target add x86_64-pc-windows-gnu
#   CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc \
#     cargo build --release --locked --target x86_64-pc-windows-gnu
[CmdletBinding()]
param(
  [ValidateSet('dev', 'release')] [string]$Mode = 'dev',
  [string]$OutDir = 'build',
  [switch]$SkipMatter
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

if (-not $SkipMatter) {
  $matter = Join-Path (Split-Path -Parent $here) 'Matter'
  $target = 'x86_64-pc-windows-msvc'
  if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'cargo not found: install rustup (https://rustup.rs) with the MSVC toolchain, or pass -SkipMatter'
  }
  # From inside the crate, so rustup honours its rust-toolchain.toml.
  Push-Location $matter
  try {
    & cargo build --release --locked --target $target
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
  }
  finally {
    Pop-Location
  }
  $helper = Join-Path $matter "target\$target\release\charker-matter.exe"
  Copy-Item -Force $helper $out
  Write-Host "built $(Join-Path $out 'charker-matter.exe')"
}
