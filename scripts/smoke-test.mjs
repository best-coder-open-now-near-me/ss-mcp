import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const serverPath = join(root, "src", "server.mjs");

const child = spawn(process.execPath, [serverPath], {
  cwd: root,
  stdio: ["pipe", "pipe", "pipe"],
  windowsHide: true
});

let buffer = Buffer.alloc(0);
let nextId = 1;
const pending = new Map();

child.stdout.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  readFrames();
});

child.stderr.on("data", (chunk) => {
  process.stderr.write(chunk);
});

child.on("exit", (code) => {
  if (pending.size > 0) {
    throw new Error(`Server exited with ${pending.size} pending request(s), code ${code}.`);
  }
});

function readFrames() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) {
      return;
    }

    const header = buffer.subarray(0, headerEnd).toString("ascii");
    const match = /content-length:\s*(\d+)/i.exec(header);
    if (!match) {
      throw new Error(`Bad frame header: ${header}`);
    }

    const length = Number(match[1]);
    const frameStart = headerEnd + 4;
    const frameEnd = frameStart + length;
    if (buffer.length < frameEnd) {
      return;
    }

    const body = buffer.subarray(frameStart, frameEnd).toString("utf8");
    buffer = buffer.subarray(frameEnd);
    const message = JSON.parse(body);
    const resolver = pending.get(message.id);
    if (resolver) {
      pending.delete(message.id);
      resolver(message);
    }
  }
}

function request(method, params = {}) {
  const id = nextId++;
  const message = {
    jsonrpc: "2.0",
    id,
    method,
    params
  };
  const json = JSON.stringify(message);
  const bytes = Buffer.byteLength(json, "utf8");
  child.stdin.write(`Content-Length: ${bytes}\r\n\r\n${json}`);

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${method}.`));
    }, 10000);

    pending.set(id, (response) => {
      clearTimeout(timeout);
      if (response.error) {
        reject(new Error(response.error.message));
      }
      else {
        resolve(response.result);
      }
    });
  });
}

const init = await request("initialize", {
  protocolVersion: "2024-11-05",
  capabilities: {},
  clientInfo: {
    name: "ss-mcp-smoke",
    version: "0.1.0"
  }
});

if (init.serverInfo?.name !== "ss-mcp") {
  throw new Error("Server initialize response did not include expected serverInfo.");
}

const listed = await request("tools/list");
const toolNames = new Set(listed.tools.map((tool) => tool.name));
for (const expected of ["list_windows", "screenshot_window", "screenshot_active_window"]) {
  if (!toolNames.has(expected)) {
    throw new Error(`Missing tool: ${expected}`);
  }
}

child.stdin.end();
console.log(`Smoke test passed. Tools: ${[...toolNames].join(", ")}`);
