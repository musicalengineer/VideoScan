"use strict";

const $ = id => document.getElementById(id);
const MAX_CARDS = 50;
const MAX_RESULT_CHARACTERS = 32768;
const PENDING_KEY = "videoscan-work-board-pending-v1";
const boardState = { data: null, connected: false, fetching: false, timer: null, sending: false, pending: null };
const stateLabels = { queued: "Queued", working: "Working", running: "Running", blocked: "Blocked", "waiting-on-human": "Needs Rick", "not-reporting": "Not reporting", done: "Reported complete", failed: "Failed", cancelled: "Cancelled", briefed: "Briefed", verdict: "Verdict ready", fixing: "Fixing", closed: "Closed", open: "Decision needed" };
const dateFormat = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" });

function text(value, limit = 4000) { return typeof value === "string" ? value.slice(0, limit) : ""; }
function stamp(value) { const date = value ? new Date(value) : null; return date && Number.isFinite(date.getTime()) ? dateFormat.format(date) : "Time not recorded"; }
function person(value) { return ({ claude: "Claude", codex: "Codex", rick: "Rick" })[value] || text(value, 160) || "Unassigned"; }
function machine(value) { return ({ none: "Headless", m4: "M4", m5: "M5", m1: "M1", m5Ultra: "M5 Ultra" })[value] || "Machine not recorded"; }
function node(tag, className, content) { const element = document.createElement(tag); if (className) element.className = className; if (content !== undefined) element.textContent = content; return element; }
function badge(state, label) { const known = Object.hasOwn(stateLabels, state); return node("span", `badge${known ? ` ${state}` : ""}`, label || stateLabels[state] || "Status unknown"); }
function saved(key) { try { return sessionStorage.getItem(key); } catch { return null; } }
function savePending() { try { if (boardState.pending) sessionStorage.setItem(PENDING_KEY, JSON.stringify(boardState.pending)); else sessionStorage.removeItem(PENDING_KEY); } catch { /* Keep the same retry identity for this tab even if storage is unavailable. */ } }

async function api(path, payload) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  try {
    const response = await fetch(path, { method: payload ? "POST" : "GET", credentials: "same-origin", cache: "no-store", redirect: "error", signal: controller.signal, ...(payload ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) } : {}) });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const error = new Error(response.status === 401 || response.status === 403 ? "Open the local board with its sign-in link, then retry." : text(data?.error, 500) || `Request failed (${response.status}).`);
      error.status = response.status;
      throw error;
    }
    if (!data || typeof data !== "object") throw new Error("The server returned an unreadable response.");
    return data;
  } finally { clearTimeout(timeout); }
}

function taskState(task) {
  // Only the server's evidence-derived state can promote active work.
  // A working row without worker evidence is never presented as reporting.
  if (task.effectiveState) return task.effectiveState;
  return task.state === "working" ? "not-reporting" : task.state || "unknown";
}

function taskCard(task) {
  const effective = taskState(task);
  const card = node("article", "work-card");
  const top = node("div", "card-top");
  top.append(badge(effective), node("span", "card-meta", machine(task.machine)));
  card.append(top, node("h3", "", text(task.title, 500) || "Untitled request"));
  card.append(node("p", "card-meta", `${person(task.manager)} coordinates · ${task.ownerAgentId ? person(task.ownerAgentId) : "No worker assigned"}`));
  const progress = effective === "queued" ? "Waiting for worker acknowledgement." : text(task.progress, 1600) || "No progress reported.";
  card.append(node("p", "card-detail", progress));
  const hasResult = typeof task.result === "string" && task.result.length > 0;
  if (hasResult) card.append(node("p", "card-meta", "Progress preview. Expand the reported outcome for the evidence."));
  else if (typeof task.progress === "string" && task.progress.length > 1600) card.append(node("p", "card-meta", "Progress preview shortened; ask the worker for the complete update."));
  if (effective === "not-reporting") card.append(node("p", "card-blocker", "Worker is not reporting. The last update below may be old."));
  if (task.blockedOn) card.append(node("p", "card-blocker", `Blocked: ${text(task.blockedOn, 1600)}`));
  if (hasResult) {
    const truncated = task.resultTruncated === true || task.result.length > MAX_RESULT_CHARACTERS;
    const outcome = node("details", "reported-outcome");
    outcome.append(node("summary", "", truncated ? "Reported outcome (truncated)" : "Full reported outcome"), node("p", "card-result", text(task.result, MAX_RESULT_CHARACTERS)));
    card.append(outcome);
    if (truncated) card.append(node("p", "card-blocker", "The reported outcome is truncated. Ask Claude for the complete result before assessing it."));
  } else if (task.resultOmitted) {
    card.append(node("p", "card-blocker", "Full outcome omitted from this older record. Ask Claude for the complete result."));
  } else if (["done", "failed"].includes(effective)) {
    card.append(node("p", "card-blocker", "Full outcome not recorded. The progress preview may be incomplete."));
  }
  if (task.objective) {
    const details = node("details");
    details.append(node("summary", "", "Scope and outcome"), node("p", "card-detail", text(task.objective)));
    card.append(details);
  }
  card.append(node("p", "card-time", `Updated ${stamp(task.updatedAt || task.createdAt)}`), node("p", "card-id", text(task.id, 240)));
  return card;
}

function decisionCard(decision) {
  const card = node("article", "work-card");
  card.append(badge("open"), node("h3", "card-detail", text(decision.question) || "Decision requested"), node("p", "card-meta", `Recorded owner: ${person(decision.owner)}`));
  if (decision.taskId) card.append(node("p", "card-id", `Task: ${text(decision.taskId, 240)}`));
  card.append(node("p", "card-time", `Updated ${stamp(decision.updatedAt || decision.createdAt)}`));
  return card;
}

function renderLane(name, entries, empty) {
  const container = $(`${name}-cards`);
  const cards = entries.slice(0, MAX_CARDS).map(entry => entry.kind === "decision" ? decisionCard(entry.value) : taskCard(entry.value));
  container.replaceChildren(...(cards.length ? cards : [node("p", "empty", empty)]));
  $(`${name}-count`).textContent = String(entries.length);
  if (entries.length > MAX_CARDS) container.append(node("p", "muted", `Showing the latest ${MAX_CARDS} of ${entries.length}.`));
}

function renderReviews(reviews) {
  const container = $("review-cards");
  const items = Array.isArray(reviews?.items) ? reviews.items : [];
  const error = text(reviews?.error, 400);
  if (reviews?.status !== "ok") {
    $("review-status").textContent = reviews?.status === "missing" ? "No review-cycle evidence has been recorded yet." : `Review evidence unavailable.${error ? ` ${error}` : ""}`;
  } else {
    $("review-status").textContent = `${reviews.stale ? "Review evidence may be old. " : ""}Last evidence ${stamp(reviews.lastUpdatedAt)} · ${Number.isInteger(reviews.total) ? reviews.total : items.length} recorded reviews${reviews.omitted ? ` · ${reviews.omitted} older reviews omitted` : ""}${error ? ` · ${error}` : ""}`;
  }
  container.classList.toggle("old-data", reviews?.status !== "ok" || !!reviews?.stale);
  const cards = items.slice(0, MAX_CARDS).map(review => {
    const card = node("article", "work-card");
    const rawState = review.effectiveState || review.phase;
    const effective = rawState === "running" && review.processAlive !== true ? "not-reporting" : rawState;
    const top = node("div", "card-top");
    top.append(badge(effective), node("span", "card-meta", "Codex review"));
    card.append(top, node("h3", "", text(review.title, 500) || text(review.id, 240) || "Review"));
    if (review.range) card.append(node("p", "card-meta", `Revision: ${text(review.range, 300)}`));
    card.append(node("p", "card-detail", `Phase: ${stateLabels[review.phase] || text(review.phase, 80) || "Unknown"}`));
    if (effective === "not-reporting") card.append(node("p", "card-blocker", "Review process is not reporting. A recorded running phase does not confirm live work."));
    if (review.stale) card.append(node("p", "card-blocker", "Review evidence may be old."));
    const findings = review.findings;
    if (Number.isInteger(findings) && findings >= 0) card.append(node("p", "card-detail", `Findings: ${findings}`));
    if (findings && typeof findings === "object" && !Array.isArray(findings)) {
      const counts = Object.entries(findings).slice(0, 8).filter(([, value]) => typeof value === "number" && Number.isFinite(value)).map(([key, value]) => `${key}: ${value}`);
      if (counts.length) card.append(node("p", "card-detail", `Findings · ${counts.join(" · ")}`));
    }
    if (typeof review.verdict === "string" && review.verdict) card.append(node("p", "card-detail", `Verdict: ${text(review.verdict, 1600)}`));
    if (review.failure) card.append(node("p", "card-blocker", text(review.failure, 1600)));
    if (review.document) card.append(node("p", "card-id", `Review notes: ${text(review.document, 300)}`));
    card.append(node("p", "card-time", `Phase since ${stamp(review.phaseSince || review.startedAt)}`));
    return card;
  });
  container.replaceChildren(...(cards.length ? cards : [node("p", "empty", "Reviews appear here when Claude starts the existing Codex review runner.")]));
}

function renderBoard(data) {
  const tasks = [...data.controlPlane.tasks].sort((a, b) => (Date.parse(b.updatedAt || b.createdAt) || 0) - (Date.parse(a.updatedAt || a.createdAt) || 0));
  const lanes = { needs: [], progress: [], queued: [], finished: [] };
  for (const decision of data.controlPlane.decisions) if (!decision.status || decision.status === "open") lanes.needs.push({ kind: "decision", value: decision });
  for (const task of tasks) {
    const state = taskState(task);
    const lane = state === "waiting-on-human" ? "needs" : state === "queued" ? "queued" : ["done", "failed", "cancelled"].includes(state) ? "finished" : "progress";
    lanes[lane].push({ kind: "task", value: task });
  }
  renderLane("needs", lanes.needs, "No decisions or requests for Rick recorded.");
  renderLane("progress", lanes.progress, "No work in progress recorded.");
  renderLane("queued", lanes.queued, "No requests waiting.");
  renderLane("finished", lanes.finished, "No recent outcomes recorded.");
  renderReviews(data.reviews);
  const schedule = data.schedule;
  const activity = typeof schedule?.currentActivity === "string" ? text(schedule.currentActivity, 200) : text(schedule?.currentActivity?.label, 200);
  $("schedule").textContent = `America/New_York${activity ? ` · Schedule: ${activity}` : ""} · M4 is active unless Rick declares a current quiet window.`;
  const warning = data.controlPlane.summary?.omittedHistorical ? "Historical Room records are omitted. This board shows work reported by the current workflow." : "";
  $("board-warning").textContent = warning;
  $("board-warning").hidden = !warning;
}

async function refreshBoard() {
  if (boardState.fetching) return;
  clearTimeout(boardState.timer);
  boardState.fetching = true;
  $("refresh-board").disabled = true;
  try {
    const data = await api("/api/work-board");
    if (!Array.isArray(data.controlPlane?.tasks) || !Array.isArray(data.controlPlane?.decisions)) throw new Error("Unsupported board response.");
    renderBoard(data);
    boardState.data = data;
    boardState.connected = true;
    $("connection").textContent = `Connected · Updated ${stamp(data.generatedAt)} · Recorded worker evidence`;
    $("connection").classList.remove("disconnected");
    $("lanes").classList.remove("old-data");
  } catch (error) {
    boardState.connected = false;
    $("connection").textContent = `Not connected · ${boardState.data ? `Showing old data from ${stamp(boardState.data.generatedAt)}. ` : ""}${error.name === "AbortError" ? "Connection timed out." : error.message}`;
    $("connection").classList.add("disconnected");
    $("lanes").classList.add("old-data");
    $("review-cards").classList.add("old-data");
  } finally {
    boardState.fetching = false;
    $("refresh-board").disabled = false;
    boardState.timer = setTimeout(refreshBoard, 10000);
  }
}

function updateRequestControls() {
  $("request-fields").disabled = !!boardState.pending || boardState.sending;
  $("request-submit").disabled = boardState.sending;
  $("request-submit").textContent = boardState.sending ? "Queuing…" : boardState.pending ? "Retry same request" : "Queue request";
}

async function submitRequest(event) {
  event.preventDefault();
  if (boardState.sending) return;
  if (!boardState.pending) {
    const title = $("request-title").value.trim();
    const objective = $("request-objective").value.trim();
    const route = $("request-machine").value;
    const manager = $("request-manager").value;
    if (!title || !objective || !["none", "m4", "m5", "m1"].includes(route) || !["claude", "codex"].includes(manager)) { $("request-message").textContent = "Enter a title, scope, manager, and explicit machine route."; return; }
    boardState.pending = { requestId: crypto.randomUUID(), title, objective, machine: route, manager };
    savePending();
  }
  boardState.sending = true;
  updateRequestControls();
  try {
    const data = await api("/api/work-board/requests", boardState.pending);
    if (!data.task?.id || !data.directive) throw new Error("Request receipt was incomplete.");
    const submitted = boardState.pending;
    boardState.pending = null;
    savePending();
    $("request-form").reset();
    $("request-message").textContent = `Request recorded for ${person(submitted.manager)}: ${text(data.task.id, 240)}. ${["done", "failed", "cancelled"].includes(data.task.state) ? "It already has an outcome; check its card." : data.task.state === "working" ? "A worker has acknowledged it; check its card." : "Waiting for worker acknowledgement."}`;
    await refreshBoard();
  } catch (error) {
    // Retain the exact payload after any uncertain response. A retry reconciles
    // against the same server identity, including after reload of this tab.
    if (error.status === 400) {
      boardState.pending = null;
      savePending();
      $("request-message").textContent = `Request was not accepted. ${error.message} Your entries are preserved for correction.`;
    } else {
      const retry = boardState.pending?.requestId;
      $("request-message").textContent = `Receipt not confirmed. ${error.name === "AbortError" ? "Connection timed out." : error.message} Your request is preserved. Retry the same request to check its receipt. ID: ${retry}`;
    }
  } finally { boardState.sending = false; updateRequestControls(); }
}

function restorePending() {
  try {
    const pending = JSON.parse(saved(PENDING_KEY) || "null");
    if (!pending || typeof pending.requestId !== "string" || typeof pending.title !== "string" || typeof pending.objective !== "string" || !["none", "m4", "m5", "m1"].includes(pending.machine) || !["claude", "codex"].includes(pending.manager)) return;
    boardState.pending = pending;
    $("request-title").value = pending.title;
    $("request-objective").value = pending.objective;
    $("request-manager").value = pending.manager;
    $("request-machine").value = pending.machine;
    $("request-message").textContent = `A previous request has no confirmed receipt. Retry the same request to check it safely. ID: ${pending.requestId}`;
  } catch { /* Ignore malformed saved UI state. */ }
  updateRequestControls();
}

function setTheme(theme) { document.documentElement.dataset.theme = theme === "light" ? "light" : "dark"; $("theme-toggle").textContent = `Theme: ${document.documentElement.dataset.theme}`; }
try { setTheme(localStorage.getItem("vs-theme") || "dark"); } catch { setTheme("dark"); }
$("theme-toggle").addEventListener("click", () => { setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark"); try { localStorage.setItem("vs-theme", document.documentElement.dataset.theme); } catch { /* Theme still works for this tab. */ } });
$("refresh-board").addEventListener("click", refreshBoard);
$("request-form").addEventListener("submit", submitRequest);
restorePending();
refreshBoard();
