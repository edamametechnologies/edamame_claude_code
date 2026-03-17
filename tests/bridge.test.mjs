import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  createBackgroundRefreshLoop,
  createClaudeCodeDrivenRefresh,
  handleRequest,
  tryExtractMessages,
} from "../bridge/claude_code_edamame_mcp.mjs";
import { buildControlCenterPayload } from "../service/control_center.mjs";
import { runHealthcheck } from "../service/health.mjs";
import { runLatestExtrapolation } from "../service/claude_code_extrapolator.mjs";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));

async function writeMockPostureCli(root, options = {}) {
  const scriptPath = path.join(root, "mock-edamame-posture.sh");
  const statePath = path.join(root, "mock-edamame-posture.state");
  const generatedPsk = options.generatedPsk || "generated-psk-abcdefghijklmnopqrstuvwxyz012345";
  const script = `#!/usr/bin/env bash
set -euo pipefail

STATE_FILE=${JSON.stringify(statePath)}
GENERATED_PSK=${JSON.stringify(generatedPsk)}

case "\${1:-}" in
  mcp-generate-psk|background-mcp-generate-psk)
    echo "$GENERATED_PSK"
    echo "# Save this PSK securely - it's required for MCP client authentication"
    ;;
  mcp-start|background-mcp-start)
    port="\${2:-3000}"
    psk="\${3:-$GENERATED_PSK}"
    cat > "$STATE_FILE" <<EOF
port=$port
url=http://127.0.0.1:$port/mcp
EOF
    echo "[OK] MCP server started successfully"
    echo "   Port: $port"
    echo "   URL: http://127.0.0.1:$port/mcp"
    echo "   PSK: $psk"
    ;;
  mcp-stop|background-mcp-stop)
    rm -f "$STATE_FILE"
    echo "[OK] MCP server stopped"
    ;;
  mcp-status|background-mcp-status)
    if [[ -f "$STATE_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$STATE_FILE"
      echo "[OK] MCP server is running"
      echo "   Port: $port"
      echo "   URL: $url"
    else
      echo "MCP server is not running"
    fi
    ;;
  *)
    echo "unsupported mock posture command: $*" >&2
    exit 1
    ;;
esac
`;
  await fs.writeFile(scriptPath, script, "utf8");
  await fs.chmod(scriptPath, 0o755);
  return { scriptPath, generatedPsk, statePath };
}

async function writeMockSystemctl(root, options = {}) {
  const scriptPath = path.join(root, "mock-systemctl.sh");
  const loadState = options.loadState || "loaded";
  const unitFileState = options.unitFileState || "enabled";
  const activeState = options.activeState || "active";
  const script = `#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  show)
    if [[ "\${2:-}" != "edamame_posture.service" ]]; then
      echo "unexpected service name: \${2:-}" >&2
      exit 1
    fi
    echo "LoadState=${loadState}"
    echo "UnitFileState=${unitFileState}"
    echo "ActiveState=${activeState}"
    ;;
  *)
    echo "unsupported mock systemctl command: $*" >&2
    exit 1
    ;;
esac
`;
  await fs.writeFile(scriptPath, script, "utf8");
  await fs.chmod(scriptPath, 0o755);
  return { scriptPath, loadState, unitFileState, activeState };
}

async function makeBridgeFixture(options = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "claude-code-edamame-bridge-"));
  const workspaceRoot = path.join(root, "edamame_project");
  const claudeProjectsRoot = path.join(root, "claude-projects");
  const transcriptDir = path.join(claudeProjectsRoot, "fixture-workspace", "agent-transcripts");
  const configPath = path.join(root, "config.json");
  const pskPath = path.join(root, ".edamame_psk");
  const hostKind = options.hostKind || "edamame_app";
  const endpoint = options.endpoint || "http://127.0.0.1:65535/mcp";
  const postureWrapperPath = path.join(root, "edamame_posture_daemon.sh");
  const postureConfigPath = path.join(root, "edamame_posture.conf");
  const postureFixture = options.withMockPostureCli
    ? await writeMockPostureCli(root, options.mockPostureCliOptions)
    : null;
  const systemctlFixture = options.withMockSystemctl
    ? await writeMockSystemctl(root, options.mockSystemctlOptions)
    : null;

  await fs.mkdir(path.join(workspaceRoot, "src"), { recursive: true });
  await fs.mkdir(transcriptDir, { recursive: true });
  if (options.withPsk !== false) {
    await fs.writeFile(pskPath, `${options.pskValue || "psk-test"}\n`, "utf8");
  }
  if (options.withMockSystemServiceFiles !== false) {
    await fs.writeFile(postureWrapperPath, "#!/usr/bin/env bash\nexit 0\n", "utf8");
    await fs.chmod(postureWrapperPath, 0o755);
    await fs.writeFile(postureConfigPath, "daemon_config=true\n", "utf8");
  }

  await fs.writeFile(
    configPath,
    JSON.stringify(
      {
        workspace_root: workspaceRoot,
        claude_code_projects_root: claudeProjectsRoot,
        state_dir: path.join(root, "state"),
        host_kind: hostKind,
        posture_cli_command: postureFixture?.scriptPath,
        systemctl_command: systemctlFixture?.scriptPath,
        posture_daemon_wrapper_path: postureWrapperPath,
        posture_config_path: postureConfigPath,
        edamame_mcp_endpoint: endpoint,
        edamame_mcp_psk_file: pskPath,
      },
      null,
      2,
    ),
    "utf8",
  );

  await fs.writeFile(
    path.join(transcriptDir, "session-two.txt"),
    `user:
<user_query>
inspect src/lib.rs
</user_query>

assistant:
[Tool call] ReadFile
  path: ${workspaceRoot}/src/lib.rs
assistant:
Only inspect ${workspaceRoot}/src/lib.rs
`,
    "utf8",
  );

  return {
    configPath,
    workspaceRoot,
    claudeCodeProjectsRoot: claudeProjectsRoot,
    transcriptProjectHints: ["fixture-workspace"],
    transcriptLimit: 4,
    transcriptRecencyHours: 48,
    transcriptActiveWindowMinutes: 5,
    stateDir: path.join(root, "state"),
    agentType: "claude_code",
    agentInstanceId: "claude-code-bridge-test",
    hostKind,
    postureCliCommand: postureFixture?.scriptPath,
    systemctlCommand: systemctlFixture?.scriptPath,
    postureDaemonWrapperPath: postureWrapperPath,
    postureConfigPath: postureConfigPath,
    claudeCodeLlmHosts: ["api.anthropic.com:443"],
    edamameMcpEndpoint: endpoint,
    edamameMcpPskFile: pskPath,
    verdictHistoryLimit: 5,
    postureFixture,
    systemctlFixture,
  };
}

async function withMockMcpAuthServer(handler) {
  const server = http.createServer((request, response) => {
    if (request.method !== "POST" || request.url !== "/mcp") {
      response.writeHead(404, { "Content-Type": "text/plain" });
      response.end("not found");
      return;
    }
    response.writeHead(401, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ error: "invalid PSK" }));
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const endpoint = `http://127.0.0.1:${address.port}/mcp`;

  try {
    return await handler(endpoint);
  } finally {
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  }
}

test("handleRequest returns MCP initialize and tool list responses", async () => {
  const config = await makeBridgeFixture();

  const initializeResponse = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {},
  });
  assert.equal(initializeResponse.result.serverInfo.name, "edamame");
  assert.deepEqual(initializeResponse.result.capabilities.resources, {});

  const toolsResponse = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  });
  assert.ok(
    toolsResponse.result.tools.some((tool) => tool.name === "claude_code.refresh_behavioral_model"),
  );
  const controlCenterTool = toolsResponse.result.tools.find(
    (tool) => tool.name === "edamame_claude_code_control_center",
  );
  assert.ok(controlCenterTool, "control center tool should be defined");
  assert.equal(
    toolsResponse.result.tools.some((tool) => tool.name === "edamame_claude_code_control_center_apply_pairing"),
    true,
  );
  assert.equal(
    toolsResponse.result.tools.some((tool) => tool.name === "edamame_claude_code_control_center_run_host_action"),
    true,
  );
});

test("tryExtractMessages accepts LF-only framed MCP messages", () => {
  const message = {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
    },
  };
  const payload = JSON.stringify(message);
  const framed = `Content-Length: ${Buffer.byteLength(payload, "utf8")}\n\n${payload}`;

  const extracted = tryExtractMessages(framed);

  assert.deepEqual(extracted.messages, [message]);
  assert.equal(extracted.remaining, "");
});

test("tryExtractMessages accepts raw JSON MCP messages", () => {
  const message = {
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      capabilities: {
        roots: {
          listChanged: false,
        },
      },
    },
    jsonrpc: "2.0",
    id: 1,
  };

  const extracted = tryExtractMessages(JSON.stringify(message));

  assert.deepEqual(extracted.messages, [message]);
  assert.equal(extracted.remaining, "");
});

test("bridge can dispatch dry-run extrapolation and healthcheck tools", async () => {
  const config = await makeBridgeFixture();

  const extrapolatorResponse = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: {
      name: "claude_code.refresh_behavioral_model",
      arguments: { dry_run: true },
    },
  });
  const extrapolatorPayload = JSON.parse(extrapolatorResponse.result.content[0].text);
  assert.equal(extrapolatorPayload.sessionCount, 1);
  assert.deepEqual(extrapolatorPayload.reasons, ["dry_run"]);
  assert.equal(extrapolatorPayload.agentType, "claude_code");
  assert.equal(extrapolatorPayload.agentInstanceId, "claude-code-bridge-test");
  assert.equal(extrapolatorPayload.rawSessions.agent_type, "claude_code");
  assert.equal(extrapolatorPayload.rawSessions.agent_instance_id, "claude-code-bridge-test");
  assert.equal(extrapolatorPayload.rawSessions.source_kind, "claude_code");
  assert.equal(extrapolatorPayload.rawSessions.sessions.length, 1);

  const healthResponse = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 4,
    method: "tools/call",
    params: {
      name: "claude_code.healthcheck",
      arguments: { strict: true },
    },
  });
  const healthPayload = JSON.parse(healthResponse.result.content[0].text);
  assert.equal(Array.isArray(healthPayload.checks), true);
  assert.equal(healthPayload.checks.some((check) => check.name === "psk.file"), true);
});

test("control center pairing stores PSK and updates config", async () => {
  const config = await makeBridgeFixture({ withPsk: false });

  const response = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 10,
    method: "tools/call",
    params: {
      name: "edamame_claude_code_control_center_apply_pairing",
      arguments: {
        host_kind: "edamame_posture",
        endpoint: "http://127.0.0.1:4010/mcp",
        psk: "pairing-secret",
      },
    },
  });

  const payload = response.result.structuredContent;
  const storedPsk = await fs.readFile(config.edamameMcpPskFile, "utf8");
  const storedConfig = JSON.parse(await fs.readFile(config.configPath, "utf8"));

  assert.equal(storedPsk.trim(), "pairing-secret");
  assert.equal(storedConfig.host_kind, "edamame_posture");
  assert.equal(storedConfig.edamame_mcp_endpoint, "http://127.0.0.1:4010/mcp");
  assert.equal(storedConfig.edamame_mcp_psk_file, config.edamameMcpPskFile);
  assert.equal(payload.pairing.configured, true);
  assert.equal(payload.config.hostKind, "edamame_posture");
});

test("control center can auto-pair a local posture host", async () => {
  const config = await makeBridgeFixture({
    withPsk: false,
    hostKind: "edamame_posture",
    withMockPostureCli: true,
    withMockSystemctl: true,
  });

  const response = await handleRequest(config, {
    jsonrpc: "2.0",
    id: 11,
    method: "tools/call",
    params: {
      name: "edamame_claude_code_control_center_run_host_action",
      arguments: {
        action: "generate_and_start",
        host_kind: "edamame_posture",
        endpoint: "http://127.0.0.1:4010/mcp",
      },
    },
  });

  const payload = response.result.structuredContent;
  const storedPsk = await fs.readFile(config.edamameMcpPskFile, "utf8");
  const storedConfig = JSON.parse(await fs.readFile(config.configPath, "utf8"));

  assert.equal(storedPsk.trim(), config.postureFixture.generatedPsk);
  assert.equal(storedConfig.host_kind, "edamame_posture");
  assert.equal(storedConfig.edamame_mcp_endpoint, "http://127.0.0.1:4010/mcp");
  assert.equal(payload.pairing.configured, true);
  assert.equal(payload.hostController.running, true);
});

test("background refresh loop runs on startup and interval without overlap", async () => {
  const calls = [];
  let concurrentCalls = 0;
  let maxConcurrentCalls = 0;

  const loop = createBackgroundRefreshLoop(
    { divergenceIntervalSecs: 120 },
    {
      intervalMs: 15,
      startupDelayMs: 0,
      runExtrapolation: async () => {
        concurrentCalls += 1;
        maxConcurrentCalls = Math.max(maxConcurrentCalls, concurrentCalls);
        calls.push(Date.now());
        await new Promise((resolve) => setTimeout(resolve, 20));
        concurrentCalls -= 1;
        return {
          success: true,
          sessionCount: 1,
          upserted: true,
          reasons: ["test_refresh"],
        };
      },
    },
  );

  loop.start();
  await new Promise((resolve) => setTimeout(resolve, 70));
  loop.stop();

  assert.ok(calls.length >= 2);
  assert.equal(maxConcurrentCalls, 1);
});

test("claude-code-driven refresh skips recent persisted runs", async () => {
  const refresh = createClaudeCodeDrivenRefresh(
    { divergenceIntervalSecs: 120 },
    {
      loadState: async () => ({
        lastRunAt: new Date().toISOString(),
      }),
      runExtrapolation: async () => {
        throw new Error("runExtrapolation should not be called");
      },
      logRefresh: false,
    },
  );

  const result = await refresh.maybeRun("tool_call:test");
  assert.equal(result.skipped, true);
  assert.equal(result.reason, "recent_persisted");
});

test("runHealthcheck surfaces MCP auth failures clearly", async () => {
  await withMockMcpAuthServer(async (endpoint) => {
    const config = await makeBridgeFixture({
      endpoint,
      pskValue: "wrong-psk",
    });

    const result = await runHealthcheck(config, { strict: false });
    const endpointCheck = result.checks.find((check) => check.name === "mcp.endpoint");
    const authCheck = result.checks.find((check) => check.name === "mcp.authentication");

    assert.equal(endpointCheck?.ok, false);
    assert.equal(endpointCheck?.detail?.reason, "edamame_mcp_auth_failed");
    assert.match(endpointCheck?.detail?.message || "", /http_401/i);
    assert.match(endpointCheck?.detail?.summary || "", /PSK/i);
    assert.equal(authCheck?.ok, false);
    assert.equal(authCheck?.detail?.status, "auth_failed");
  });
});
