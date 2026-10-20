import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(join(root, "public", "board.html"), "utf8");
const source = readFileSync(join(root, "public", "board.js"), "utf8");
const PENDING_KEY = "videoscan-work-board-pending-v1";
const snapshot = () => ({ generatedAt: "2026-10-20T17:00:00Z", controlPlane: { tasks: [], decisions: [], summary: {} },
  reviews: { status: "ok", items: [], total: 0 }, schedule: { currentActivity: "Development on M4" } });
const response = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, async json() { return body; } });
const submitEvent = { preventDefault() {} };

class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase(); this.children = []; this.value = ""; this.dataset = {}; this.disabled = false;
    this._text = ""; this.className = ""; this.handlers = new Map();
    const classes = new Set();
    this.classList = { add: name => classes.add(name), remove: name => classes.delete(name), contains: name => classes.has(name),
      toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name) };
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(""); }
  set innerHTML(_value) { throw new Error("Board must not interpret private evidence as HTML"); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this._text = ""; this.children = children; }
  addEventListener(type, handler) { this.handlers.set(type, handler); }
}

function storage(values = new Map()) {
  return { values, getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key) };
}

async function harness({ session = storage(), firstResponse = snapshot() } = {}) {
  const elements = new Map([...html.matchAll(/\bid="([^"]+)"/g)].map(match => [match[1], new Element()]));
  const created = [];
  elements.get("request-manager").value = "claude";
  elements.get("request-form").reset = () => { for (const id of ["request-title", "request-objective", "request-machine"]) elements.get(id).value = ""; elements.get("request-manager").value = "claude"; };
  const rig = { elements, created, calls: [], handler: () => response(firstResponse), session };
  let uuid = 1;
  const timers = new Map();
  let timerID = 0;
  const context = vm.createContext({ document: { getElementById: id => { assert.ok(elements.has(id), `Unknown DOM id: ${id}`); return elements.get(id); },
    createElement: tag => { const element = new Element(tag); created.push(element); return element; }, documentElement: new Element("html") },
    sessionStorage: session, localStorage: storage(), crypto: { randomUUID: () => `637766a0-841d-4e04-a5ee-${String(uuid++).padStart(12, "0")}` },
    fetch: async (path, options) => { rig.calls.push({ path, options }); return rig.handler(path, options); },
    AbortController, Intl, setTimeout: (fn, ms) => { const id = ++timerID; timers.set(id, { fn, ms }); return id; }, clearTimeout: id => timers.delete(id) });
  vm.runInContext(source, context, { filename: "board.js" });
  rig.context = context;
  rig.state = () => vm.runInContext("boardState", context);
  rig.el = id => elements.get(id);
  rig.typeRequest = () => { rig.el("request-title").value = "Review <private> folder"; rig.el("request-objective").value = "Read branch and report findings"; rig.el("request-machine").value = "none"; rig.el("request-manager").value = "claude"; };
  for (let i = 0; rig.state().fetching && i < 20; i += 1) await new Promise(resolve => setImmediate(resolve));
  assert.equal(rig.state().fetching, false, "initial board fetch must settle");
  return rig;
}

test("refresh outage preserves typed request and old cards while clearly marking stale evidence", async () => {
  const data = snapshot();
  data.controlPlane.tasks.push({ id: "private-task", title: "Existing evidence", effectiveState: "queued", machine: "m5" });
  const rig = await harness({ firstResponse: data });
  rig.typeRequest();
  const before = rig.el("queued-cards").textContent;
  rig.handler = () => { throw new Error("Network unavailable"); };
  await rig.context.refreshBoard();
  assert.equal(rig.el("request-title").value, "Review <private> folder");
  assert.equal(rig.el("request-objective").value, "Read branch and report findings");
  assert.equal(rig.el("request-machine").value, "none");
  assert.equal(rig.el("queued-cards").textContent, before);
  assert.match(rig.el("connection").textContent, /Not connected.*Showing old data/);
  assert.equal(rig.el("lanes").classList.contains("old-data"), true);
  assert.equal(rig.el("review-cards").classList.contains("old-data"), true);
});

test("uncertain submission and reload preserve exact payload and idempotency identity", async () => {
  const rig = await harness();
  rig.typeRequest();
  rig.handler = () => { throw new Error("Response lost after commit"); };
  await rig.context.submitRequest(submitEvent);
  const first = rig.calls.find(call => call.options.method === "POST");
  const payload = JSON.parse(first.options.body);
  assert.equal(rig.state().pending.requestId, payload.requestId);
  assert.equal(rig.el("request-fields").disabled, true);
  assert.equal(rig.el("request-submit").textContent, "Retry same request");
  assert.match(rig.el("request-message").textContent, /Receipt not confirmed.*preserved/);
  assert.equal(JSON.parse(rig.session.getItem(PENDING_KEY)).requestId, payload.requestId);
  const reloaded = await harness({ session: rig.session });
  assert.equal(reloaded.el("request-title").value, payload.title);
  assert.equal(reloaded.el("request-fields").disabled, true);
  reloaded.handler = (path, options) => options.method === "POST"
    ? response({ task: { id: "same-task", state: "queued" }, directive: { id: "same-directive" }, reused: true }) : response(snapshot());
  await reloaded.context.submitRequest(submitEvent);
  assert.equal(reloaded.calls.find(call => call.options.method === "POST").options.body, first.options.body);
  assert.equal(reloaded.state().pending, null);
  assert.equal(reloaded.session.getItem(PENDING_KEY), null);
  assert.equal(reloaded.el("request-fields").disabled, false);
  assert.match(reloaded.el("request-message").textContent, /Request recorded for Claude.*Waiting for worker acknowledgement/);
  assert.equal(reloaded.el("request-title").value, "");
});

test("double submit while awaiting receipt produces one POST and displays queue separately from execution", async () => {
  const rig = await harness();
  rig.typeRequest();
  let accept;
  rig.handler = (path, options) => options.method === "POST" ? new Promise(resolve => { accept = resolve; }) : response(snapshot());
  const sending = rig.context.submitRequest(submitEvent);
  await rig.context.submitRequest(submitEvent);
  assert.equal(rig.calls.filter(call => call.options.method === "POST").length, 1);
  assert.equal(rig.el("request-submit").disabled, true);
  accept(response({ task: { id: "queued-once", state: "queued" }, directive: { id: "one" } }, 201));
  await sending;
  assert.match(rig.el("request-message").textContent, /Waiting for worker acknowledgement/);
  assert.doesNotMatch(rig.el("request-message").textContent, /completed|running|passed/i);
});

test("authorization errors and incomplete receipts retain retry identity; confirmed rejection remains editable", async () => {
  const rig = await harness();
  rig.typeRequest();
  for (const status of [401, 403, 409, 503]) {
    rig.handler = () => response({ error: "Unable to confirm" }, status);
    await rig.context.submitRequest(submitEvent);
    assert.equal(rig.el("request-fields").disabled, true, String(status));
    assert.ok(rig.state().pending);
  }
  const identity = rig.state().pending.requestId;
  assert.equal(new Set(rig.calls.filter(call => call.options.method === "POST").map(call => JSON.parse(call.options.body).requestId)).size, 1);
  rig.handler = () => response({ task: { id: "incomplete" } });
  await rig.context.submitRequest(submitEvent);
  assert.equal(rig.state().pending.requestId, identity);
  assert.match(rig.el("request-message").textContent, /incomplete/);
  rig.handler = () => response({ error: "Invalid scope" }, 400);
  await rig.context.submitRequest(submitEvent);
  assert.equal(rig.state().pending, null);
  assert.equal(rig.el("request-fields").disabled, false);
  assert.equal(rig.el("request-title").value, "Review <private> folder");
  assert.equal(rig.session.getItem(PENDING_KEY), null);
});

test("private titles, progress, decision text and review evidence remain literal text", async () => {
  const rig = await harness();
  const hostile = '<img src=x onerror="steal()"><script>secret()</script>';
  const data = snapshot();
  data.controlPlane.tasks = [{ id: hostile, title: hostile, progress: hostile, objective: hostile, blockedOn: hostile, effectiveState: "working", machine: "m5", manager: "claude" }];
  data.controlPlane.decisions = [{ id: "decision", question: hostile, owner: hostile, status: "open" }];
  data.reviews.items = [{ title: hostile, range: hostile, phase: "closed", verdict: hostile, failure: hostile, document: hostile, findings: 0 }];
  rig.context.renderBoard(data);
  assert.ok(rig.el("progress-cards").textContent.includes(hostile));
  assert.ok(rig.el("needs-cards").textContent.includes(hostile));
  assert.ok(rig.el("review-cards").textContent.includes(hostile));
  assert.match(rig.el("review-cards").textContent, /Findings.*0/);
  assert.equal(rig.created.some(element => ["IMG", "SCRIPT", "IFRAME"].includes(element.tagName)), false);
});

test("stale work and review records cannot appear running; failures keep their distinct outcome", async () => {
  const rig = await harness();
  const data = snapshot();
  data.controlPlane.tasks = [{ id: "unproven", title: "No heartbeat", state: "working" }, { id: "failed", title: "Tests failed", state: "failed", progress: "2 tests failed" }];
  data.reviews.items = [{ title: "Missing process", phase: "running", processAlive: false, findings: 3 }, { title: "Proven process", phase: "running", processAlive: true }];
  rig.context.renderBoard(data);
  assert.match(rig.el("progress-cards").textContent, /Not reporting/);
  assert.equal(rig.el("progress-count").textContent, "1");
  assert.equal(rig.el("finished-count").textContent, "1");
  assert.match(rig.el("finished-cards").textContent, /Failed.*2 tests failed/);
  assert.match(rig.el("review-cards").children[0].textContent, /Not reporting/);
  assert.match(rig.el("review-cards").children[0].textContent, /Findings.*3/);
  assert.match(rig.el("review-cards").children[1].textContent, /Running/);
});

test("rendered lanes stay bounded and newest outcomes are visible first", async () => {
  const rig = await harness();
  const data = snapshot();
  data.controlPlane.tasks = Array.from({ length: 2000 }, (_, i) => ({ id: `task-${i}`, title: `Task ${i}`, state: "done", updatedAt: new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString() }));
  rig.context.renderBoard(data);
  assert.equal(rig.el("finished-count").textContent, "2000");
  assert.equal(rig.el("finished-cards").children.length, 51, "50 work cards plus truncation note");
  assert.match(rig.el("finished-cards").children[0].textContent, /Task 1999/);
  assert.match(rig.el("finished-cards").children.at(-1).textContent, /50 of 2000/);
});

test("unrouted work and unavailable M5 Ultra cannot submit", async () => {
  const rig = await harness();
  rig.typeRequest();
  for (const route of ["", "m5Ultra"]) {
    rig.el("request-machine").value = route;
    await rig.context.submitRequest(submitEvent);
    assert.equal(rig.calls.filter(call => call.options.method === "POST").length, 0);
  }
  assert.match(html, /value="m5Ultra" disabled/);
});

test("finished card retains late failure evidence from the full result, beyond its short progress preview", async () => {
  const rig = await harness();
  const result = "Validation detail. ".repeat(120) + " FINAL: 2 FAILURES; EVIDENCE: docs/reviews/failure.md";
  const data = snapshot();
  data.controlPlane.tasks = [{ id: "result", title: "Completed evaluation", state: "done", progress: result.slice(0, 2000), result }];
  rig.context.renderBoard(data);
  assert.ok(rig.el("finished-cards").textContent.includes(result), "full outcome including late findings must be readable on the card");
});

test("result capacity boundary remains readable and truncated, omitted or absent outcomes are explicit", async () => {
  const rig = await harness();
  const result = "x".repeat(32760) + "THE-END!";
  const full = rig.context.taskCard({ id: "full", state: "done", result });
  assert.ok(full.textContent.includes(result));
  assert.match(full.textContent, /Full reported outcome/);
  assert.match(full.textContent, /Reported complete/);
  assert.doesNotMatch(full.textContent, /passed|truncated/i);
  const truncated = rig.context.taskCard({ id: "truncated", state: "done", result, resultTruncated: true });
  assert.match(truncated.textContent, /outcome \(truncated\)/);
  assert.match(truncated.textContent, /complete result before assessing it/);
  const omitted = rig.context.taskCard({ id: "omitted", state: "done", resultOmitted: true });
  assert.match(omitted.textContent, /Full outcome omitted/);
  const absent = rig.context.taskCard({ id: "absent", state: "done" });
  assert.match(absent.textContent, /Full outcome not recorded/);
});
