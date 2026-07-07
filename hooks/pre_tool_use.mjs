#!/usr/bin/env node
//
// EDAMAME PreToolUse hook for Claude Code (A3 tool-call firewall, live gating).
//
// Claude Code invokes this on every tool call BEFORE the tool runs. The hook
// classifies the proposed call into EDAMAME's coarse tool-class taxonomy
// (metadata only -- never the command string, file contents, or full URL),
// asks the local EDAMAME MCP server for an allow / hold / block decision via
// `evaluate_pre_execution_tool_call`, and translates that into Claude Code's
// PreToolUse permission decision:
//
//   EDAMAME allow  -> proceed silently (no output)
//   EDAMAME hold   -> poll until the operator approves/denies in the app;
//                     approve -> allow, deny/expire -> deny, budget out -> ask
//   EDAMAME block  -> deny
//
// It NEVER approves a held call on the agent's behalf -- resolution is an
// operator-only action in the EDAMAME app. The hook only asks and enforces.
//
// Failure handling is fail-open by default (EDAMAME down / not paired ->
// proceed) so the firewall never bricks a developer's workflow; set
// preExecutionFailMode="closed" to fail deny instead.

import fs from "node:fs/promises";
import path from "node:path";

import { ensureDirectory, loadConfig, sha256 } from "../service/config.mjs";
import { makeEdamameClient } from "../bridge/edamame_client.mjs";

const EVALUATE_TOOL = "evaluate_pre_execution_tool_call";

// Tools that never change state and carry no sensitive egress: fast-path them
// locally so the common read/search/plan calls never pay an EDAMAME round-trip.
// Read/NotebookRead are handled separately (sensitive paths are NOT skipped).
const FAST_PATH_ALLOW_TOOLS = new Set([
  "Glob",
  "Grep",
  "LS",
  "TodoWrite",
  "Task",
  "BashOutput",
  "KillShell",
  "ExitPlanMode",
  "WebSearch",
]);

const FILE_WRITE_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit"]);
const FILE_READ_TOOLS = new Set(["Read", "NotebookRead"]);

// Default sensitive-path substrings (matched case-insensitively). A Read of a
// path matching one of these is escalated from the (fast-pathed) file_read
// class to secret_access so EDAMAME actually scores it.
const DEFAULT_SENSITIVE_READ_PATTERNS = [
  ".env",
  ".pem",
  ".key",
  "id_rsa",
  "id_ed25519",
  "id_ecdsa",
  ".p12",
  ".pfx",
  ".ppk",
  "credentials",
  "/.aws/",
  "\\.aws\\",
  "/.ssh/",
  "\\.ssh\\",
  "/.kube/",
  ".npmrc",
  ".netrc",
  ".pgpass",
  ".git-credentials",
  "/secrets/",
  ".keychain",
  ".dockercfg",
  "/.docker/config",
];

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value;
  }
  return "";
}

function toolInputPath(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return "";
  return firstString(
    toolInput.file_path,
    toolInput.filePath,
    toolInput.notebook_path,
    toolInput.notebookPath,
    toolInput.path,
  );
}

function matchesSensitiveRead(filePath, patterns) {
  if (!filePath) return false;
  const lower = filePath.toLowerCase();
  return patterns.some((pattern) => lower.includes(pattern.toLowerCase()));
}

function isPrivateHost(host) {
  if (!host) return false;
  if (host.endsWith(".local") || host.endsWith(".lan") || host.endsWith(".internal")) return true;
  if (host === "0.0.0.0") return true;
  if (/^10\./.test(host)) return true;
  if (/^192\.168\./.test(host)) return true;
  if (/^172\.(1[6-9]|2\d|3[0-1])\./.test(host)) return true;
  if (/^169\.254\./.test(host)) return true;
  return false;
}

// Classify a URL host into an EDAMAME sink trust zone. Only the coarse zone
// slug is ever emitted -- the URL itself never leaves the hook.
function sinkZoneFromUrl(url) {
  if (typeof url !== "string" || !url.trim()) return "unknown";
  let parsed;
  try {
    parsed = new URL(url.trim());
  } catch (_error) {
    return "unknown";
  }
  const host = parsed.hostname.toLowerCase();
  if (host === "localhost" || host === "127.0.0.1" || host === "::1") return "trust1";
  if (isPrivateHost(host)) return "trust2_lan";
  return "trust2_public";
}

// Map a Claude Code tool call to a metadata-only EDAMAME PreExecutionRequest,
// or signal that it should be fast-path allowed without contacting EDAMAME.
//
// Returns { skip: true } for benign fast-path tools, or
// { skip: false, request: {...} } with a PreExecutionRequest payload.
export function classifyToolCall(toolName, toolInput, options = {}) {
  const agentType = options.agentType || "claude_code";
  const name = String(toolName || "").trim();
  if (!name) return { skip: true, reason: "empty_tool_name" };

  const sensitivePatterns = Array.isArray(options.sensitiveReadPatterns) && options.sensitiveReadPatterns.length > 0
    ? options.sensitiveReadPatterns
    : DEFAULT_SENSITIVE_READ_PATTERNS;

  const base = {
    agent_type: agentType,
    tool_name: name,
    data_flow_taint: null,
    sink_trust_zone: "unknown",
    origin_untrusted: false,
  };

  if (FAST_PATH_ALLOW_TOOLS.has(name)) {
    return { skip: true, reason: "fast_path_read_only" };
  }

  if (name === "Bash") {
    return { skip: false, request: { ...base, tool_class: "shell" } };
  }

  if (FILE_WRITE_TOOLS.has(name)) {
    return { skip: false, request: { ...base, tool_class: "file_write" } };
  }

  if (FILE_READ_TOOLS.has(name)) {
    const filePath = toolInputPath(toolInput);
    if (matchesSensitiveRead(filePath, sensitivePatterns)) {
      return {
        skip: false,
        request: { ...base, tool_class: "secret_access", data_flow_taint: "secret" },
      };
    }
    // Ordinary file reads are benign -- fast-path them.
    return { skip: true, reason: "non_sensitive_read" };
  }

  if (name === "WebFetch") {
    const url = toolInput && typeof toolInput === "object" ? toolInput.url : "";
    return {
      skip: false,
      request: {
        ...base,
        tool_class: "network",
        // Fetched web content is an untrusted origin that can drive later calls.
        origin_untrusted: true,
        sink_trust_zone: sinkZoneFromUrl(url),
      },
    };
  }

  if (name.startsWith("mcp__")) {
    return { skip: false, request: { ...base, tool_class: "mcp_tool" } };
  }

  // Unknown tool: EDAMAME cannot gate a class it does not model, so avoid the
  // round-trip and let it proceed. (New gateable tools are added explicitly.)
  return { skip: true, reason: "unclassified_tool" };
}

// Translate an EDAMAME decision payload into the hook's enforced result.
// `emit: false` means "proceed silently" (Claude runs the tool normally).
export function decisionResult(decision, edamame = {}) {
  switch (decision) {
    case "allow":
      return { decision: "allow", emit: false, edamame };
    case "hold":
      return { decision: "ask", emit: true, edamame, reason: reasonFor("hold", edamame) };
    case "block":
      return { decision: "deny", emit: true, edamame, reason: reasonFor("block", edamame) };
    default:
      return { decision: "deny", emit: true, edamame, reason: reasonFor("block", edamame) };
  }
}

function reasonFor(kind, edamame) {
  const rationale = firstString(edamame && edamame.rationale);
  const severity = firstString(edamame && edamame.severity);
  const tail = rationale ? ` ${rationale}` : "";
  const sev = severity ? ` [${severity}]` : "";
  if (kind === "hold") {
    return `EDAMAME held this tool call for operator approval${sev}.${tail} Approve or deny it in the EDAMAME app.`;
  }
  return `EDAMAME blocked this tool call${sev}.${tail}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Best-effort cross-process dedup: when the same tool call fires twice (e.g. a
// user installed BOTH the marketplace plugin hook and the app/posture
// settings.json hook), only the first process creates a pending entry; the
// second follows the same pending id via the shared record file. Keyed by
// session + tool_use id (hashed locally; never transmitted).
async function withDedup(config, key, run, deps = {}) {
  const ttlMs = config.preExecutionDedupTtlMs;
  if (!(ttlMs > 0) || !key) {
    return run({ recordPendingId: async () => {}, followPendingId: async () => null });
  }

  const dir = path.join(config.stateDir, "precheck-dedup");
  const recPath = path.join(dir, `${sha256(key)}.json`);
  const lockPath = `${recPath}.lock`;
  const now = deps.now || (() => Date.now());
  const sleepFn = deps.sleep || sleep;

  try {
    await ensureDirectory(dir);
  } catch (_error) {
    return run({ recordPendingId: async () => {}, followPendingId: async () => null });
  }

  // Try to become the leader by atomically creating the lock file.
  let isLeader = false;
  try {
    const handle = await fs.open(lockPath, "wx");
    await handle.close();
    isLeader = true;
  } catch (_error) {
    isLeader = false;
  }

  if (isLeader) {
    const recordPendingId = async (pendingId, decision) => {
      try {
        await fs.writeFile(recPath, JSON.stringify({ pendingId, decision, ts: now() }), "utf8");
      } catch (_error) {
        // Non-fatal: dedup is best-effort.
      }
    };
    try {
      return await run({ recordPendingId, followPendingId: async () => null });
    } finally {
      await fs.rm(lockPath, { force: true }).catch(() => {});
    }
  }

  // Follower: wait briefly for the leader's record, then follow its pending id.
  const followDeadline = now() + Math.min(2000, ttlMs);
  while (now() < followDeadline) {
    try {
      const raw = await fs.readFile(recPath, "utf8");
      const rec = JSON.parse(raw);
      if (rec && typeof rec.pendingId === "string" && rec.pendingId) {
        return { follow: true, pendingId: rec.pendingId };
      }
      if (rec && rec.decision) {
        return { follow: true, decision: rec.decision };
      }
    } catch (_error) {
      // Not written yet.
    }
    // If the leader's lock is gone and still no record, the leader likely
    // crashed -- fall through and evaluate independently.
    try {
      await fs.access(lockPath);
    } catch (_error) {
      break;
    }
    await sleepFn(120);
  }
  return run({ recordPendingId: async () => {}, followPendingId: async () => null });
}

// Core hook logic. `deps` allows tests to inject a fake client, clock, and
// sleep so the poll loop and dedup are deterministic.
export async function runPreToolUse(event, deps = {}) {
  const config = deps.config;
  if (!config || config.preExecutionEnabled === false) {
    return { decision: "allow", emit: false, reason: "disabled" };
  }

  const toolName = event && typeof event === "object" ? event.tool_name : "";
  const toolInput = event && typeof event === "object" ? event.tool_input : undefined;

  const classification = classifyToolCall(toolName, toolInput, {
    agentType: config.agentType,
    sensitiveReadPatterns: config.preExecutionSensitiveReadPatterns,
  });
  if (classification.skip) {
    return { decision: "allow", emit: false, reason: classification.reason };
  }

  const request = classification.request;

  const makeClient = deps.makeClient || makeEdamameClient;
  let client;
  try {
    client = await makeClient(config);
  } catch (error) {
    return failResult(config, error);
  }

  const dedupKey = firstString(
    event && event.tool_use_id,
    event && event.session_id ? `${event.session_id}:${sha256(`${toolName}:${safeJson(toolInput)}`)}` : "",
  );

  try {
    const outcome = await withDedup(
      config,
      dedupKey,
      async ({ recordPendingId }) => {
        return evaluateWithHoldPollingRecorded(client, request, config, recordPendingId, deps);
      },
      deps,
    );

    // Follower path returned by withDedup (dedup hit): follow the leader.
    if (outcome && outcome.follow) {
      if (outcome.pendingId) {
        return pollExistingPending(client, outcome.pendingId, config, deps);
      }
      if (outcome.decision) {
        return decisionResult(outcome.decision, {});
      }
    }
    return outcome;
  } catch (error) {
    return failResult(config, error);
  }
}

function safeJson(value) {
  try {
    return JSON.stringify(value);
  } catch (_error) {
    return "";
  }
}

// Wraps evaluateWithHoldPolling so the leader records the pending id as soon as
// it is known, letting a concurrent follower attach to the same held call.
async function evaluateWithHoldPollingRecorded(client, request, config, recordPendingId, deps = {}) {
  const now = deps.now || (() => Date.now());
  const sleepFn = deps.sleep || sleep;
  const timeoutMs = config.preExecutionTimeoutMs;

  const fresh = await client.invoke(
    EVALUATE_TOOL,
    { request_json: JSON.stringify(request) },
    timeoutMs,
  );
  const freshObj = fresh && typeof fresh === "object" ? fresh : {};
  const decision = firstString(freshObj.decision) || "block";

  if (decision !== "hold") {
    await recordPendingId(null, decision);
    return decisionResult(decision, freshObj);
  }

  const pendingId = firstString(freshObj.pending_id);
  if (!pendingId) {
    return decisionResult("block", { ...freshObj, rationale: "held without a pending id (fail-closed)" });
  }
  await recordPendingId(pendingId, "hold");

  const ttlSecs = Number(freshObj.hold_ttl_secs);
  const ttlBudgetMs = Number.isFinite(ttlSecs) && ttlSecs > 0 ? ttlSecs * 1000 : Infinity;
  const budgetMs = Math.min(config.preExecutionHoldPollBudgetSecs * 1000, ttlBudgetMs);
  const intervalMs = config.preExecutionHoldPollIntervalMs;
  const deadline = now() + budgetMs;

  let last = freshObj;
  while (now() < deadline) {
    await sleepFn(intervalMs);
    const polled = await client.invoke(
      EVALUATE_TOOL,
      { request_json: JSON.stringify({ pending_id: pendingId }) },
      timeoutMs,
    );
    last = polled && typeof polled === "object" ? polled : {};
    const polledDecision = firstString(last.decision) || "block";
    if (polledDecision === "allow") return decisionResult("allow", last);
    if (polledDecision === "block") return decisionResult("block", last);
  }

  if (config.preExecutionHoldTimeoutDecision === "deny") {
    return {
      decision: "deny",
      emit: true,
      edamame: last,
      reason: "EDAMAME held this tool call and no operator decision arrived in time (fail-closed).",
    };
  }
  return {
    decision: "ask",
    emit: true,
    edamame: last,
    reason:
      "EDAMAME is still holding this tool call for operator approval (no decision yet). Approve or deny it in the EDAMAME app, or decide here.",
  };
}

// Poll an existing pending id (dedup follower path) until it resolves or the
// budget runs out.
async function pollExistingPending(client, pendingId, config, deps = {}) {
  const now = deps.now || (() => Date.now());
  const sleepFn = deps.sleep || sleep;
  const timeoutMs = config.preExecutionTimeoutMs;
  const budgetMs = Math.min(
    config.preExecutionHoldPollBudgetSecs * 1000,
    PRE_EXECUTION_HOLD_TTL_MS,
  );
  const intervalMs = config.preExecutionHoldPollIntervalMs;
  const deadline = now() + budgetMs;

  let last = {};
  while (now() < deadline) {
    const polled = await client.invoke(
      EVALUATE_TOOL,
      { request_json: JSON.stringify({ pending_id: pendingId }) },
      timeoutMs,
    );
    last = polled && typeof polled === "object" ? polled : {};
    const polledDecision = firstString(last.decision) || "block";
    if (polledDecision === "allow") return decisionResult("allow", last);
    if (polledDecision === "block") return decisionResult("block", last);
    await sleepFn(intervalMs);
  }
  if (config.preExecutionHoldTimeoutDecision === "deny") {
    return { decision: "deny", emit: true, edamame: last, reason: "EDAMAME hold timed out (fail-closed)." };
  }
  return {
    decision: "ask",
    emit: true,
    edamame: last,
    reason: "EDAMAME is still holding this tool call for operator approval. Decide in the app or here.",
  };
}

const PRE_EXECUTION_HOLD_TTL_MS = 300 * 1000;

function failResult(config, error) {
  const message = String((error && error.message) || error || "unknown");
  if (config.preExecutionFailMode === "closed") {
    return {
      decision: "deny",
      emit: true,
      reason: `EDAMAME firewall could not verify this tool call and is configured to fail closed (${message}).`,
      error: message,
    };
  }
  // Fail open: EDAMAME unavailable / not paired should not block the workflow.
  return { decision: "allow", emit: false, reason: "edamame_unavailable_fail_open", error: message };
}

// --- CLI entry (stdin JSON event -> stdout permission decision) ---

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--config" && i + 1 < argv.length) {
      options.configPath = argv[i + 1];
      i += 1;
    }
  }
  return options;
}

export function emitAndExit(result, write = (text) => process.stdout.write(text)) {
  if (!result || !result.emit) {
    process.exit(0);
    return;
  }
  const output = {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: result.decision,
      permissionDecisionReason: result.reason || "",
    },
    suppressOutput: true,
  };
  write(`${JSON.stringify(output)}\n`);
  process.exit(0);
}

async function main() {
  let event = {};
  try {
    const raw = await readStdin();
    event = raw && raw.trim() ? JSON.parse(raw) : {};
  } catch (_error) {
    // Can't parse the event -- do not break Claude Code; allow silently.
    process.exit(0);
    return;
  }

  let config;
  try {
    const cliOptions = parseArgs(process.argv.slice(2));
    config = await loadConfig(cliOptions.configPath ? { configPath: cliOptions.configPath } : {});
  } catch (_error) {
    process.exit(0);
    return;
  }

  const result = await runPreToolUse(event, { config });
  emitAndExit(result);
}

const invokedDirectly =
  process.argv[1] && (process.argv[1].endsWith("pre_tool_use.mjs") || process.argv[1].endsWith("pre_tool_use"));
if (invokedDirectly) {
  main().catch(() => process.exit(0));
}
