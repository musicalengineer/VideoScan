import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { readOnDemandComplexity } from "../src/on-demand-complexity.mjs";

const toolSource = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MEASURED_AT = "2026-10-18T12:34:56Z";
const NOW = new Date("2026-10-20T23:00:00Z");
const SHA = "0123456789abcdef0123456789abcdef01234567";

function artifact(overrides = {}) {
  return {
    schemaVersion: 1, scope: "VideoScan/VideoScan/Catalog", folder: "Catalog", machine: "m5",
    ts: MEASURED_AT, sha: SHA, sourceRef: "refs/heads/main", sourceDirty: false,
    source: "manual", branch: "main", sourceVerified: true, lizardVersion: "1.22.1",
    measurementScope: "whole-repository", presentationScope: "VideoScan/VideoScan/Catalog",
    measuredRoots: ["VideoScan/VideoScan", "VideoScan/VideoScanCore/Sources", "swift_cli"],
    measuredLanguages: ["Swift"], collectorRunKind: "nightly (collector default; invocation was manual)",
    metrics: { lines: 4321, files: 42, functions: 123, max_ccn: 31, ccn_over_15: 4,
      ccn_over_30: 1, files_over_1000: 2, mean_ccn: 3.1 },
    folderMetrics: { files: 42, functions: 123, ccn_over_15: 4, ccn_over_30: 1,
      nloc_over_80: 3, offenders: 6, files_over_800: 2, mean_ccn: 3.1 },
    ccn15Excess: 25,
    topFunctions: [{ file: "VideoScan/VideoScan/Catalog/Fixture.swift", function: "Fixture.inspect",
      line: 42, ccn: 31, nloc: 100 }],
    ...overrides,
  };
}

function fixture() {
  const toolRoot = mkdtempSync(join(tmpdir(), "videoscan-on-demand-ccn-"));
  mkdirSync(join(toolRoot, "var"));
  const path = join(toolRoot, "var", "on-demand-complexity-latest.json");
  return { toolRoot, path,
    write(value) { writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value)); },
    read() { return readOnDemandComplexity({ toolRoot, now: NOW }); } };
}

test("on-demand result preserves measurement identity and whole-repository versus folder scope", async () => {
  const rig = fixture();
  rig.write(artifact());
  const before = readFileSync(rig.path, "utf8");
  const result = await rig.read();
  assert.equal(result.status, "ok");
  assert.equal(result.observedAt, NOW.toISOString());
  assert.equal(result.result.ts, MEASURED_AT, "opening the page must not refresh the measurement timestamp");
  assert.equal(result.result.sha, SHA, "the complete measured revision is evidence");
  assert.equal(result.result.sourceDirty, false);
  assert.equal(result.result.sourceRef, "refs/heads/main");
  assert.equal(result.result.measurementScope, "whole-repository");
  assert.equal(result.result.presentationScope, "VideoScan/VideoScan/Catalog");
  assert.equal(result.result.metrics.max_ccn, 31);
  assert.equal(result.result.topFunctions[0].line, 42);
  assert.equal(result.stale, true, "old measurement remains stale even when read now");
  assert.equal(readFileSync(rig.path, "utf8"), before, "reading must not rewrite collector evidence");
});

test("missing, malformed, non-regular and oversized artifacts fail without leaking private contents", async () => {
  const missing = fixture();
  const absent = await missing.read();
  assert.equal(absent.status, "missing");
  assert.equal(absent.result, null);
  for (const content of ["{PRIVATE-TOKEN", "null", "[]", "42", " ".repeat(128 * 1024 + 1)]) {
    const rig = fixture();
    rig.write(content);
    const result = await rig.read();
    assert.equal(result.status, "error");
    assert.equal(result.result, null);
    assert.equal(JSON.stringify(result).includes("PRIVATE-TOKEN"), false);
    assert.equal(JSON.stringify(result).includes(rig.toolRoot), false);
  }
  const directory = fixture();
  mkdirSync(directory.path);
  assert.equal((await directory.read()).status, "error");
});

test("a FIFO at the fixed artifact path is rejected promptly without a writer", () => {
  const rig = fixture();
  execFileSync("/usr/bin/mkfifo", [rig.path]);
  // A separate process is essential: a regression to blocking open must not
  // leave the entire Node test runner waiting indefinitely for a FIFO writer.
  const script = `import { readOnDemandComplexity } from ${JSON.stringify(new URL("../src/on-demand-complexity.mjs", import.meta.url).href)};
    console.log(JSON.stringify(await readOnDemandComplexity({toolRoot: ${JSON.stringify(rig.toolRoot)}})));`;
  const output = execFileSync(process.execPath, ["--input-type=module", "-e", script], { timeout: 2000, encoding: "utf8" });
  assert.equal(JSON.parse(output).status, "error");
});

test("the fixed artifact path cannot be redirected through a symlink", async () => {
  const rig = fixture();
  const outside = join(rig.toolRoot, "private-elsewhere.json");
  writeFileSync(outside, JSON.stringify(artifact()));
  symlinkSync(outside, rig.path);
  const result = await rig.read();
  assert.equal(result.status, "error");
  assert.equal(result.result, null);
  assert.equal(JSON.stringify(result).includes(outside), false);
});

test("invalid revision, timestamp, scope and numeric evidence are rejected rather than coerced", async t => {
  const malformed = {
    schema: { schemaVersion: 2 }, machine: { machine: "m5Ultra" },
    shortSHA: { sha: "abcdef1" }, timestamp: { ts: "not-a-timestamp" },
    scope: { scope: "../../private" }, absoluteScope: { scope: "/Users/private/Catalog" },
    negativeCount: { metrics: { ...artifact().metrics, files: -1 } },
    stringCount: { metrics: { ...artifact().metrics, functions: "123" } },
    fractionalCount: { metrics: { ...artifact().metrics, files: 1.5 } },
    missingCount: { metrics: { ...artifact().metrics, max_ccn: undefined } },
    dirtyFlag: { sourceDirty: "false" },
  };
  for (const [name, value] of Object.entries(malformed)) {
    await t.test(name, async () => {
      const rig = fixture();
      rig.write(artifact(value));
      const result = await rig.read();
      assert.equal(result.status, "error");
      assert.equal(result.result, null);
    });
  }
});

test("artifact output is whitelisted and function evidence is bounded", async () => {
  const rig = fixture();
  rig.write(artifact({ privateNotes: "PRIVATE-TOKEN", environment: { home: "/Users/private" },
    metrics: { ...artifact().metrics, rawCommand: "PRIVATE-COMMAND" },
    topFunctions: Array.from({ length: 100 }, (_, index) => ({ ...artifact().topFunctions[0], line: index + 1, secret: "PRIVATE-FUNCTION" })) }));
  const result = await rig.read();
  assert.equal(JSON.stringify(result).includes("PRIVATE-"), false);
  if (result.status === "ok") {
    assert.ok(result.result.topFunctions.length <= 20);
    assert.equal(result.result.metrics.max_ccn, 31);
  } else {
    assert.equal(result.status, "error");
    assert.equal(result.result, null);
  }
  // The ordinary small artifact must be accepted while still stripping extras.
  rig.write(artifact({ privateNotes: "PRIVATE-TOKEN", metrics: { ...artifact().metrics, rawCommand: "PRIVATE-COMMAND" } }));
  const ordinary = await rig.read();
  assert.equal(ordinary.status, "ok");
  assert.equal(JSON.stringify(ordinary).includes("PRIVATE-"), false);
});

test("complexity result endpoint requires authentication and reads only its fixed local artifact", async t => {
  const runtime = mkdtempSync(join(tmpdir(), "videoscan-on-demand-server-"));
  const isolatedTool = join(runtime, "tools", "engineering-room");
  cpSync(join(toolSource, "src"), join(isolatedTool, "src"), { recursive: true });
  mkdirSync(join(isolatedTool, "var"), { recursive: true });
  const resultPath = join(isolatedTool, "var", "on-demand-complexity-latest.json");
  writeFileSync(resultPath, JSON.stringify(artifact()));
  const poison = join(runtime, "poison.json");
  writeFileSync(poison, JSON.stringify(artifact({ sha: "f".repeat(40) })));
  const port = 54000 + Math.floor(Math.random() * 6000);
  const token = "synthetic-on-demand-results-token";
  const child = spawn(process.execPath, [join(isolatedTool, "src", "server.mjs")], {
    cwd: isolatedTool, stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, ENGINEERING_ROOM_MODE: "board", ENGINEERING_ROOM_LAN: "0",
      ENGINEERING_ROOM_PORT: String(port), ENGINEERING_ROOM_TOKEN: token,
      ENGINEERING_ROOM_DB: join(runtime, "board.sqlite3"), VIDEOSCAN_REVIEW_CYCLES: join(runtime, "missing-reviews.json") },
  });
  t.after(() => child.kill("SIGTERM"));
  await waitForReady(child);
  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(`${base}/api/metrics-refresh/results`)).status, 401);
  const login = await fetch(`${base}/board?token=${token}`, { redirect: "manual" });
  assert.equal(login.status, 302);
  const headers = { Cookie: login.headers.get("set-cookie").split(";")[0] };
  const response = await fetch(`${base}/api/metrics-refresh/results?path=${encodeURIComponent(poison)}`, { headers });
  assert.equal(response.status, 200);
  assert.match(response.headers.get("cache-control"), /no-store/);
  const result = await response.json();
  assert.equal(result.status, "ok");
  assert.equal(result.result.sha, SHA, "request parameters cannot select another file");
  assert.equal(result.result.ts, MEASURED_AT);
  assert.equal((await fetch(`${base}/api/metrics-refresh/results`, { headers: { ...headers, Origin: "https://evil.example" } })).status, 403);
});

function waitForReady(child) {
  return new Promise((resolveReady, reject) => {
    const lines = createInterface({ input: child.stdout });
    let stderr = "";
    child.stderr.on("data", chunk => { stderr += chunk; });
    const timeout = setTimeout(() => reject(new Error(`Timed out starting isolated server: ${stderr}`)), 5000);
    child.once("exit", code => { clearTimeout(timeout); reject(new Error(`Isolated server exited ${code}: ${stderr}`)); });
    lines.on("line", line => { if (line.includes("is ready:")) { clearTimeout(timeout); resolveReady(); } });
  });
}
