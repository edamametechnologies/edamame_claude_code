# EDAMAME Claude Code Demo Triggers

User-space injector scripts that trigger detectable security events in the EDAMAME agentic pipeline. Designed to run from a Claude Code terminal on macOS, Linux, or Windows.

## Scripts

### trigger_blacklist_comm.py

Generates TLS egress to known-blacklisted sinkhole IPs while holding SSH credential files open.

- **Detection:** `skill_supply_chain` finding (blacklisted session + sensitive open files)
- **Mechanism:** The same Python process owns the network flow and the file handles, so flodbadd's L7 attribution ties them together.

### trigger_cve_token_exfil.py

Streams TCP traffic to a high port (portquiz.net:63169) while holding `~/.ssh/` and `~/.env` files open.

- **Detection:** `token_exfiltration` finding (anomalous session + sensitive open files)
- **CVE anchor:** CVE-2025-52882 / CVE-2026-25253
- **Claude Code compatibility:** Runs as a direct Python child of the Claude Code IDE -- no `/tmp` lineage, so the self-access suppression heuristic does not apply.

### trigger_cve_sandbox_escape.py

Compiles and launches a small C binary under `/tmp` that generates UDP egress. The binary's parent path is `/tmp/...`, which is the exact pattern the sandbox exploitation detector checks.

- **Detection:** `sandbox_exploitation` finding (parent_process_path starts with `/tmp/`)
- **CVE anchor:** CVE-2026-24763
- **Claude Code compatibility:** Launched from a Claude Code terminal. The Python wrapper has normal lineage; the compiled child has `/tmp` ancestry.
- **Requirement:** A C compiler (`cc`, `gcc`, or `clang`). Falls back to a pure-Python UDP loop on Windows (no `/tmp` lineage in that case).

### trigger_divergence.py

Connects to 12 unusual public endpoints on uncommon ports from a Claude Code-parented process. No sensitive files are accessed -- this is purely about unexpected network egress.

- **Detection:** Divergence engine produces a `DIVERGENCE` verdict when >5 unexplained destinations are observed.
- **Prerequisite:** A behavioral model must be active and non-stale in EDAMAME. Without a model, the engine returns `NO_MODEL`.
- **Mechanism:** The destinations (portquiz.net on ports 9999, 12345, 31337, etc.; neverssl.com, example.com, httpbin.org, icanhazip.com) are unlikely to appear in any normal Claude Code behavioral model. Each round opens all 12 connections, holds them for 15 seconds, then closes.

### cleanup.py

Stops all running demo injectors and removes only the files that these scripts created. Never touches pre-existing user files.

## Usage

```bash
cd demo

# Blacklisted-site communication
python3 trigger_blacklist_comm.py

# CVE-2025-52882 token exfiltration
python3 trigger_cve_token_exfil.py

# CVE-2026-24763 sandbox escape
python3 trigger_cve_sandbox_escape.py

# Divergence (requires active behavioral model)
python3 trigger_divergence.py

# Stop everything and clean up
python3 cleanup.py
```

All scripts accept `--duration N` to auto-stop after N seconds, and `--help` for full options.

## How It Works

Each script is designed to trigger a specific detection pathway in the EDAMAME agentic pipeline:

```
Script (user-space) -> network traffic [+ file access for CVE scripts]
        |
        v
flodbadd capture engine
  - Session tracking, iForest anomaly scoring, blacklist matching
  - L7 process attribution (open files, parent lineage)
        |
        +--- Vulnerability detector (edamame_core)
        |      - token_exfiltration: anomalous session + sensitive open files
        |      - skill_supply_chain: blacklisted session + sensitive open files
        |      - sandbox_exploitation: /tmp parent lineage
        |
        +--- Divergence engine (edamame_core)
               - Correlates behavioral model predictions vs live session destinations
               - Fires DIVERGENCE when >5 destinations are unexplained by the model
               - No file access required -- purely network-based
```

## Non-eBPF Platform Compatibility

On platforms without eBPF (macOS, Windows, Linux without eBPF), flodbadd uses periodic netstat/libproc polling to attribute sockets to processes. Sensitive file scanning runs on a separate cadence:

| Platform | Sensitive file scan interval |
|----------|------------------------------|
| Linux    | 30 seconds                   |
| macOS    | 60 seconds                   |
| Windows  | 120 seconds                  |

For the vulnerability detector to tie a network session to its open files, the connection must stay alive long enough for both the socket-to-PID resolution and the file scan to overlap on the same process. All scripts in this folder maintain persistent, long-lived connections (10-15+ seconds minimum) rather than short connect-send-close patterns to ensure they are captured by the polling-based L7 attribution.

## Notes

- All scripts are user-space only; no root/admin required.
- Demo state (PIDs, created-file markers) lives in `/tmp/edamame_claude_code_demo` (or `%TEMP%\edamame_claude_code_demo` on Windows).
- Scripts never overwrite existing user files. If a seed file already exists, the injector reads it in place.
- The Claude Code process tree lineage matters: scripts spawned from a Claude Code terminal have the Claude Code IDE as their parent, which is a normal desktop application -- this means they pass through the detection pipeline without being suppressed as "application self-access".

## Test Report

For a canonical test report and validation results, see [edamame_cursor/demo/TEST_REPORT_2026-03-15.md](https://github.com/edamametechnologies/edamame_cursor/blob/main/demo/TEST_REPORT_2026-03-15.md). The detection pathways are identical across Cursor, Claude Code, and OpenClaw integrations.
