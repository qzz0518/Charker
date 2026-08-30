#!/usr/bin/env bash
# Creates a self-signed code-signing identity so Charker keeps its Bluetooth
# permission across rebuilds.
#
# WHY: an ad-hoc signature (`codesign --sign -`) has no stable identity — its code
# requirement is the binary's own cdhash. macOS pins the Bluetooth TCC grant to
# that, so every rebuild produces a "new app" and re-prompts for permission.
# Signing with a real certificate, even a self-signed one, gives a stable
# requirement and the grant survives.
#
# This adds a certificate to YOUR login keychain and will ask for your password.
# It is entirely optional: without it the app works, it just re-asks for
# Bluetooth permission after every rebuild.
#
#   Scripts/make-signing-identity.sh          # create it
#   IDENTITY="Charker Dev" Scripts/make-app.sh   # then build with it
set -euo pipefail

NAME="${1:-Charker Dev}"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "identity '$NAME' already exists"
	echo "build with: IDENTITY=\"$NAME\" Scripts/make-app.sh"
	exit 0
fi

cat <<MSG
This will create a self-signed code-signing certificate named "$NAME" in your
login keychain. Certificate Assistant cannot be driven from a script, so do it
once by hand:

  1. Open Keychain Access
  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate…
  3. Name: $NAME
     Identity Type: Self Signed Root
     Certificate Type: Code Signing
     (leave "Let me override defaults" unchecked)
  4. Create, then Done

Then build with:

  IDENTITY="$NAME" Scripts/make-app.sh

The first launch after that still asks for Bluetooth permission once. Every
rebuild afterwards keeps it.
MSG
