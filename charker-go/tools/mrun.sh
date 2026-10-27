#!/bin/bash
# Dev loop on macOS: build charker-go, run it on the simulated charger as its
# own instance, open a page and screenshot the window.
#
#   tools/mrun.sh <instance> <out.png> [page] [width height]
#
# page: dashboard | energy | devices | menuBar | advanced | about
# The instance name keeps data, the single-instance lock and the binary apart,
# so several copies can run at once. Logs: $TMPDIR/charker-<instance>/dev.log
set -e
inst=$1; out=$2; route=$3; w=${4:-969}; h=${5:-878}
here=$(cd "$(dirname "$0")/.." && pwd)
dir=${TMPDIR:-/tmp}/charker-$inst
mkdir -p "$dir"
(cd "$here" && GOTOOLCHAIN=go1.27.3 go build -tags charkerdev -o "$dir/charker-$inst" .)
pkill -f "$dir/charker-$inst" 2>/dev/null || true
sleep 0.5
CHARKER_MOCK=1 CHARKER_INSTANCE=$inst CHARKER_ROUTE=$route "$dir/charker-$inst" >"$dir/stdout.log" 2>&1 &
pid=$!
sleep 4
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid)
set frontmost to true
set size of window 1 to {$w, $h}
end tell" >/dev/null
sleep ${WAIT:-4}
id=$(swift - "$pid" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var best = (0.0, 0)
for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid && (w[kCGWindowLayer as String] as! Int) == 0 {
  let b = w[kCGWindowBounds as String] as! [String: Any]
  let a = (b["Width"] as! Double) * (b["Height"] as! Double)
  if a > best.0 { best = (a, w[kCGWindowNumber as String] as! Int) }
}
print(best.1)
SWIFT
)
screencapture -o -x -l"$id" "$out"
echo "$out (pid $pid, log $dir/dev.log)"
