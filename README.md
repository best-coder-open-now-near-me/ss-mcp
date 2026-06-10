# ss-mcp

`ss-mcp` is a tiny MCP server for giving an LLM visual feedback from a Windows desktop window.

It exposes three tools:

- `list_windows`: lists visible top-level windows with `windowId`, title, process name, and bounds.
- `screenshot_window`: captures a chosen window by `windowId`, title, or process name.
- `screenshot_active_window`: captures the foreground window.

Screenshots are returned as MCP `image/png` content plus JSON metadata. If you pass `savePath`, the PNG is also written there.

## Requirements

- Windows
- Node.js 18 or newer
- Windows PowerShell with access to `user32.dll`, `dwmapi.dll`, and `System.Drawing`

No npm dependencies are required.

## Run

```powershell
node .\src\server.mjs
```

If `node` is not on PATH, use an absolute Node executable path in your MCP client config.

## Example MCP Config

Point your MCP client at the server entrypoint:

```json
{
  "mcpServers": {
    "window_screenshot": {
      "command": "node",
      "args": [
        "C:\\path\\to\\ss-mcp\\src\\server.mjs"
      ]
    }
  }
}
```

For Codex Desktop, prefer using Codex's config writer instead of hand-editing TOML:

```powershell
$env:CODEX_HOME = "C:\Users\mewhi\.codex"
codex mcp add window_screenshot -- "C:\path\to\node.exe" "C:\path\to\ss-mcp\src\server.mjs"
```

If `node` is not on PATH, use the full path to the Node executable that Codex can launch.

## Tool Examples

List windows:

```json
{
  "name": "list_windows",
  "arguments": {
    "processName": "notepad"
  }
}
```

Capture a known window:

```json
{
  "name": "screenshot_window",
  "arguments": {
    "windowId": 123456,
    "captureMode": "auto",
    "maxWidth": 1600,
    "maxHeight": 1200
  }
}
```

Capture the foreground window:

```json
{
  "name": "screenshot_active_window",
  "arguments": {
    "captureMode": "auto"
  }
}
```

`captureMode` can be:

- `auto`: try `PrintWindow`, then fall back to desktop pixels.
- `printWindow`: ask the app to render itself, which can work even if the window is covered.
- `screen`: copy the visible desktop pixels, which is often most faithful but requires the target to be visible.

Some GPU-heavy, protected, elevated, or minimized windows may return black or stale captures. In those cases, restore the window and use `captureMode: "screen"`.

## Smoke Test

```powershell
npm run smoke
```

or, without npm:

```powershell
node .\scripts\smoke-test.mjs
```

The smoke test verifies MCP framing, initialization, and tool listing. It does not capture your desktop.
