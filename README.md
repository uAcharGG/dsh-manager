# dsh-manager — DeepSeek Harness Management Panel

A one-click local launcher and management panel for **DeepSeek Harness (`dsh web`)**. Double-click to start the harness, then manage it from a browser: start/stop/restart the service, install/uninstall/enable plugins, watch live logs, and pick plugin folders with a native dialog.

The panel is a single-file PowerShell HTTP server (`dsh-manager/server.ps1`) — no Node, no database, no dependencies beyond what Windows ships.

## Features

- **One-click service control** — start, stop, restart the local `dsh web` server (port 3080 by default), with ready-detection and auto-open in the browser.
- **Configurable dsh path** — the service control area has a **dsh 启动路径** row: type or pick (folder icon) the deepseek-harness checkout directory and save. It persists to `%APPDATA%\dshm\config.json`, overrides the `-Checkout` default, and takes effect at the next start (a running dsh is unaffected).
- **Plugin management** — install, uninstall, and enable/disable plugins on a profile's composition layer, through `dsh plugin` (pnpm) in the background with live progress in the log area.
- **Install guard** — installing/uninstalling is blocked while `dsh` is running: composition changes only take effect after a restart, so the panel tells you to stop the service first.
- **Native folder picker** — a folder icon opens the Windows folder dialog in a detached process (no console window, no server blocking); the picked path is filled into the local-path install field.
- **Plugin source display** — every installed plugin shows a description read from its README (or `-`) and its real file source path (resolved from `link:`/`file:` dependencies); built-in bundles show "内置模板组合包".
- **Live logs** — launch log and plugin-operation log, streamed incrementally to the page.

## Quick start

1. Double-click **`dsh-manager.cmd`** (or run `dsh-manager/server.ps1`).
2. The panel opens at `http://127.0.0.1:3399` and the dsh service at `http://127.0.0.1:3080`.
3. Use the **Launch** tab to start the service, and the **Plugins** tab to manage plugins.

> Ports: manager defaults to **3399** (auto-falls back if busy), dsh to **3080**. The dsh checkout path defaults to `D:\AI\DeepSeekHarness\deepseek-harness`; set it in the panel (服务控制 → dsh 启动路径, saved to `%APPDATA%\dshm\config.json`) or pass `-Checkout`.

## Plugin workflow

- **Install a local plugin**: stop the service → click the folder icon → pick the plugin folder → **Install** → start the service again.
- **Install from npm/git/tarball**: choose the source type, enter the spec, **Install** (service must be stopped).
- **Uninstall / toggle**: stop the service first, then uninstall or flip the enable switch; restart to apply.
- **Uninstall cleanup** — a successful uninstall also removes the plugin's local config files (e.g. dsh-vision deletes `$DSH_HOME/vision-config.json`).
- The operation runs as a background job; progress appears in the plugin log and the list refreshes automatically.

## HTTP API

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/status` | GET | running state, URLs, plugin-job busy flag |
| `/api/profiles` | GET | available profiles (`web`, `headless`) |
| `/api/plugins?profile=` | GET | installed plugins incl. version, README description, source path |
| `/api/logs?log=launch\|plugin&cursor=` | GET | incremental log lines |
| `/api/start` / `/api/stop` / `/api/restart` | POST | service control |
| `/api/config` | GET / POST | read or save the dsh launch path (persisted to `%APPDATA%\dshm\config.json`) |
| `/api/plugins/install` / `uninstall` / `toggle` | POST | plugin operations (install/uninstall blocked while dsh runs) |
| `/api/pick-directory` / `pick-directory-result` | POST / GET | native folder picker (detached dialog + result polling) |

## Directory structure

```
dsh-manager/
├── dsh-manager.cmd / .ps1   # launcher entry points
├── start-dsh.cmd / .ps1     # plain service start
├── build-icons.mjs          # icon build helper
├── assets/                  # panel icons
└── dsh-manager/
    ├── server.ps1           # the whole backend (HTTP server + all actions)
    ├── app.js               # front-end logic
    ├── index.html           # panel UI
    └── cleanup.cmd / .ps1   # cleanup helper
```

## Technical notes

- The backend is a minimal `TcpListener` HTTP server — no `http.sys`, no admin URL ACL, compatible with Windows PowerShell 5.1 and PowerShell 7+.
- The folder dialog runs in a **detached, hidden-console PowerShell process** so the single-threaded HTTP loop never blocks; the result is polled by the front end.
- Stopping the service collects every related process (port listener + command-line match + parent chain) and kills the tree.

## License

MIT
