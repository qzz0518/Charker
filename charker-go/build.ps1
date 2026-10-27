# build.ps1 - build Charker for Windows.
#
#   .\build.ps1                 dev build -> build\charker-dev.exe
#   .\build.ps1 -Mode release   release   -> build\windows-amd64\ (mygo build:
#                               Charker.exe, charker-setup-<version>-amd64.exe
#                               and, with the update key, the update files)
#
# The version is the macOS app's: CFBundleShortVersionString in
# ..\Resources\Info.plist, so both platforms ship the same number
# (mygo.config.ts reads it for release builds).
#
# The dev build keeps the console, the WebView2 inspector and the charkerdev
# hooks in dev.go.
#
# Both first build the Apple Home helper (..\Matter, Rust), charker-matter.exe;
# -SkipMatter leaves it out of dev builds. That needs rustup with the MSVC
# toolchain (Visual Studio Build Tools); rustup picks the Rust version from
# ..\Matter\rust-toolchain.toml. Without MSVC, cross-build it on Linux/WSL
# with mingw-w64 (mygo.config.ts finds that build too):
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
$root = Split-Path -Parent $here
$out = Join-Path $here $OutDir
New-Item -ItemType Directory -Force -Path $out | Out-Null

$plist = [xml](Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Resources\Info.plist'))
$version = $plist.SelectSingleNode("/plist/dict/key[.='CFBundleShortVersionString']/following-sibling::*[1]").InnerText
if (-not $version) { throw 'CFBundleShortVersionString not found in Resources\Info.plist' }

$target = 'x86_64-pc-windows-msvc'
$helper = Join-Path $root "Matter\target\$target\release\charker-matter.exe"
if (-not ($SkipMatter -and $Mode -eq 'dev')) {
  if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'cargo not found: install rustup (https://rustup.rs) with the MSVC toolchain, or pass -SkipMatter'
  }
  # From inside the crate, so rustup honours its rust-toolchain.toml.
  Push-Location (Join-Path $root 'Matter')
  try {
    # Keep this machine's paths out of the binary, as make-app.sh does.
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $sysroot = (& rustc --print sysroot).Trim()
    $env:CARGO_ENCODED_RUSTFLAGS = @(
      "--remap-path-prefix=$root=/charker",
      "--remap-path-prefix=$cargoHome=/cargo",
      "--remap-path-prefix=$sysroot=/rustc"
    ) -join [char]0x1f
    & cargo build --release --locked --target $target
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
  }
  finally {
    Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue
    Pop-Location
  }
}

Push-Location $here
try {
  if ($Mode -eq 'dev') {
    $exe = Join-Path $out 'charker-dev.exe'
    & go build -trimpath -tags charkerdev -ldflags "-X main.version=$version-dev" -o $exe .
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    if (-not $SkipMatter) { Copy-Item -Force $helper $out }
    Write-Host "built $exe ($version-dev)"
  }
  else {
    # The update key signs the update files; without it mygo build makes
    # the installer alone.
    & go tool mygo build -platform windows/amd64 -o $OutDir
    if ($LASTEXITCODE -ne 0) { throw "mygo build failed ($LASTEXITCODE)" }
  }
}
finally {
  Pop-Location
}
