# Setup

## Prerequisites

- Node.js 18+ with `fetch` support.
- A local EDAMAME host on the same machine:
  - macOS / Windows: the EDAMAME Security app
  - Linux: `edamame_posture`

## Install via Claude Code Marketplace Plugin

The recommended install path. Add the marketplace and install:

```shell
/plugin marketplace add edamametechnologies/edamame_claude_code
/plugin install edamame@edamame-security
/reload-plugins
```

The plugin registers:

- the MCP server (stdio bridge to EDAMAME),
- skills for posture assessment and divergence diagnosis,
- a security-monitor agent,
- healthcheck and export-intent commands.

After installation, run `/edamame:healthcheck` to verify the connection.

The plugin uses `${CLAUDE_PLUGIN_ROOT}` in `.mcp.json` so the MCP server
resolves its bridge path from the plugin cache automatically. Set the
`CLAUDE_CODE_EDAMAME_CONFIG` environment variable to point at a custom
config file, or let it auto-resolve to the default platform path.

## Install via EDAMAME app / posture CLI

EDAMAME downloads the latest release from GitHub (HTTP zipball -- no `git`
required) and copies files using native Rust file operations (no `bash` or
`python` required). Works on macOS, Linux, and Windows:

```bash
edamame-posture install-agent-plugin claude_code
edamame-posture agent-plugin-status claude_code
```

The EDAMAME Security app also exposes an "Agent Plugins" section in AI
Settings with one-click install, status display, and intent injection test
buttons.

## Install From Source (bash)

```bash
bash setup/install.sh /absolute/path/to/target/workspace
```

The installer:

- copies the package into a stable per-user install directory,
- renders a default package config,
- renders a Claude Code MCP snippet with fully resolved paths (including absolute `node` path),
- renders optional scheduler templates.

## Install From Source (PowerShell, Windows)

```powershell
.\setup\install.ps1 -WorkspaceRoot "C:\Users\me\projects\myapp"
```

PowerShell equivalent of `install.sh` for native Windows environments. Does
the same file copy + template rendering without requiring bash or python.

## Config Paths

Primary config file:

- macOS: `~/Library/Application Support/claude-code-edamame/config.json`
- Windows: `%APPDATA%\claude-code-edamame\config.json`
- Linux: `~/.config/claude-code-edamame/config.json`

Default state directory:

- macOS: `~/Library/Application Support/claude-code-edamame/state`
- Windows: `%LOCALAPPDATA%\claude-code-edamame\state`
- Linux: `~/.local/state/claude-code-edamame`

The default local credential file lives inside the package state directory as
`edamame-mcp.psk`.

Key fields:

- `workspace_root` - workspace this package monitors.
- `claude_projects_root` - Claude Code project storage, typically `~/.claude/projects`.
- `agent_type` - producer name attached to each behavioral-model slice. Default: `claude_code`.
- `agent_instance_id` - stable unique producer instance identifier.
- `host_kind` - `edamame_app` on macOS/Windows, `edamame_posture` on Linux.
- `edamame_mcp_endpoint` - local EDAMAME MCP endpoint, default `http://127.0.0.1:3000/mcp`.
- `edamame_mcp_psk_file` - package-local file where the credential is stored.

## Pairing

### macOS / Windows

Use `host_kind = edamame_app`.

1. Start the EDAMAME Security app.
2. Enable its local MCP server on port `3000`.
3. **Primary flow**: Use the control center to request pairing from the app, approve in the EDAMAME Security app.
4. **Fallback**: Generate a PSK from the app's MCP controls, paste it into the control center.

### Linux

Use `host_kind = edamame_posture`.

1. Generate a PSK:

```bash
edamame_posture mcp-generate-psk
```

2. Start the local MCP endpoint:

```bash
edamame_posture mcp-start 3000 "<PSK>"
```

3. Paste the PSK into the control center.

## Troubleshooting: `env: node: No such file or directory`

Claude Code may not inherit your shell's `PATH`. The manual installer
resolves this automatically (it writes the absolute `node` path into the
rendered MCP snippet). If using the marketplace plugin and this error occurs,
ensure `node` is on the system `PATH`.

## Health Check

```bash
bash setup/healthcheck.sh --strict --json
```

This validates:

- local config presence,
- credential file presence,
- EDAMAME MCP reachability,
- divergence-engine running state,
- behavioral-model presence.

## Local E2E: scripted transcript inject and `edamame_cli` verification

Use this when you want to confirm the full path from a **synthetic Claude Code transcript**
through the extrapolator into the running EDAMAME app, then read the merged model back via RPC
(the same surface `edamame_cli` uses).

Prerequisites: EDAMAME app running with MCP paired, agentic/LLM available for raw ingest, and a
built `edamame_cli` (or `EDAMAME_CLI` pointing at the binary).

```bash
bash scripts/e2e_inject_intent.sh
```

The script:

1. Checks install layout (`claude-code-edamame` config, PSK, optional `~/.claude/settings.json` marketplace entry).
2. Writes **three** fresh `.txt` transcripts under `~/.claude/projects/<workspace-basename>-edamame-e2e-inject/`
   (API URL + file read, shell/curl to npm, git-remote style). Each file basename is a distinct `session_key`.
3. Runs `claude_code_extrapolator.mjs` once against your config (installed package, or repo fallback).
4. Polls `edamame_cli rpc get_behavioral_model` until the merged behavioral model contains a
   `predictions[]` entry **for every** synthetic session (`agent_type`, `agent_instance_id`, and `session_key`).
   This avoids false failures when the merged contributor `hash` differs from a single-ingest `windowHash`.

The script calls `edamame_cli rpc get_behavioral_model --pretty`. For `String`-typed RPC
returns, the CLI emits a JSON string literal; the script parses twice (outer JSON string, then
inner behavioral-model JSON). Without `--pretty`, the CLI uses Rust `Debug` formatting, which is
not JSON and cannot be parsed reliably.

Environment:

| Variable | Purpose |
|----------|---------|
| `EDAMAME_CLI` | Path to `edamame_cli` if not on `PATH` |
| `CLAUDE_CODE_EDAMAME_CONFIG` | Alternate `config.json` |
| `E2E_SKIP_PLUGIN_CHECK=1` | Skip `~/.claude/settings.json` marketplace check |
| `E2E_POLL_ATTEMPTS` | Poll count (default 24) |
| `E2E_POLL_INTERVAL_SECS` | Seconds between polls (default 5) |
| `E2E_STRICT_HASH=1` | Also require contributor `hash` equals extrapolator `windowHash` (strict; often false after merges) |
