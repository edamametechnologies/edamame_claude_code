# EDAMAME for Claude Code

**Runtime behavioral monitoring for Claude Code on developer workstations.**

This plugin bridges Claude Code transcripts (reasoning plane) to the
[EDAMAME Security](https://edamame.tech) system-plane observer, enabling
two-plane divergence detection on developer machines.

## How It Works

1. Claude Code produces session transcripts while you code.
2. This plugin parses transcripts and forwards them to EDAMAME via MCP.
3. EDAMAME evaluates behavioral intent against live system telemetry.
4. Divergence verdicts surface through the control center or health checks.

## Prerequisites

- **Node.js 18+**
- **EDAMAME Security** running on the same machine:
  - macOS / Windows: [EDAMAME Security app](https://edamame.tech)
  - Linux: [edamame_posture](https://github.com/edamametechnologies/edamame_posture) CLI

## Installation

### Option A: Claude Code Marketplace (Recommended)

Add the EDAMAME marketplace and install the plugin:

```shell
/plugin marketplace add edamametechnologies/edamame_claude_code
/plugin install edamame@edamame-security
```

The plugin automatically registers the MCP server, skills, agents, and
commands. After installation, run `/edamame:healthcheck` to verify the
connection.

### Option B: Local Plugin (Development)

Load the plugin directly from the repo for testing:

```shell
claude --plugin-dir ./edamame_claude_code
```

### Option C: Manual Install (From Source)

For environments where the marketplace is not available:

1. **Clone the repo and run the installer:**

```bash
git clone https://github.com/edamametechnologies/edamame_claude_code.git
cd edamame_claude_code
bash setup/install.sh /path/to/your/workspace
```

2. **Register the MCP server.** The installer renders a
   `claude-code-mcp.json` snippet with fully resolved paths. Merge it into
   your Claude Code MCP configuration. The snippet path is printed at the
   end of the install.

3. **Restart Claude Code**, then run `/edamame:healthcheck` to verify.

See [Setup Guide](docs/SETUP.md) for detailed config paths per platform.

### Pairing

- **macOS / Windows**: Start the EDAMAME Security app, enable MCP on port
  3000. Use the control center to request pairing from the app, or paste a PSK.
- **Linux**: Use `edamame_claude_code_control_center` and select
  "Generate, start, and pair automatically", or manually start
  `edamame_posture mcp-start 3000 "<PSK>"` and paste the PSK.

### Troubleshooting: `env: node: No such file or directory`

Claude Code may not inherit your shell's `PATH`. If `node` is installed via
Homebrew or nvm and the MCP server fails to start, ensure `node` is on the
system `PATH` or configure the MCP entry with the absolute path to `node`.
The manual installer resolves this automatically.

### Health Check

```bash
bash setup/healthcheck.sh --strict --json
```

## What the Plugin Provides

| Component | Contents |
|-----------|---------|
| **MCP Server** | stdio bridge forwarding EDAMAME tools (posture, divergence, sessions, remediation) to Claude Code |
| **Skills** | Security posture assessment (`/edamame:security-posture`), divergence monitoring (`/edamame:divergence-monitor`) |
| **Agents** | Security-monitor agent for safety-aware coding |
| **Commands** | Health check (`/edamame:healthcheck`), behavioral model export (`/edamame:export-intent`) |

## Layout

| Directory | Purpose |
|-----------|---------|
| `.claude-plugin/` | Plugin manifest and marketplace catalog |
| `.mcp.json` | Plugin MCP server definition |
| `skills/` | Agent skills (security-posture, divergence-monitor) |
| `agents/` | Custom agent definitions (security-monitor) |
| `commands/` | Agent-executable commands (healthcheck, export-intent) |
| `assets/` | Plugin logo and static assets |
| `bridge/` | Local stdio MCP bridge, control center, forwarding surface |
| `adapters/` | Transcript parsing and `RawReasoningSessionPayload` assembly |
| `service/` | Control center, extrapolator, posture facade, verdict reader, health checks |
| `scheduler/` | Optional launchd and systemd user-job templates |
| `setup/` | Install, bundle, and health-check scripts plus config templates |
| `prompts/` | Prompt contract used by EDAMAME-side raw-session ingest |
| `docs/` | Architecture, setup, operator guidance |

## Distribution Channels

| Channel | How | Friction |
|---------|-----|----------|
| **Claude Code Marketplace** | `/plugin marketplace add edamametechnologies/edamame_claude_code` | Lowest -- two commands |
| **Official Anthropic Marketplace** | Submit via [platform.claude.com/plugins/submit](https://platform.claude.com/plugins/submit) | One-click install after approval |
| **Team/Project scope** | Add `extraKnownMarketplaces` to project `.claude/settings.json` | Auto-prompts collaborators |
| **Local `--plugin-dir`** | `claude --plugin-dir ./edamame_claude_code` | Dev/test only |
| **Manual install** | `bash setup/install.sh` + merge MCP snippet | Full control, any env |

## Documentation

- [Setup Guide](docs/SETUP.md) -- install, config paths, pairing, health checks
- [Architecture](docs/ARCHITECTURE.md) -- component mapping and runtime flow

## Behavioral Model Contract

- `service/claude_code_extrapolator.mjs` forwards raw reasoning sessions to
  EDAMAME via `upsert_behavioral_model_from_raw_sessions`.
- `agent_type` defaults to `claude_code`.
- `agent_instance_id` is stable per workstation/workspace unless overridden.
- EDAMAME uses its configured LLM provider to convert raw transcripts into
  a contributor slice, then evaluates the merged model.
- Refresh is driven by the Claude Code MCP lifecycle; no OS scheduler required.

## Running Tests

```bash
node --test tests/*.test.mjs
```

## Related Repositories

| Repository | Purpose |
|------------|---------|
| [edamame_cursor](https://github.com/edamametechnologies/edamame_cursor) | EDAMAME integration for Cursor |
| [edamame_openclaw](https://github.com/edamametechnologies/edamame_openclaw) | EDAMAME integration for OpenClaw agents |
| [agent_security](https://github.com/edamametechnologies/agent_security) | Research paper: two-plane runtime security (arXiv preprint) |
| [edamame_security](https://github.com/edamametechnologies/edamame_security) | EDAMAME Security desktop/mobile app |
| [edamame_posture](https://github.com/edamametechnologies/edamame_posture) | EDAMAME Posture CLI for CI/CD and servers |
| [edamame_core_api](https://github.com/edamametechnologies/edamame_core_api) | EDAMAME Core public API documentation |

## License

Apache License 2.0 -- see [LICENSE](LICENSE).
