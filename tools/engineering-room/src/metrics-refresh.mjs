import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { realpathSync, statSync } from "node:fs";
import { dirname, extname, relative, resolve, sep } from "node:path";

const AREAS = ["tests", "code", "hallie", "reviews"];
const PREFIX = "metrics-refresh:";
const REQUEST_HEADER = "Metrics refresh request v1\n";
const SOURCE_EXTENSIONS = new Set([".swift", ".py", ".sh", ".mjs", ".js", ".ts", ".tsx", ".jsx", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm", ".html", ".css"]);

/** This adapter queues existing manager directives. It never executes a runner. */
export class MetricsRefresh {
  constructor({ controlPlane, repoRoot, listFolders = trackedSourceFolders }) {
    this.controlPlane = controlPlane;
    this.repoRoot = repoRoot;
    this.listFolders = listFolders;
  }

  snapshot() {
    const board = this.controlPlane.board();
    return {
      capabilities: {
        execution: "manager-queue",
        machines: [
          { id: "m4", available: true, requiresQuietWindowFor: ["tests", "hallie"] },
          { id: "m5", available: true, requiresQuietWindowFor: [] },
          { id: "m5Ultra", available: false, reason: "Not configured yet." },
        ],
        areas: AREAS,
        folders: this.listFolders(this.repoRoot),
      },
      generatedAt: board.generatedAt,
      requests: board.tasks.filter(isRefreshTask)
        .sort((a, b) => b.createdAt.localeCompare(a.createdAt)).slice(0, 50).map(summarizeTask),
    };
  }

  enqueue(input) {
    const request = validateRequest(input, this.listFolders(this.repoRoot));
    const requestId = input.requestId === undefined ? randomUUID() : input.requestId;
    if (typeof requestId !== "string" || !/^[A-Za-z0-9_-]{8,100}$/.test(requestId)) {
      throw clientError(400, "requestId must contain 8–100 letters, numbers, underscores, or hyphens.");
    }
    const id = `${PREFIX}${requestId}`;
    const existing = this.controlPlane.getTask(id);
    if (existing) {
      if (JSON.stringify(readRequest(existing)) !== JSON.stringify(request)) {
        throw clientError(409, "This requestId already belongs to a different refresh request.");
      }
      // createDirective persists the task before its room message and queue row.
      // A failed first attempt can therefore leave a task with no manager queue
      // entry. Repair that interrupted handoff before acknowledging the retry.
      const task = this.controlPlane.getDirectiveByTask(id) ? existing : this.controlPlane.createDirective({
        taskId: id, title: existing.title, objective: existing.objective,
        manager: request.manager, machine: request.machine, priority: existing.priority,
      }).task;
      return { accepted: true, queued: task.state === "queued", reused: true, task: summarizeTask(task) };
    }
    const title = `Refresh ${request.areas.join(", ")} on ${request.machine}: ${request.folder || "whole repository"}`;
    const result = this.controlPlane.createDirective({
      id, title, objective: workerObjective(request), manager: request.manager,
      machine: request.machine, priority: 50,
    });
    return { accepted: true, queued: true, reused: false, task: summarizeTask(result.task) };
  }
}

export function validateRequest(input, folders) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw clientError(400, "Expected a refresh request object.");
  if (!["m4", "m5"].includes(input.machine)) throw clientError(400, "Choose m4 or m5; m5Ultra is not configured yet.");
  if (!Array.isArray(input.areas) || input.areas.length < 1 || input.areas.length > AREAS.length || input.areas.some(area => !AREAS.includes(area))) {
    throw clientError(400, "Select one or more of tests, code, hallie, and reviews.");
  }
  const areas = AREAS.filter(area => input.areas.includes(area));
  const manager = input.manager ?? "codex";
  if (!["codex", "claude"].includes(manager)) throw clientError(400, "Choose the Codex or Claude manager.");
  if (input.quietWindow !== undefined && typeof input.quietWindow !== "boolean") throw clientError(400, "quietWindow must be a boolean.");
  const quietWindow = input.quietWindow === true;
  if (input.machine === "m4" && areas.some(area => ["tests", "hallie"].includes(area)) && !quietWindow) {
    throw clientError(400, "M4 tests and Hallie evaluation require an explicitly declared quiet window.");
  }
  const rawFolder = boundedText(input.folder ?? "", "folder", 240);
  const folder = rawFolder === "." ? "" : rawFolder;
  if (folder && (!folders.includes(folder) || folder.startsWith("/") || folder.split("/").includes(".."))) {
    throw clientError(400, "Choose a tracked source folder from this repository, or leave it empty for the whole repository.");
  }
  const revision = boundedText(input.revision ?? "working-tree", "revision", 160);
  if (!revision || !/^[A-Za-z0-9][A-Za-z0-9._/~^-]*$/.test(revision) || revision.includes("..")) {
    throw clientError(400, "revision must be working-tree, HEAD, a branch, or a commit identifier.");
  }
  const testScope = input.testScope ?? "all";
  if (!["all", "selected"].includes(testScope)) throw clientError(400, "testScope must be all or selected.");
  const rawSelectors = boundedText(input.testSelectors ?? "", "testSelectors", 2000, { multiline: true });
  const selectors = rawSelectors.split(/[,\n]/).map(value => value.trim()).filter(Boolean);
  if (selectors.length > 40 || selectors.some(value => !/^[A-Za-z0-9_][A-Za-z0-9_.:/-]*$/.test(value) || value.split(/[/:]/).includes(".."))) {
    throw clientError(400, "Use up to 40 comma- or newline-separated test identifiers or test file paths; shell commands are not accepted.");
  }
  if (areas.includes("tests") && testScope === "selected" && !selectors.length) throw clientError(400, "Selected tests require at least one test identifier.");
  if (areas.includes("tests") && testScope === "all" && selectors.length) throw clientError(400, "Choose selected tests to use test identifiers, or clear the identifiers.");
  return {
    machine: input.machine, areas, testScope: areas.includes("tests") ? testScope : "all",
    testSelectors: areas.includes("tests") ? [...new Set(selectors)].join("\n") : "",
    folder, revision, manager, quietWindow,
  };
}

/** The folder menu comes from tracked source, never arbitrary browser paths. */
export function trackedSourceFolders(repoRoot) {
  let files;
  try {
    files = execFileSync("git", ["ls-files", "--cached", "-z"], {
      cwd: repoRoot, encoding: "utf8", timeout: 5000, maxBuffer: 8 * 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    }).split("\0");
  } catch { throw clientError(503, "Tracked source folders are unavailable; retry when the repository is accessible."); }
  const root = realpathSync(repoRoot);
  const folders = new Set();
  for (const file of files) {
    if (!SOURCE_EXTENSIONS.has(extname(file)) || file.split("/").some(part => part.startsWith("."))) continue;
    for (let folder = dirname(file); folder !== "."; folder = dirname(folder)) folders.add(folder);
  }
  return [...folders].filter(folder => {
    try {
      const path = realpathSync(resolve(root, folder));
      const rel = relative(root, path);
      return rel && rel !== ".." && !rel.startsWith(`..${sep}`) && !rel.startsWith(sep) && statSync(path).isDirectory();
    } catch { return false; }
  }).sort();
}

function workerObjective(request) {
  return `${REQUEST_HEADER}${JSON.stringify(request)}\n\nWorker checklist:\n` + [
    "Claim this existing task through team-control, heartbeat progress, and complete it with evidence. This is a queued manager request; the web server has not started tests, evaluation, review, or publication.",
    "Run only on the selected machine. Confirm that machine is reachable and available; do not silently fall back to another Mac. For M4 tests/Hallie, confirm the explicitly declared quiet window is still current before launching app or UI work.",
    "Resolve the requested revision on that machine before execution. Record actual full SHA, branch, dirty state, start/end times, machine, exact commands, test selectors, and folder scope. working-tree means that machine's current checkout including its dirty changes. Never reset, stash, switch, or overwrite an active checkout to satisfy a request; use an isolated checkout for a different committed revision. Report a missing revision or unavailable environment as blocked.",
    "For tests, use the current XCTest/Python/Node runners: all means the full current test scope; selected means the explicit stage/suite/test identifiers. The source folder applies to code health and reviews; it must not silently narrow an all-tests request. Use Release when production parity matters. Do not invoke scripts/nightly_local_tests.sh: its branch synchronization and nightly side effects are outside this daytime request. Never imply that a selected subset ran the full suite. Do not revive the retired TestDriver app.",
    "For code, collect size, complexity, and technical debt together with scripts/collect_metrics.sh, scripts/complexity_metrics.py, and applicable static-analysis/exposure collectors. Measure the whole tree once and filter the presentation to the requested folder. Preserve baselines; do not shrink or rewrite debt baselines just to turn the page green. Record the whole-tree measurement scope and folder presentation scope separately, and do not claim unrelated debt was resolved.",
    "For Hallie, use the established Hallie evaluation/replay runner and report its actual dataset and outcome. Missing app, corpus, models, or credentials are not passing evidence.",
    "For reviews, perform a fresh read-only review of the requested folder (or whole repository), pinned to the resolved revision/dirty snapshot; no PR is required. Report findings with file:line, reproduction, severity, and read/no-findings scope. Record the result through the existing review tracking path.",
    "Publish only supported, sanitized metric streams using the existing publisher. Verify that a newer measurement timestamp, the actual revision/dirty identity, and the correct scope reach the dashboard; return the artifact/evidence link. Never publish a subset, branch/dirty run, or folder review as the whole clean-main/nightly result. If existing streams cannot preserve this scope or publication is unavailable, return the scoped evidence in this task and explicitly report publication blocked; do not claim the public page refreshed.",
    "Commands finishing is not completion: identify each requested area's measured outcome, remaining findings/failures, and verified publication status. If publication is blocked, keep this task blocked with its evidence and reason. Preserve unrequested/stale areas and any full-suite failures. A completed request with failing tests or review findings is not green health; report execution success and measurement findings separately.",
  ].map((line, index) => `${index + 1}. ${line}`).join("\n");
}

function isRefreshTask(task) { return task.id.startsWith(PREFIX) && readRequest(task) !== null; }
function readRequest(task) {
  if (!task.objective?.startsWith(REQUEST_HEADER)) return null;
  try { return JSON.parse(task.objective.slice(REQUEST_HEADER.length).split("\n", 1)[0]); }
  catch { return null; }
}
function summarizeTask(task) {
  return {
    id: task.id, title: task.title, machine: task.machine, manager: task.manager,
    state: task.state, progress: task.progress, blockedOn: task.blockedOn,
    createdAt: task.createdAt, updatedAt: task.updatedAt, request: readRequest(task),
    resultSummary: ["done", "failed"].includes(task.state) ? task.progress : null,
  };
}
function boundedText(value, name, max, { multiline = false } = {}) {
  if (typeof value !== "string" || value.length > max || (multiline ? /[\x00-\x09\x0b-\x1f\x7f]/ : /[\x00-\x1f\x7f]/).test(value)) {
    throw clientError(400, `${name} must be text of at most ${max} characters without control characters.`);
  }
  return value.trim();
}
function clientError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }

/** Only the metrics route needs the page's inline code and public chart/data origins. */
export function metricsDocument(html) {
  const nonce = randomBytes(24).toString("base64");
  const body = html.replace(/<(script|style)(?=[\s>])/g, `<$1 nonce="${nonce}"`);
  const csp = `default-src 'self'; script-src 'self' 'nonce-${nonce}' https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js; style-src 'self' 'nonce-${nonce}'; style-src-attr 'unsafe-inline'; connect-src 'self' https://api.github.com https://raw.githubusercontent.com; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`;
  return { body, csp };
}
