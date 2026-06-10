#!/usr/bin/env node
import { spawn } from "node:child_process";
import { Buffer } from "node:buffer";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..");
const captureScript = join(projectRoot, "scripts", "window-capture.ps1");

const serverInfo = {
  name: "ss-mcp",
  version: "0.1.0"
};

const tools = [
  {
    name: "list_windows",
    description: "List visible top-level Windows desktop windows that can be targeted for screenshots.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        title: {
          type: "string",
          description: "Optional case-insensitive title substring filter."
        },
        processName: {
          type: "string",
          description: "Optional process name filter, without .exe."
        }
      }
    }
  },
  {
    name: "screenshot_window",
    description: "Capture a screenshot of a visible window by window id, title substring, or process name.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        windowId: {
          type: "integer",
          description: "Native HWND value from list_windows."
        },
        title: {
          type: "string",
          description: "Case-insensitive window title match. Uses substring matching unless exactTitle is true."
        },
        exactTitle: {
          type: "boolean",
          default: false,
          description: "Require an exact title match when title is provided."
        },
        processName: {
          type: "string",
          description: "Process name filter, without .exe."
        },
        captureMode: {
          type: "string",
          enum: ["auto", "printWindow", "screen"],
          default: "auto",
          description: "printWindow can capture covered windows; screen captures the visible desktop pixels."
        },
        maxWidth: {
          type: "integer",
          minimum: 1,
          default: 1600,
          description: "Maximum returned image width. The screenshot is downscaled only when needed."
        },
        maxHeight: {
          type: "integer",
          minimum: 1,
          default: 1200,
          description: "Maximum returned image height. The screenshot is downscaled only when needed."
        },
        savePath: {
          type: "string",
          description: "Optional PNG output path. When omitted, the temporary screenshot is deleted after the MCP response is built."
        },
        includeImage: {
          type: "boolean",
          default: true,
          description: "Return the PNG as MCP image content. Set false only when savePath is provided."
        }
      }
    }
  },
  {
    name: "screenshot_active_window",
    description: "Capture a screenshot of the current foreground window.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        captureMode: {
          type: "string",
          enum: ["auto", "printWindow", "screen"],
          default: "auto"
        },
        maxWidth: {
          type: "integer",
          minimum: 1,
          default: 1600
        },
        maxHeight: {
          type: "integer",
          minimum: 1,
          default: 1200
        },
        savePath: {
          type: "string",
          description: "Optional PNG output path. When omitted, the temporary screenshot is deleted after the MCP response is built."
        },
        includeImage: {
          type: "boolean",
          default: true,
          description: "Return the PNG as MCP image content. Set false only when savePath is provided."
        }
      }
    }
  }
];

let inputBuffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  readFrames();
});

process.stdin.on("end", () => {
  process.exit(0);
});

function readFrames() {
  while (true) {
    const headerEnd = inputBuffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) {
      return;
    }

    const header = inputBuffer.subarray(0, headerEnd).toString("ascii");
    const match = /content-length:\s*(\d+)/i.exec(header);
    if (!match) {
      inputBuffer = inputBuffer.subarray(headerEnd + 4);
      continue;
    }

    const contentLength = Number(match[1]);
    const frameStart = headerEnd + 4;
    const frameEnd = frameStart + contentLength;
    if (inputBuffer.length < frameEnd) {
      return;
    }

    const body = inputBuffer.subarray(frameStart, frameEnd).toString("utf8");
    inputBuffer = inputBuffer.subarray(frameEnd);
    void handleRawMessage(body);
  }
}

async function handleRawMessage(body) {
  let message;
  try {
    message = JSON.parse(body);
  } catch (error) {
    sendError(null, -32700, `Parse error: ${error.message}`);
    return;
  }

  if (Array.isArray(message)) {
    await Promise.all(message.map((item) => handleMessage(item)));
    return;
  }

  await handleMessage(message);
}

async function handleMessage(message) {
  if (!message || typeof message !== "object") {
    sendError(null, -32600, "Invalid Request");
    return;
  }

  if (!Object.hasOwn(message, "id")) {
    return;
  }

  try {
    switch (message.method) {
      case "initialize":
        sendResult(message.id, {
          protocolVersion: message.params?.protocolVersion ?? "2024-11-05",
          capabilities: {
            tools: {}
          },
          serverInfo
        });
        break;

      case "ping":
        sendResult(message.id, {});
        break;

      case "tools/list":
        sendResult(message.id, { tools });
        break;

      case "tools/call":
        sendResult(message.id, await callTool(message.params ?? {}));
        break;

      case "resources/list":
        sendResult(message.id, { resources: [] });
        break;

      case "prompts/list":
        sendResult(message.id, { prompts: [] });
        break;

      default:
        sendError(message.id, -32601, `Method not found: ${message.method}`);
    }
  } catch (error) {
    sendResult(message.id, {
      isError: true,
      content: [
        {
          type: "text",
          text: error.stack ?? error.message
        }
      ]
    });
  }
}

async function callTool(params) {
  const name = params.name;
  const args = params.arguments ?? {};

  switch (name) {
    case "list_windows":
      return listWindows(args);

    case "screenshot_window":
      return captureWindow(args);

    case "screenshot_active_window":
      return captureWindow({ ...args, active: true });

    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function listWindows(args) {
  const result = await runCaptureScript("list", args);
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(result, null, 2)
      }
    ]
  };
}

async function captureWindow(args) {
  const includeImage = args.includeImage !== false;
  if (!includeImage && !args.savePath) {
    throw new Error("includeImage=false requires savePath so the captured PNG is not discarded.");
  }

  const result = await runCaptureScript("capture", {
    ...args,
    maxWidth: args.maxWidth ?? 1600,
    maxHeight: args.maxHeight ?? 1200
  });

  const content = [
    {
      type: "text",
      text: JSON.stringify(result, null, 2)
    }
  ];

  if (includeImage) {
    if (!result.path || !existsSync(result.path)) {
      throw new Error("Capture succeeded, but the PNG file was not found.");
    }

    const png = readFileSync(result.path);
    content.push({
      type: "image",
      mimeType: "image/png",
      data: png.toString("base64")
    });
  }

  if (!args.savePath && result.path) {
    rmSync(result.path, { force: true });
  }

  return { content };
}

function runCaptureScript(action, args) {
  const executable = process.env.SS_MCP_POWERSHELL ?? "powershell.exe";
  const psArgs = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    captureScript,
    "-Action",
    action
  ];

  appendArg(psArgs, "WindowId", args.windowId);
  appendArg(psArgs, "Title", args.title);
  appendSwitch(psArgs, "ExactTitle", args.exactTitle);
  appendArg(psArgs, "ProcessName", args.processName);
  appendSwitch(psArgs, "Active", args.active);
  appendArg(psArgs, "CaptureMode", args.captureMode);
  appendArg(psArgs, "OutputPath", args.savePath);
  appendArg(psArgs, "MaxWidth", args.maxWidth);
  appendArg(psArgs, "MaxHeight", args.maxHeight);

  return new Promise((resolve, reject) => {
    const child = spawn(executable, psArgs, {
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (data) => {
      stdout += data;
    });
    child.stderr.on("data", (data) => {
      stderr += data;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(stderr.trim() || `PowerShell capture backend exited with code ${code}.`));
        return;
      }

      try {
        resolve(JSON.parse(stdout));
      } catch (error) {
        reject(new Error(`Could not parse capture backend JSON: ${error.message}\n${stdout}`));
      }
    });
  });
}

function appendArg(args, name, value) {
  if (value === undefined || value === null || value === "") {
    return;
  }

  args.push(`-${name}`, String(value));
}

function appendSwitch(args, name, value) {
  if (value) {
    args.push(`-${name}`);
  }
}

function sendResult(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function sendError(id, code, message) {
  send({
    jsonrpc: "2.0",
    id,
    error: {
      code,
      message
    }
  });
}

function send(message) {
  const json = JSON.stringify(message);
  const length = Buffer.byteLength(json, "utf8");
  process.stdout.write(`Content-Length: ${length}\r\n\r\n${json}`);
}
