#!/usr/bin/env bash
# Fast, secret-free checks for the release metadata that ties Sparkle, sandbox
# services and the app bundle together. This belongs in normal CI; signing and
# notarization remain explicit release-only operations.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO="$ROOT/Resources/Info.plist"
ENTITLEMENTS="$ROOT/Resources/Charker.entitlements"
MATTER_ENTITLEMENTS="$ROOT/Resources/CharkerMatter.entitlements"
DMG_BACKGROUND="$ROOT/Resources/DMG/background.png"
APP_LICENSE="$ROOT/LICENSE"
THIRD_PARTY_NOTICES="$ROOT/THIRD-PARTY-NOTICES.md"
DRACO_LICENSE="$ROOT/Resources/Licenses/Draco-Apache-2.0.txt"
A2345_MODEL="$ROOT/Resources/Model3D/A2345.glb"
MATTER_LICENSES="$ROOT/Resources/Licenses/charker-matter-LICENSES.txt"

mkdir -p "$ROOT/.build"
plutil -lint "$INFO" "$ENTITLEMENTS" "$MATTER_ENTITLEMENTS" >/dev/null

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"

case "$FEED_URL" in
	https://*) ;;
	*) echo "SUFeedURL must use HTTPS: $FEED_URL" >&2; exit 1 ;;
esac

KEY_BYTES="$(printf '%s' "$PUBLIC_KEY" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')"
if [ "$KEY_BYTES" != "32" ]; then
	echo "SUPublicEDKey must decode to a 32-byte Ed25519 public key" >&2
	exit 1
fi

for BOOLEAN_KEY in SUEnableInstallerLauncherService SURequireSignedFeed SUVerifyUpdateBeforeExtraction; do
	if [ "$(/usr/libexec/PlistBuddy -c "Print :$BOOLEAN_KEY" "$INFO")" != "true" ]; then
		echo "$BOOLEAN_KEY must be enabled" >&2
		exit 1
	fi
done

MACH_KEY='com.apple.security.temporary-exception.mach-lookup.global-name'
for INDEX in 0 1; do
	/usr/libexec/PlistBuddy -c "Print :$MACH_KEY:$INDEX" "$ENTITLEMENTS"
done | sort > "$ROOT/.build/charker-mach-services.actual"
printf '%s\n' "$BUNDLE_ID-spki" "$BUNDLE_ID-spks" | sort > "$ROOT/.build/charker-mach-services.expected"
if ! cmp -s "$ROOT/.build/charker-mach-services.actual" "$ROOT/.build/charker-mach-services.expected"; then
	echo "Sparkle Mach service entitlements do not match $BUNDLE_ID" >&2
	exit 1
fi

# The Matter helper runs as Charker's child and inherits its sandbox. Anything
# beyond these two keys would either break inheritance or widen the sandbox.
MATTER_ENTITLEMENT_KEYS="$(plutil -convert json -r -o - "$MATTER_ENTITLEMENTS")"
if [ "$MATTER_ENTITLEMENT_KEYS" != "$(printf '%s\n' '{' \
	'  "com.apple.security.app-sandbox" : true,' \
	'  "com.apple.security.inherit" : true' \
	'}')" ]; then
	echo "CharkerMatter.entitlements must contain exactly app-sandbox and inherit" >&2
	exit 1
fi

# The helper listens for the user's Home on UDP and advertises over Bonjour.
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.server' "$ENTITLEMENTS" 2>/dev/null)" != "true" ]; then
	echo "Charker.entitlements must enable com.apple.security.network.server for Matter" >&2
	exit 1
fi
if [ -z "$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$INFO" 2>/dev/null)" ]; then
	echo "Info.plist must explain local network use in NSLocalNetworkUsageDescription" >&2
	exit 1
fi
BONJOUR_SERVICES="$(plutil -extract NSBonjourServices json -o - "$INFO" 2>/dev/null || true)"
for SERVICE in _matter._tcp _matterc._udp; do
	if ! printf '%s' "$BONJOUR_SERVICES" | rg -Fq "\"$SERVICE\""; then
		echo "Info.plist NSBonjourServices must list $SERVICE" >&2
		exit 1
	fi
done

# The shipped dependency notice is generated from Cargo.lock; any dependency
# change must regenerate it (mise run matter-licenses).
MATTER_LOCK_HASH="$(shasum -a 256 "$ROOT/Matter/Cargo.lock" | awk '{print $1}')"
if ! rg -Fxq "Cargo.lock SHA-256: $MATTER_LOCK_HASH" "$MATTER_LICENSES"; then
	echo "charker-matter-LICENSES.txt is stale; run mise run matter-licenses" >&2
	exit 1
fi

if ! rg -Fq '.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")' "$ROOT/Package.swift"; then
	echo "Sparkle must remain pinned to reviewed version 2.10.0" >&2
	exit 1
fi

if [ ! -x "$ROOT/Scripts/make-dmg.sh" ]; then
	echo "Scripts/make-dmg.sh must be executable" >&2
	exit 1
fi
for REQUIRED_FILE in "$APP_LICENSE" "$THIRD_PARTY_NOTICES" "$DRACO_LICENSE" "$MATTER_LICENSES" "$A2345_MODEL"; do
	if [ ! -s "$REQUIRED_FILE" ]; then
		echo "missing required distribution resource: $REQUIRED_FILE" >&2
		exit 1
	fi
done
if [ "$(LC_ALL=C head -c 4 "$A2345_MODEL")" != "glTF" ]; then
	echo "A2345 model must be a binary glTF asset" >&2
	exit 1
fi
if [ ! -f "$DMG_BACKGROUND" ]; then
	echo "missing Finder background: $DMG_BACKGROUND" >&2
	exit 1
fi
DMG_WIDTH="$(sips -g pixelWidth "$DMG_BACKGROUND" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
DMG_HEIGHT="$(sips -g pixelHeight "$DMG_BACKGROUND" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
if [ "$DMG_WIDTH" != "660" ] || [ "$DMG_HEIGHT" != "400" ]; then
	echo "DMG background must be exactly 660x400, got ${DMG_WIDTH}x${DMG_HEIGHT}" >&2
	exit 1
fi

if git -C "$ROOT" ls-files | rg -q '\.(p12|pem|key|cer|p8)$'; then
	echo "signing material must not be tracked by Git" >&2
	exit 1
fi

echo "Release configuration validation passed: $BUNDLE_ID, Sparkle 2.10.0, signed HTTPS feed, sandboxed Matter helper."
