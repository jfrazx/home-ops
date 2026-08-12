/**
 * Minimal GitHub webhook receiver for docs-mcp-server.
 *
 * docs-mcp-server has no webhook support of its own (upstream lists it under
 * "future enhancements" in docs/concepts/refresh-architecture.md), so this sits
 * beside it and triggers the same `refresh` the nightly CronJob runs.
 *
 * It deliberately does very little:
 *   - verifies X-Hub-Signature-256 against GITHUB_WEBHOOK_SECRET
 *   - accepts only `push` events on the repo's own default branch
 *   - shells out to sync.sh, which refreshes (or scrapes) that one library
 *
 * This endpoint is reachable from the public internet, so every request is
 * rejected unless it clears all three checks above.
 *
 * There is no allowlist here any more. The set of indexed libraries lives only
 * in the store now (it used to be repos.txt, which this read on every request),
 * so sync.sh is the gate: it looks the library up and exits non-zero for
 * anything not already indexed. That is a stricter check than the old file --
 * it cannot drift from what is actually in the index -- at the cost of spawning
 * a short-lived process to reject an unknown repo. Reaching that point already
 * requires a valid signature.
 */
"use strict";

const http = require("node:http");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const PORT = Number(process.env.WEBHOOK_PORT || 8080);
const SECRET = process.env.GITHUB_WEBHOOK_SECRET || "";
const SYNC_SCRIPT = process.env.DOCS_MCP_SYNC_SCRIPT || "/etc/docs-mcp/sync.sh";
const MAX_BODY = 5 * 1024 * 1024; // GitHub caps payloads at 25MB; we need far less.

if (!SECRET) {
  console.error("[webhook] GITHUB_WEBHOOK_SECRET is not set; refusing to start");
  process.exit(1);
}

const log = (...args) => console.log("[webhook]", ...args);

function signatureIsValid(signature, body) {
  // Node joins duplicate request headers into a single string and only ever
  // hands back an array for set-cookie, so in practice this is always a string.
  // Guard on the type anyway: a delivery carrying anything other than exactly
  // one signature is anomalous and should be rejected rather than reconciled,
  // and it keeps Buffer.from() from throwing inside the request handler, which
  // has no try/catch and would take the process down rather than return 401.
  if (typeof signature !== "string" || signature.length === 0) return false;
  const expected =
    "sha256=" + crypto.createHmac("sha256", SECRET).update(body).digest("hex");
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(signature, "utf8");
  // timingSafeEqual throws on length mismatch, so compare lengths first.
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// One sync per repo at a time, so a burst of pushes cannot pile up concurrent
// jobs against the same library. A push that lands mid-sync is not dropped:
// it sets a pending flag and re-runs once, since the running sync may already
// have read the tree before that commit existed.
const inFlight = new Set();
const pending = new Set();

function triggerSync(repo) {
  if (inFlight.has(repo)) {
    pending.add(repo);
    log("sync already running for", repo, "- queued a follow-up run");
    return;
  }
  inFlight.add(repo);
  log("starting sync for", repo);

  // `repo` comes straight from the payload, so it is untrusted: it is passed as
  // a discrete argv entry, never interpolated into a shell string, and sync.sh
  // only acts on it if it matches a library already in the store.
  const child = spawn("/bin/sh", [SYNC_SCRIPT, repo], { stdio: "inherit" });

  const finish = (detail) => {
    inFlight.delete(repo);
    log("sync for", repo, detail);
    if (pending.delete(repo)) {
      log("running queued follow-up sync for", repo);
      triggerSync(repo);
    }
  };

  child.on("close", (code) => finish(`exited with ${code}`));
  child.on("error", (err) => finish(`failed to spawn: ${err.message}`));
}

const server = http.createServer((req, res) => {
  const reply = (code, message) => {
    res.writeHead(code, { "content-type": "text/plain" });
    res.end(message);
  };

  if (req.method === "GET" && req.url === "/healthz") return reply(200, "ok");
  if (req.method !== "POST") return reply(405, "method not allowed");

  const chunks = [];
  let size = 0;
  let aborted = false;

  req.on("data", (chunk) => {
    if (aborted) return;
    size += chunk.length;
    if (size > MAX_BODY) {
      aborted = true;
      reply(413, "payload too large");
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });

  req.on("end", () => {
    if (aborted) return;
    const body = Buffer.concat(chunks);

    if (!signatureIsValid(req.headers["x-hub-signature-256"], body)) {
      log("rejected delivery with bad or missing signature");
      return reply(401, "invalid signature");
    }

    const event = req.headers["x-github-event"];
    if (event === "ping") return reply(200, "pong");
    if (event !== "push") return reply(202, `ignoring ${event} event`);

    let payload;
    try {
      payload = JSON.parse(body.toString("utf8"));
    } catch {
      return reply(400, "invalid json");
    }

    const repo = payload.repository?.full_name;
    const defaultBranch = payload.repository?.default_branch;
    const ref = payload.ref;

    if (!repo || !defaultBranch || !ref) return reply(400, "missing fields");

    // "merge to master only" - ignore feature branches, tags and deletions, so
    // work-in-progress never lands in the index.
    if (ref !== `refs/heads/${defaultBranch}`) {
      log("ignoring push to", ref, "on", repo);
      return reply(202, "not the default branch");
    }
    if (payload.deleted) return reply(202, "ignoring branch deletion");

    // Respond before the sync finishes; GitHub times deliveries out at 10s and
    // a full scrape can take minutes. That also means an unindexed repo still
    // gets a 202 here -- sync.sh does the rejecting, and logs it.
    reply(202, "sync queued");
    triggerSync(repo);
  });
});

server.listen(PORT, "0.0.0.0", () => log("listening on", PORT));
