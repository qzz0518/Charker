// Screenshots a page of the browser dev server (cmd/webdev) with headless
// Chrome, optionally after a few interactions, without touching the desktop.
//
//   bun tools/shot.ts <out.png> [section] [--size 969x840] [--theme dark|light]
//        [--port 8765] [--wait 2500] [--eval "<js>"]... [--click "<css>"]...
//
// Steps run in the order given, each followed by a short pause. --eval runs
// in the page (e.g. to scroll a container); --click clicks the first match.
// Console errors from the page are printed.
import { spawn } from "bun";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const argv = process.argv.slice(2);
const out = argv[0];
if (!out) {
  console.error("usage: bun tools/shot.ts <out.png> [section] [options]");
  process.exit(2);
}
let section = "dashboard";
let size = "969x840";
let port = "8765";
let wait = 2500;
let theme = "dark";
const steps: { kind: string; arg: string }[] = [];
for (let i = 1; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--size") size = argv[++i];
  else if (a === "--port") port = argv[++i];
  else if (a === "--wait") wait = Number(argv[++i]);
  else if (a === "--theme") theme = argv[++i];
  else if (a === "--eval") steps.push({ kind: "eval", arg: argv[++i] });
  else if (a === "--click") steps.push({ kind: "click", arg: argv[++i] });
  else section = a;
}
const [w, h] = size.split("x").map(Number);
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "charker-shot-"));
const debugPort = 9300 + Math.floor(Math.random() * 600);
const proc = spawn([
  chrome,
  "--headless=new",
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${profile}`,
  "--hide-scrollbars=false",
  "--force-device-scale-factor=2",
  `--window-size=${w},${h}`,
  `--force-dark-mode=${theme === "dark"}`,
  `--blink-settings=preferredColorScheme=${theme === "dark" ? 0 : 1}`,
  "about:blank",
], { stdout: "ignore", stderr: "ignore" });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let target: any;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(100);
  try {
    const list = await (await fetch(`http://127.0.0.1:${debugPort}/json`)).json();
    target = list.find((t: any) => t.type === "page");
  } catch {}
}
if (!target) throw new Error("chrome did not start");
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map<number, (v: any) => void>();
ws.onmessage = (e) => {
  const msg = JSON.parse(String(e.data));
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)!(msg);
    pending.delete(msg.id);
  } else if (msg.method === "Runtime.consoleAPICalled" && ["error", "warning"].includes(msg.params.type)) {
    console.log(`page ${msg.params.type}:`, msg.params.args.map((a: any) => a.value ?? a.description).join(" "));
  } else if (msg.method === "Runtime.exceptionThrown") {
    console.log("page exception:", msg.params.exceptionDetails?.exception?.description ?? msg.params.exceptionDetails?.text);
  }
};
const send = (method: string, params: any = {}) =>
  new Promise<any>((r) => {
    const n = ++id;
    pending.set(n, r);
    ws.send(JSON.stringify({ id: n, method, params }));
  });
await send("Runtime.enable");
await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 2, mobile: false });
await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: theme }] });
await send("Page.navigate", { url: `http://127.0.0.1:${port}/#${section}` });
await sleep(wait);
for (const s of steps) {
  if (s.kind === "eval") {
    const r = await send("Runtime.evaluate", { expression: s.arg, awaitPromise: true, returnByValue: true });
    if (r.result?.result?.value !== undefined) console.log("eval:", JSON.stringify(r.result.result.value));
    if (r.result?.exceptionDetails) console.log("eval error:", r.result.exceptionDetails.exception?.description);
  } else {
    const r = await send("Runtime.evaluate", {
      expression: `(() => { const el = document.querySelector(${JSON.stringify(s.arg)}); if (!el) return 'missing'; const b = el.getBoundingClientRect(); return [b.x + b.width / 2, b.y + b.height / 2]; })()`,
      returnByValue: true,
    });
    const v = r.result?.result?.value;
    if (v === "missing") {
      console.log(`click: no element for ${s.arg}`);
    } else {
      for (const type of ["mousePressed", "mouseReleased"]) {
        await send("Input.dispatchMouseEvent", { type, x: v[0], y: v[1], button: "left", clickCount: 1 });
      }
    }
  }
  await sleep(500);
}
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(shot.result.data, "base64"));
console.log(out);
ws.close();
proc.kill();
