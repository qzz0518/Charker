#!/usr/bin/env bash
# Assemble and sign Charker.app from SwiftPM products and the Rust Matter
# helper in Matter/.
#
# Local development stays fast by building the host architecture and signing
# ad-hoc. A distribution build passes both architectures, a Developer ID hash,
# and DISTRIBUTION=1; every nested code item is then signed explicitly with the
# hardened runtime and a secure timestamp.
set -euo pipefail

CONFIG="${CONFIG:-release}"
IDENTITY="${IDENTITY:--}"
DISTRIBUTION="${DISTRIBUTION:-0}"
ARCHS="${ARCHS:-$(uname -m)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_PATH:-$ROOT/dist/Charker.app}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/charker-bundle}"
SOURCE_INFO="$ROOT/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_INFO")}"

if [ "$DISTRIBUTION" = "1" ] && [ "$IDENTITY" = "-" ]; then
	echo "DISTRIBUTION=1 requires a Developer ID Application identity" >&2
	exit 1
fi

read -r -a ARCH_LIST <<< "$ARCHS"
if [ "${#ARCH_LIST[@]}" -eq 0 ]; then
	echo "ARCHS must contain at least one architecture" >&2
	exit 1
fi

BIN_DIRS=()
BINARIES=()
for ARCH in "${ARCH_LIST[@]}"; do
	case "$ARCH" in
		arm64|x86_64) ;;
		*) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
	esac
	SCRATCH="$BUILD_ROOT/$ARCH"
	swift build -c "$CONFIG" \
		--triple "$ARCH-apple-macosx" \
		--scratch-path "$SCRATCH" \
		--product Charker
	BIN_DIR="$(swift build -c "$CONFIG" \
		--triple "$ARCH-apple-macosx" \
		--scratch-path "$SCRATCH" \
		--show-bin-path)"
	BIN="$BIN_DIR/Charker"
	if [ ! -x "$BIN" ]; then
		echo "missing Charker executable for $ARCH: $BIN" >&2
		exit 1
	fi
	if ! lipo -archs "$BIN" | tr ' ' '\n' | rg -Fxq "$ARCH"; then
		echo "Charker executable does not contain requested architecture $ARCH" >&2
		exit 1
	fi
	BIN_DIRS+=("$BIN_DIR")
	BINARIES+=("$BIN")
done

# The Apple Home bridge is a separate Rust executable that Charker spawns. Run
# Cargo from Matter/ so rustup honours its rust-toolchain.toml, and remap every
# local source prefix (checkout and build tree, Cargo's registry and git
# checkouts, the toolchain) so the binary carries no builder paths. The encoded
# form keeps paths with spaces intact.
MATTER_TARGET_DIR="$BUILD_ROOT/matter"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SOURCE_INFO")"
RUST_SYSROOT="$(cd "$ROOT/Matter" && rustc --print sysroot)"
MATTER_RUSTFLAGS=(
	"--remap-path-prefix=$ROOT=/charker"
	"--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
	"--remap-path-prefix=$RUST_SYSROOT=/rustc"
	"--remap-path-prefix=$MATTER_TARGET_DIR=/target"
)
MATTER_ENCODED_RUSTFLAGS="$(IFS=$'\037'; printf '%s' "${MATTER_RUSTFLAGS[*]}")"
HELPERS=()
for ARCH in "${ARCH_LIST[@]}"; do
	case "$ARCH" in
		arm64) RUST_TARGET=aarch64-apple-darwin ;;
		x86_64) RUST_TARGET=x86_64-apple-darwin ;;
	esac
	(cd "$ROOT/Matter" && \
		CARGO_TARGET_DIR="$MATTER_TARGET_DIR" \
		MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
		CARGO_ENCODED_RUSTFLAGS="$MATTER_ENCODED_RUSTFLAGS" \
		cargo build --manifest-path "$ROOT/Matter/Cargo.toml" \
			--release --locked --target "$RUST_TARGET")
	HELPER="$MATTER_TARGET_DIR/$RUST_TARGET/release/charker-matter"
	if [ ! -x "$HELPER" ]; then
		echo "missing charker-matter executable for $ARCH: $HELPER" >&2
		exit 1
	fi
	HELPERS+=("$HELPER")
done

GLTF_FRAMEWORK="${BIN_DIRS[0]}/GLTFKit2.framework"
SPARKLE_FRAMEWORK="${BIN_DIRS[0]}/Sparkle.framework"
for FRAMEWORK in "$GLTF_FRAMEWORK" "$SPARKLE_FRAMEWORK"; do
	if [ ! -d "$FRAMEWORK" ]; then
		echo "missing embedded framework: $FRAMEWORK" >&2
		exit 1
	fi
done

if [ ! -f "$ROOT/Resources/Model3D/A2345.glb" ]; then
	echo "missing required A2345 model: $ROOT/Resources/Model3D/A2345.glb" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
if [ "${#BINARIES[@]}" -eq 1 ]; then
	cp "${BINARIES[0]}" "$APP/Contents/MacOS/Charker"
else
	lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Charker"
fi
if [ "${#HELPERS[@]}" -eq 1 ]; then
	cp "${HELPERS[0]}" "$APP/Contents/MacOS/charker-matter"
else
	lipo -create "${HELPERS[@]}" -output "$APP/Contents/MacOS/charker-matter"
fi
ditto "$GLTF_FRAMEWORK" "$APP/Contents/Frameworks/GLTFKit2.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

cp "$SOURCE_INFO" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle.main must own localisations. SwiftPM's Bundle.module points back into
# the build directory and does not survive a standalone .app distribution.
shopt -s nullglob
for LPROJ in "$ROOT/Resources/Localizations"/*.lproj; do
	ditto "$LPROJ" "$APP/Contents/Resources/$(basename "$LPROJ")"
done
shopt -u nullglob

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d "$ROOT/Resources/Brand" ]; then
	ditto "$ROOT/Resources/Brand" "$APP/Contents/Resources/Brand"
fi
if [ -d "$ROOT/Resources/Licenses" ]; then
	ditto "$ROOT/Resources/Licenses" "$APP/Contents/Resources/Licenses"
fi
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
if [ -f "$ROOT/Resources/Model3D/A2687.glb" ] && [ -f "$ROOT/Resources/Model3D/A2687.hdr" ]; then
	mkdir -p "$APP/Contents/Resources/Model3D"
	for ASSET in A2687.webp A2687.glb A2687.hdr; do
		cp "$ROOT/Resources/Model3D/$ASSET" "$APP/Contents/Resources/Model3D/"
	done
fi
mkdir -p "$APP/Contents/Resources/Model3D"
cp "$ROOT/Resources/Model3D/A2345.glb" "$APP/Contents/Resources/Model3D/"
cp "$ROOT/Resources/Model3D/A2345.png" "$APP/Contents/Resources/Model3D/"
ditto "$ROOT/Resources/ClockThemes" "$APP/Contents/Resources/ClockThemes"

cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"

# SwiftPM links both dynamic frameworks through @rpath. A shell-assembled app
# does not inherit Xcode's LD_RUNPATH_SEARCH_PATHS, so add the conventional app
# framework location before any signature is created.
if ! otool -l "$APP/Contents/MacOS/Charker" | rg -Fq '@executable_path/../Frameworks'; then
	install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Charker"
fi

# Repository fallbacks are useful for `swift run`, but a distributable binary
# must never reveal the builder's absolute checkout path. Keep this as a bundle
# invariant so future asset loaders cannot silently reintroduce it.
if [ "$CONFIG" = "release" ]; then
	# The debug map lists every source and object file by absolute path, and
	# nothing at runtime reads it.
	xcrun strip -S "$APP/Contents/MacOS/Charker"
	REPOSITORY_PATH_HITS="$(strings - "$APP/Contents/MacOS/Charker" | rg -F -e "$ROOT" -e "$HOME" || true)"
	if [ -n "$REPOSITORY_PATH_HITS" ]; then
		echo "release binary contains an absolute repository or home path" >&2
		exit 1
	fi
	# The helper's Cargo registry, git checkouts and toolchain all live under
	# the builder's home directory. Scan every byte so each slice is covered.
	HELPER_PATH_HITS="$(strings - "$APP/Contents/MacOS/charker-matter" | rg -F -e "$ROOT" -e "$HOME" || true)"
	if [ -n "$HELPER_PATH_HITS" ]; then
		echo "charker-matter contains an absolute repository or home path" >&2
		exit 1
	fi
fi

for ARCH in "${ARCH_LIST[@]}"; do
	for CODE in \
		"$APP/Contents/MacOS/Charker" \
		"$APP/Contents/MacOS/charker-matter" \
		"$APP/Contents/Frameworks/GLTFKit2.framework/Versions/Current/GLTFKit2" \
		"$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"; do
		if ! lipo -archs "$CODE" | tr ' ' '\n' | rg -Fxq "$ARCH"; then
			echo "$(basename "$CODE") is missing requested architecture $ARCH" >&2
			exit 1
		fi
	done
done

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [ "$DISTRIBUTION" = "1" ]; then
	SIGN_FLAGS+=(--options runtime --timestamp)
fi

sign_code() {
	codesign "${SIGN_FLAGS[@]}" "$@"
}

# Sparkle contains executable code several levels below the framework. Signing
# only the outer framework (or using codesign --deep) leaves an unverifiable and
# non-notarisable bundle. Keep Downloader.xpc's upstream entitlement metadata;
# every other item receives a fresh signature from the inside out.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/Current"
sign_code --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
sign_code "$SPARKLE_VERSION/XPCServices/Installer.xpc"
sign_code "$SPARKLE_VERSION/Autoupdate"
sign_code "$SPARKLE_VERSION/Updater.app"
sign_code "$SPARKLE"
sign_code "$APP/Contents/Frameworks/GLTFKit2.framework"
# The helper has no Info.plist to name it, and it only ever runs as a child of
# the sandboxed app, so it inherits that sandbox and asks for nothing else.
sign_code --identifier dev.charker.Charker.matter \
	--entitlements "$ROOT/Resources/CharkerMatter.entitlements" \
	"$APP/Contents/MacOS/charker-matter"
sign_code --entitlements "$ROOT/Resources/Charker.entitlements" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "built $APP"
echo "version $VERSION ($BUILD_NUMBER)"
echo "architectures $(lipo -archs "$APP/Contents/MacOS/Charker")"
if [ "$DISTRIBUTION" = "1" ]; then
	echo "signed for Developer ID distribution"
else
	echo "signed for local development"
fi
