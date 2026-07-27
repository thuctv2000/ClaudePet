// ClaudePet Bridge — the supported way into a VS Code terminal.
//
// `Terminal.sendText` writes straight to the stdin of the terminal's pty. No
// focus, no window, no bringing VS Code to the front, and it works while the
// window is minimised or hidden. It is an extension API, callable only from
// inside VS Code — which is what this bridge exists to cross.
//
// What it replaces on the pet's side is a chain of UI automation: activate VS
// Code, send ⌃` to move focus, read the accessibility tree to check the right
// terminal took it, then synthesize keystrokes. That works, but it steals the
// user's window, cannot run while the window is minimised, and identifies the
// terminal by its title. This identifies it by process id.

const vscode = require("vscode");
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

let server = null;
let lockPath = null;

/** The terminal whose shell process is `pid`, or undefined. */
async function terminalWithPid(pid) {
  for (const terminal of vscode.window.terminals) {
    if ((await terminal.processId) === pid) return terminal;
  }
  return undefined;
}

/** Every terminal's pid, so a miss can say what WAS there. */
async function knownPids() {
  const out = [];
  for (const terminal of vscode.window.terminals) {
    out.push({ name: terminal.name, pid: await terminal.processId });
  }
  return out;
}

function handle(request, response, token) {
  // Loopback-bound and token-gated, the same shape as the pet's own hook
  // server: another local user must not be able to type into your shell.
  if (request.headers["x-pet-token"] !== token) {
    response.writeHead(401);
    response.end();
    return;
  }
  if (request.method !== "POST" || request.url !== "/send") {
    response.writeHead(404);
    response.end();
    return;
  }
  let body = "";
  request.on("data", (chunk) => {
    body += chunk;
    if (body.length > 1_000_000) request.destroy();
  });
  request.on("end", async () => {
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      response.writeHead(400);
      response.end(JSON.stringify({ error: "bad json" }));
      return;
    }
    const terminal = await terminalWithPid(payload.pid);
    if (!terminal) {
      // 404 rather than an error: the pet asks every window it can find, and
      // the ones that don't own this terminal are expected to say no.
      response.writeHead(404);
      response.end(JSON.stringify({ error: "no terminal with that pid",
                                    terminals: await knownPids() }));
      return;
    }
    terminal.sendText(String(payload.text ?? ""), true);
    response.writeHead(200);
    response.end(JSON.stringify({ ok: true, name: terminal.name }));
  });
}

function activate(context) {
  const token = crypto.randomUUID();
  server = http.createServer((request, response) => handle(request, response, token));
  server.on("error", () => {});
  server.listen(0, "127.0.0.1", () => {
    const port = server.address().port;
    // One file per window, named by the extension host's pid: several windows
    // each run their own copy of this, and the pet tries them all.
    const directory = path.join(os.homedir(), ".petmacos");
    fs.mkdirSync(directory, { recursive: true });
    lockPath = path.join(directory, `vscode-${process.pid}.json`);
    fs.writeFileSync(
      lockPath,
      JSON.stringify({
        port,
        token,
        pid: process.pid,
        folders: (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath),
      }),
      { mode: 0o600 }
    );
  });
  context.subscriptions.push({ dispose: deactivate });
}

function deactivate() {
  if (server) {
    server.close();
    server = null;
  }
  // A stale file would send the pet knocking on a dead port every time.
  if (lockPath) {
    try { fs.unlinkSync(lockPath); } catch {}
    lockPath = null;
  }
}

module.exports = { activate, deactivate };
