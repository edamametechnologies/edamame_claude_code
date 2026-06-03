# Architecture

## Two-Plane Model

```
Claude Code (reasoning plane)        EDAMAME Security (system plane)
   |                                      |
   | transcripts                          | live telemetry
   v                                      v
+------------------+              +------------------+
| EDAMAME for      |   MCP/HTTP   | Divergence       |
| Claude Code      | -----------> | Engine           |
| (this package)   |              | (internal)       |
+------------------+              +------------------+
                                         |
                                    verdicts:
                                  CLEAN / DIVERGENCE
                                  NO_MODEL / STALE
```

## Component Map

| Component | File | Role |
|-----------|------|------|
| MCP bridge | `bridge/claude_code_edamame_mcp.mjs` | stdio MCP server; registers tools and resources; drives periodic refresh |
| Control center | `bridge/control_center_app.html` | Interactive MCP App for pairing and status |
| EDAMAME client | `bridge/edamame_client.mjs` | HTTP client for EDAMAME MCP endpoint |
| Config | `service/config.mjs` | Cross-platform config/state path resolution |
| Control center logic | `service/control_center.mjs` | Pairing, status assembly, host actions |
| Extrapolator | `service/claude_code_extrapolator.mjs` | Transcript-to-model translation and push |
| Session adapter | `adapters/session_prediction_adapter.mjs` | Parse Claude Code transcripts into `RawReasoningSessionPayload` |
| Health check | `service/health.mjs` | Validate config, endpoint, engine, model |
| Posture facade | `service/posture_facade.mjs` | Read-only EDAMAME posture/score wrapper |
| Verdict reader | `service/verdict_reader.mjs` | Read-only divergence verdict facade |

The [edamame_claude](https://github.com/edamametechnologies/edamame_claude) repository mirrors the client, control center HTML, posture facade, and skills listed above for reuse across Claude Code and Claude Desktop ([edamame_claude_desktop](https://github.com/edamametechnologies/edamame_claude_desktop)). This package currently embeds its own copies; shared imports are a later step.

## Data Flow

1. Claude Code produces session transcripts under `~/.claude/projects/`.
2. `session_prediction_adapter.mjs` discovers and parses recent transcripts.
3. `claude_code_extrapolator.mjs` assembles a `RawReasoningSessionPayload`.
4. The payload is forwarded to EDAMAME via `upsert_behavioral_model_from_raw_sessions`.
5. EDAMAME's internal LLM generates a contributor `BehavioralWindow` slice.
6. The divergence engine correlates the model against live system telemetry.
7. Verdicts are available via `get_divergence_verdict`.

> **External transcript observer (additive, no change in this repo).** Starting with `edamame_core` 1.2.3, EDAMAME runs its own EDAMAME-side observer that reads `~/.claude/projects/` directly and feeds the same `upsert_behavioral_model_from_raw_sessions` pipeline. The observer is the security primitive: divergence detection works as soon as Claude Code is **discovered** on disk, regardless of whether this Node-side package is installed. When the package **is** installed, its bridge also pushes models in-process and the observer hash-skips on duplicate payloads -- so the two paths are purely additive and this repo's install / MCP / pairing flow is unchanged. Operators can pause / resume / run-now per agent from the EDAMAME app's AI / Config tab. When the observer is paused while Claude Code is discovered on disk, EDAMAME's `unsecured_claude_code` internal threat trips on the next score cycle.

## Observer vs plugin: the value boundary

The two paths above are **not** peers, and conflating them in either
direction is wrong: this package is neither the security control nor dead
weight.

| | EDAMAME host-side observer | This package (reasoning plane) |
|---|---|---|
| Role | **Security control of record** | **Cooperative enhancement** |
| Trust model | Observer-independent: runs in the system plane, so a compromised Claude Code cannot pause, blind, or silence it | Cooperative: Claude Code voluntarily declares intent; it can only *add* signal, never *weaken* a verdict |
| Needs | Claude Code's transcripts readable on the host (Claude Code **discovered** on disk) | Claude Code itself running this MCP bridge |
| Provides the guarantee? | **Yes** -- divergence detection works with zero plugin installed | **No** -- it adds coverage and convenience only |

The package earns its place in two ways, neither of which is the
guarantee itself:

- **Off-host coverage.** When Claude Code runs where the host observer
  cannot read its transcripts -- a remote box, SSH session, container, CI
  runner, VM, or a different user account -- this in-process bridge is the
  *only* path that delivers the behavioral model to EDAMAME.
- **Cooperative onboarding and UX.** MCP-native discovery, pairing, the
  in-agent read-only posture/verdict surface, health checks, intent
  export, and security-awareness rules and skills -- the turnkey ramp that
  gets a workstation monitored and lets the developer see verdicts from
  inside Claude Code.

Corollary: a security *decision* never moves into the package. Dismissing
findings, clearing divergence state, or any verdict-mutating capability
stays operator-only on the EDAMAME side (the MCP observer-independence
policy). The package observes and onboards; it never adjudicates.

## Plugin Distribution

The plugin uses Claude Code's native distribution system:

- `.claude-plugin/plugin.json` -- plugin manifest
- `.claude-plugin/marketplace.json` -- self-hosted marketplace catalog
- `.mcp.json` -- MCP server definition using `${CLAUDE_PLUGIN_ROOT}`

Users install via:
```shell
/plugin marketplace add edamametechnologies/edamame_claude_code
/plugin install edamame@edamame-security
```

The `${CLAUDE_PLUGIN_ROOT}` variable in `.mcp.json` resolves to the plugin
cache directory, making the MCP server path portable without an installer.
