// `go tool mygo build -platform windows/amd64` makes the Windows release:
// Charker.exe, the installer charker-setup-<version>-amd64.exe and, with
// MYGO_UPDATER_PRIVATE_KEY set, the signed update files for the release.
// The name, identifier and version are the macOS app's (Resources/Info.plist).

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";

const plist = readFileSync("../Resources/Info.plist", "utf8");
const plistString = (key: string) =>
  plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`))?.[1];

// The Apple Home helper (../Matter), built with build.ps1 (MSVC) or
// cross-built with mingw-w64; CHARKER_MATTER_EXE names another build.
const matter = [
  process.env.CHARKER_MATTER_EXE,
  "../Matter/target/x86_64-pc-windows-msvc/release/charker-matter.exe",
  "../Matter/target/x86_64-pc-windows-gnu/release/charker-matter.exe",
].find((p) => p && existsSync(p));
if (!matter) throw new Error("charker-matter.exe not found: build ../Matter for Windows or set CHARKER_MATTER_EXE");

// The key that signs updates (mygo keygen), kept on the release Mac;
// MYGO_UPDATER_PRIVATE_KEY supplies it elsewhere.
const updateKey = `${homedir()}/Library/Application Support/mygo/update-keys/charker/mygo-update.key`;

export default {
  name: "Charker",
  identifier: plistString("CFBundleIdentifier"),
  version: plistString("CFBundleShortVersionString"),
  copyright: "© 2026 qzz0518",
  icon: "../Resources/Screenshots/app-icon-rounded.png",
  out: "build",
  resources: [
    matter,
    "../Resources/Licenses/charker-matter-LICENSES-windows.txt",
    "../LICENSE",
    "../THIRD-PARTY-NOTICES.md",
  ],
  updates: {
    publicKey: "rmpttrrJN9DpDOezJI2SVN0v3hP3panf9JiWLygIMgE=",
    github: "qzz0518/Charker",
    ...(existsSync(updateKey) && { privateKey: updateKey }),
  },
};
