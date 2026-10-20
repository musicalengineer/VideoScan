import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";

const MAX_REVIEW_BYTES = 2 * 1024 * 1024;
const MAX_SCHEDULE_BYTES = 64 * 1024;
const REVIEW_LIMIT = 20;
const RESULT_LIMIT = 50;
const RESULT_CHARACTER_LIMIT = 32768;
const REVIEW_PHASES = new Set(["briefed", "running", "verdict", "fixing", "closed", "failed"]);
const TERMINAL_STATES = new Set(["done", "failed"]);

// This view reads the review runner's existing atomic JSON snapshot. It never
// registers a synthetic worker or turns a historical review into a queue task.
export class WorkBoard {
  constructor({ controlPlane, repoRoot, mode = "board", clock = () => new Date(), reviewCyclesPath = process.env.VIDEOSCAN_REVIEW_CYCLES, schedulePath, processAlive = pidAlive }) {
    this.controlPlane = controlPlane;
    this.repoRoot = resolve(repoRoot);
    this.mode = mode;
    this.clock = clock;
    this.reviewCyclesPath = reviewCyclesPath
      ? reviewCyclesPath.replace(/^~(?=\/)/, homedir())
      : join(homedir(), "Library", "Application Support", "VideoScan", "review-cycles", "review-cycles.json");
    this.processAlive = processAlive;
    this.schedulePath = schedulePath ?? join(this.repoRoot, "docs", "team-operations", "rick-availability.local.md");
  }

  async snapshot() {
    const now = this.clock();
    const board = this.controlPlane.board();
    const agents = board.agents.filter(item => !retiredSource(item.source)).map(agent => {
      const leaseActive = Boolean(dateValue(agent.leaseExpiresAt) > now.getTime() && dateValue(agent.lastHeartbeatAt) !== null);
      return {
        id: agent.id, manager: agent.manager, displayName: agent.displayName, state: agent.state,
        effectiveState: leaseActive || TERMINAL_STATES.has(agent.state) ? agent.effectiveState : "not-reporting",
        source: agent.source, taskId: agent.taskId, progress: agent.progress, blockedOn: agent.blockedOn,
        lastHeartbeatAt: agent.lastHeartbeatAt, leaseExpiresAt: agent.leaseExpiresAt, leaseActive,
        updatedAt: agent.updatedAt,
      };
    });
    const agentsById = new Map(agents.map(agent => [agent.id, agent]));
    // Match the UI's recent-outcomes limit. Each indexed lookup returns at most
    // one bounded string; historical results never expand every board refresh.
    const recentCompletedIds = new Set(board.tasks.filter(task => !retiredSource(task.source) && TERMINAL_STATES.has(task.state))
      .sort((a, b) => (dateValue(b.updatedAt) ?? 0) - (dateValue(a.updatedAt) ?? 0))
      .slice(0, RESULT_LIMIT).map(task => task.id));
    const completionResult = this.controlPlane.db.prepare(`
      SELECT substr(CASE WHEN json_valid(payload_json) THEN
        CASE WHEN json_type(payload_json,'$.result')='text' THEN json_extract(payload_json,'$.result') END
      END,1,?) AS result FROM cp_events
      WHERE task_id=? AND kind IN ('task.completed','task.failed')
      ORDER BY ts DESC,id DESC LIMIT 1
    `);
    const tasks = board.tasks.filter(item => !retiredSource(item.source)).map(task => {
      const owner = agentsById.get(task.ownerAgentId);
      const reporting = Boolean(owner?.leaseActive && owner.taskId === task.id);
      const result = recentCompletedIds.has(task.id) ? completionResult.get(RESULT_CHARACTER_LIMIT + 1, task.id)?.result : null;
      return {
        id: task.id, title: task.title, objective: task.objective, manager: task.manager,
        machine: task.machine, ownerAgentId: task.ownerAgentId, state: task.state,
        effectiveState: task.state === "working" && !reporting ? "not-reporting" : task.state,
        priority: task.priority, progress: task.progress, blockedOn: task.blockedOn, source: task.source,
        createdAt: task.createdAt, updatedAt: task.updatedAt,
        result: typeof result === "string" ? result.slice(0, RESULT_CHARACTER_LIMIT) : null,
        resultTruncated: typeof result === "string" && result.length > RESULT_CHARACTER_LIMIT,
        resultOmitted: TERMINAL_STATES.has(task.state) && !recentCompletedIds.has(task.id),
      };
    });
    const decisions = board.decisions.filter(item => !retiredSource(item.source));
    const reviews = await readReviewCycles({ path: this.reviewCyclesPath, repoRoot: this.repoRoot, now, processAlive: this.processAlive });
    const schedule = await readSchedule({ path: this.schedulePath, now });
    return {
      generatedAt: now.toISOString(), mode: this.mode,
      controlPlane: {
        generatedAt: board.generatedAt, agents, tasks, decisions,
        summary: {
          reportingAgents: agents.filter(agent => agent.leaseActive).length,
          queuedTasks: tasks.filter(task => task.effectiveState === "queued").length,
          workingTasks: tasks.filter(task => task.effectiveState === "working").length,
          openDecisions: decisions.length,
          omittedHistorical: board.agents.length + board.tasks.length + board.decisions.length - agents.length - tasks.length - decisions.length,
          lastUpdatedAt: newestDate([...agents, ...tasks, ...decisions].map(item => item.updatedAt)),
        },
      },
      reviews, schedule,
    };
  }

  // A browser can retry an uncertain POST without creating another directive or
  // resetting a task a worker has already claimed. Reuse the existing tables.
  enqueue(input) {
    const requestId = cleanText(input?.requestId, 36, "requestId");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)) throw clientError(400, "requestId must be a UUID.");
    const title = cleanText(input.title, 500, "title");
    const objective = cleanText(input.objective, 8000, "objective");
    const manager = input.manager ?? "claude";
    const machine = input.machine;
    if (!["claude", "codex"].includes(manager)) throw clientError(400, "manager must be claude or codex.");
    if (!["none", "m4", "m5", "m1"].includes(machine)) throw clientError(400, "machine must be none, m4, m5, or m1. M5 Ultra is not available yet.");
    const id = `work-board:${requestId.toLowerCase()}`;
    const existing = this.controlPlane.getTask(id);
    if (existing) {
      if (existing.title !== title || existing.objective !== objective || existing.manager !== manager || existing.machine !== machine) {
        throw clientError(409, "This requestId already identifies a different request. Retry the original request unchanged.");
      }
      const directive = this.controlPlane.getDirectiveByTask(id);
      if (!directive) throw clientError(409, "This request is missing its directive; ask the manager to reconcile it before retrying.");
      return { task: existing, directive, reused: true };
    }
    this.controlPlane.db.exec("BEGIN IMMEDIATE");
    try {
      const { task, directive } = this.controlPlane.createDirective({ id, title, objective, manager, machine, actor: "rick" });
      this.controlPlane.db.exec("COMMIT");
      return { task, directive, reused: false };
    } catch (error) {
      this.controlPlane.db.exec("ROLLBACK");
      throw error;
    }
  }
}

export async function readReviewCycles({ path, repoRoot, now = new Date(), processAlive = pidAlive }) {
  const result = { status: "ok", source: "codex-review-cycles", observedAt: now.toISOString(), lastUpdatedAt: null, error: null, stale: false, total: 0, omitted: 0, items: [] };
  let file;
  try {
    // Nonblocking open plus isFile also avoids hanging on an accidentally
    // configured pipe/device. Reading MAX+1 bytes caps allocation and file growth.
    file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
    const stat = await file.stat();
    if (!stat.isFile()) throw new Error("not-file");
    if (stat.size > MAX_REVIEW_BYTES) throw new Error("too-large");
    result.lastUpdatedAt = stat.mtime.toISOString();
    result.stale = now.getTime() - stat.mtimeMs > 24 * 60 * 60 * 1000;
    const buffer = Buffer.alloc(MAX_REVIEW_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await file.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > MAX_REVIEW_BYTES) throw new Error("too-large");
    const parsed = JSON.parse(buffer.subarray(0, length).toString("utf8"));
    // The runner writes a list; the status-line reader also accepts {cycles:[]}.
    const cycles = Array.isArray(parsed) ? parsed : parsed?.cycles;
    if (!Array.isArray(cycles)) throw new Error("invalid-shape");
    const usable = cycles.filter(cycle => cycle && typeof cycle === "object" && !Array.isArray(cycle));
    const invalid = cycles.length - usable.length;
    result.total = usable.length;
    if (invalid) result.error = `${invalid} malformed review record${invalid === 1 ? " was" : "s were"} ignored.`;
    result.items = usable.sort((left, right) => {
      const leftId = positiveInteger(left.id) ?? 0;
      const rightId = positiveInteger(right.id) ?? 0;
      return rightId - leftId || (dateValue(right.startedAt) ?? 0) - (dateValue(left.startedAt) ?? 0);
    }).slice(0, REVIEW_LIMIT).map(cycle => reviewItem(cycle, { now, repoRoot, processAlive }));
    result.omitted = Math.max(0, usable.length - result.items.length);
  } catch (error) {
    result.status = error.code === "ENOENT" ? "missing" : "error";
    result.error = error.code === "ENOENT" ? "No review-cycle state has been written yet."
      : error.message === "too-large" ? "Review-cycle state exceeds the 2 MiB read limit."
        : error.message === "not-file" ? "Review-cycle state is not a regular file."
          : error instanceof SyntaxError || error.message === "invalid-shape" ? "Review-cycle state is malformed; no review status is available."
            : "Review-cycle state could not be read.";
  } finally {
    await file?.close().catch(() => {});
  }
  return result;
}

function reviewItem(cycle, { now, repoRoot, processAlive }) {
  const phase = REVIEW_PHASES.has(cycle.phase) ? cycle.phase : "unknown";
  const phaseSince = isoDate(cycle.phaseSince);
  const ageSeconds = phaseSince ? Math.max(0, Math.floor((now.getTime() - Date.parse(phaseSince)) / 1000)) : null;
  const pid = positiveInteger(cycle.pid);
  let alive = null;
  if (phase === "running" && pid) { try { alive = Boolean(processAlive(pid)); } catch { alive = false; } }
  const stale = phase !== "closed" && (ageSeconds === null || ageSeconds >= (phase === "fixing" ? 7200 : 1800));
  const effectiveState = phase === "running" && !alive ? "not-reporting" : phase;
  const labels = { briefed: "Brief ready", running: "Review process running", verdict: "Verdict ready", fixing: "Fixes requested", closed: "Closed", failed: "Failed", unknown: "Unknown phase", "not-reporting": pid ? "Review process is no longer running" : "Running state has no process evidence" };
  return {
    id: positiveInteger(cycle.id), title: boundedText(cycle.title, 500) || "Untitled review",
    range: boundedText(cycle.range, 500), phase, effectiveState, statusLabel: labels[effectiveState],
    phaseSince, startedAt: isoDate(cycle.startedAt), ageSeconds, stale, processAlive: alive,
    findings: nonnegativeInteger(cycle.findings), tokens: nonnegativeInteger(cycle.tokens),
    verdict: boundedText(cycle.verdict, 2000), failure: boundedText(cycle.failure, 2000),
    document: documentLabel(cycle.doc, repoRoot),
  };
}

// Personal hours remain in the ignored local document, not in tracked code.
export async function readSchedule({ path, now = new Date() }) {
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_SCHEDULE_BYTES) throw new Error("invalid-file");
    const buffer = Buffer.alloc(MAX_SCHEDULE_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await file.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > MAX_SCHEDULE_BYTES) throw new Error("invalid-file");
    return { ...scheduleAt(now, buffer.subarray(0, length).toString("utf8")), lastUpdatedAt: stat.mtime.toISOString() };
  } catch (error) {
    return {
      ...scheduleAt(now), status: error.code === "ENOENT" ? "missing" : "error",
      error: error.code === "ENOENT" ? "No local working schedule is available." : "The local working schedule could not be read safely.",
    };
  } finally {
    await file?.close().catch(() => {});
  }
}

export function scheduleAt(now, markdown = "") {
  const text = typeof markdown === "string" && Buffer.byteLength(markdown) <= MAX_SCHEDULE_BYTES ? markdown : "";
  let timeZone = text.match(/^\s*Timezone:\s*([A-Za-z0-9_+\-/]+)\s*$/m)?.[1] ?? "America/New_York";
  try { new Intl.DateTimeFormat("en-GB", { timeZone }); } catch { timeZone = "America/New_York"; }
  const blocks = [];
  let inTypicalDay = false;
  for (const line of text.split(/\r?\n/)) {
    if (/^\s*##\s+Typical day\s*$/i.test(line)) { inTypicalDay = true; continue; }
    if (/^\s*##\s+/.test(line)) { inTypicalDay = false; continue; }
    if (!inTypicalDay || blocks.length >= 96) continue;
    const match = line.match(/^\s*[-*]\s+(\d{2}:\d{2})\s*[-–—]\s*(\d{2}:\d{2})\s*[-–—]\s*(.+)$/);
    if (!match || !validClockTime(match[1]) || !(validClockTime(match[2]) || match[2] === "24:00")) continue;
    const [, start, rawEnd, label] = match;
    const end = rawEnd === "00:00" ? "24:00" : rawEnd;
    if (start === end || !label.trim()) continue;
    blocks.push({ start, end, label: label.trim().slice(0, 500) });
  }
  const localTime = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(now);
  return {
    timeZone, localTime,
    currentActivity: blocks.find(block => block.start < block.end ? localTime >= block.start && localTime < block.end : localTime >= block.start || localTime < block.end)?.label
      ?? (blocks.length ? "No typical activity recorded for this time" : "Typical schedule unavailable; presence unknown"),
    blocks, presence: "unknown", status: blocks.length ? "ok" : "unavailable",
    error: blocks.length ? null : "No usable time blocks were found in the local working schedule.", lastUpdatedAt: null,
    machinePolicy: "This is Rick’s typical schedule, not live presence. M4 remains interactive until Rick explicitly declares a quiet window. Prefer M5 or M1 for UI tests and long evaluations.",
  };
}

function validClockTime(value) { return /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value); }

function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch { return false; } }
function retiredSource(source) { return ["reconstruction-seed", "agent-status-jsonl"].includes(source) || String(source ?? "").startsWith("docs/team-channel/"); }
function dateValue(value) { return typeof value === "string" && value.trim() && Number.isFinite(Date.parse(value)) ? Date.parse(value) : null; }
function isoDate(value) { const date = dateValue(value); return date === null ? null : new Date(date).toISOString(); }
function newestDate(values) { const latest = values.reduce((best, value) => Math.max(best, dateValue(value) ?? -Infinity), -Infinity); return Number.isFinite(latest) ? new Date(latest).toISOString() : null; }
function positiveInteger(value) { return Number.isSafeInteger(value) && value > 0 ? value : null; }
function nonnegativeInteger(value) { return Number.isSafeInteger(value) && value >= 0 ? value : null; }
function boundedText(value, limit) { return typeof value === "string" ? value.slice(0, limit) : null; }
function cleanText(value, limit, label) { if (typeof value !== "string" || !value.trim() || value.trim().length > limit) throw clientError(400, `${label} must be 1–${limit} characters.`); return value.trim(); }
function clientError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }
function documentLabel(value, repoRoot) {
  if (typeof value !== "string" || !value.trim()) return null;
  const path = value.trim();
  const normalized = relative(resolve(repoRoot), isAbsolute(path) ? path : resolve(repoRoot, path));
  // Display only. Never hand these paths to staticFile or make local file links.
  return (!normalized.startsWith("../") && normalized !== ".." && !isAbsolute(normalized) ? normalized : basename(path)).slice(0, 1000);
}
