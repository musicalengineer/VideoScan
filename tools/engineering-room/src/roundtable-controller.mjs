import { randomUUID } from "node:crypto";

const DEFAULT_TURNS = 6;
const SERVER_TURN_CAP = 100;
const DEFAULT_TOKEN_BUDGET = 12000;
const MAX_TOKEN_BUDGET = 2_000_000;
const ACTIVE_STATUSES = new Set(["thinking", "intervention", "recovering"]);

// The filename is retained to keep existing imports stable. This controller is
// now the authenticated, persisted Autopilot state machine.
export class RoundtableController {
  constructor({ agents, database, publish, transcript, roomBrief = () => "", presence = () => false, scheduler = defaultScheduler, attendedDelayMs = 8000, unattendedDelayMs = 250 }) {
    this.agents = agents;
    this.db = database;
    this.publish = publish;
    this.transcript = transcript;
    this.roomBrief = roomBrief;
    this.presence = presence;
    this.scheduler = scheduler;
    this.attendedDelayMs = attendedDelayMs;
    this.unattendedDelayMs = unattendedDelayMs;
    this.timer = null;
    this.expiryTimer = null;
    this.lastHeartbeatPublish = 0;
    const enabled = Boolean(this.db.getState?.("autopilot.enabled", false));
    const saved = this.db.getState?.("autopilot.run", null);
    this.state = saved ? { ...inactiveState(enabled), ...saved, enabled } : inactiveState(enabled);
    this.state.providerCostTokens = Number(saved?.providerCostTokens ?? saved?.consumedTokens) || 0;
    this.state.generatedTokens = Number(saved?.generatedTokens) || 0;
    this.state.consumedTokens = this.state.providerCostTokens; // Backward-compatible snapshot field.
    for (const agent of Object.values(agents)) agent.on("event", event => this.#agentEvent(event));
  }

  get snapshot() { return { ...this.state, maxTurns: this.state.totalTurns }; }
  get active() { return ACTIVE_STATUSES.has(this.state.status); }

  async setEnabled(enabled) {
    if (typeof enabled !== "boolean") throw clientError(400, "Autopilot enabled must be true or false.");
    if (!enabled && this.active) await this.stop("Autopilot was disabled by Rick.");
    this.db.setState?.("autopilot.enabled", enabled);
    this.state = { ...this.state, enabled, lastActivityAt: new Date().toISOString() };
    this.#update();
    return this.snapshot;
  }

  preflight({ turns = DEFAULT_TURNS, tokenBudget = DEFAULT_TOKEN_BUDGET, deadlineAt } = {}) {
    if (!this.state.enabled) throw clientError(409, "Enable Autopilot with the authenticated control before starting a run.");
    if (this.active) throw clientError(409, "Autopilot is already active. Stop it first.");
    const totalTurns = normalizeTurns(turns);
    const normalizedTokenBudget = normalizeTokenBudget(tokenBudget);
    const normalizedDeadline = normalizeDeadline(deadlineAt);
    const unavailable = Object.entries(this.agents).filter(([, agent]) => !["connected", "available"].includes(agent.status.connection));
    if (unavailable.length) throw clientError(409, `${unavailable.map(([provider]) => titleCase(provider)).join(" and ")} must be connected before Autopilot starts.`);
    const busy = Object.entries(this.agents).filter(([, agent]) => agent.status.busy);
    if (busy.length) throw clientError(409, `${busy.map(([provider]) => titleCase(provider)).join(" and ")} must finish before Autopilot starts.`);
    return { totalTurns, tokenBudget: normalizedTokenBudget, deadlineAt: normalizedDeadline };
  }

  async start({ message, topicTitle, objective, turns = DEFAULT_TURNS, tokenBudget = DEFAULT_TOKEN_BUDGET, deadlineAt }) {
    const limits = this.preflight({ turns, tokenBudget, deadlineAt });
    const now = new Date().toISOString();
    this.state = {
      ...inactiveState(true), id: randomUUID(), status: "thinking", topicId: message.topicId, topicTitle,
      initiatorMessageId: message.id, objective, totalTurns: limits.totalTurns, completedTurns: 0,
      tokenBudget: limits.tokenBudget, consumedTokens: 0, providerCostTokens: 0, generatedTokens: 0, tokenCountEstimated: false,
      deadlineAt: limits.deadlineAt, currentProvider: "codex", nextProvider: "claude",
      emptyDeltas: 0, startedAt: now, lastActivityAt: now,
    };
    this.#update();
    this.#armExpiry();
    await this.#askCurrent(message);
    return this.snapshot;
  }

  async recover() {
    if (!this.active) return false;
    if (!this.state.enabled) return this.stop("Autopilot remained disabled after restart.");
    if (Date.now() >= new Date(this.state.deadlineAt).getTime()) return this.stop("The Autopilot deadline expired while the room was offline.", "expired");

    const replies = this.db.snapshot().messages.filter(message => message.replyTo === this.state.initiatorMessageId && ["codex", "claude"].includes(message.author));
    const completedTurns = Math.max(this.state.completedTurns ?? 0, replies.length);
    this.#finalizeSummary();
    if (completedTurns >= this.state.totalTurns) return this.#finish("Turn budget completed.");
    const provider = completedTurns % 2 === 0 ? "codex" : "claude";
    this.state = {
      ...this.state, status: "recovering", completedTurns, currentProvider: provider,
      nextProvider: provider === "codex" ? "claude" : "codex", waitingUntil: null,
      reason: "Recovering persisted Autopilot state after restart.", lastActivityAt: new Date().toISOString(),
    };
    this.#update();
    this.#armExpiry();
    const message = this.db.snapshot().messages.find(item => item.id === this.state.initiatorMessageId);
    if (!message) return this.#fail("The initiating message is no longer available.");
    this.state = { ...this.state, status: "thinking", reason: null };
    this.#update();
    await this.#askCurrent(message);
    return true;
  }

  async stop(reason = "Stopped by Rick.", terminalStatus = "stopped") {
    if (!this.active) return false;
    this.#clearTimers();
    const provider = this.state.currentProvider;
    this.state = { ...this.state, status: terminalStatus, waitingUntil: null, reason, lastActivityAt: new Date().toISOString() };
    this.#finalizeSummary();
    this.#update();
    if (provider && this.agents[provider]?.status.busy) {
      try { await this.agents[provider].interrupt(); } catch { /* Persisted terminal state is already safe. */ }
    }
    this.#statusMessage(this.#closeoutText());
    return true;
  }

  async interject() { return this.stop("Rick interjected; automatic continuation was cancelled."); }

  #agentEvent(event) {
    if (!this.active) return;
    if (event.type === "agent.message.delta" && event.data?.provider === this.state.currentProvider) {
      const now = Date.now();
      if (now - this.lastHeartbeatPublish >= 1000) {
        this.lastHeartbeatPublish = now;
        this.state = { ...this.state, lastActivityAt: new Date(now).toISOString() };
        this.#update();
      }
      return;
    }
    if (this.state.status !== "thinking") return;
    if (event.type === "room.error" && event.data?.provider === this.state.currentProvider) {
      this.#fail(`${titleCase(event.data.provider)} failed: ${event.data.message}`);
      return;
    }
    if (event.type !== "turn.completed" && event.type !== "turn.interrupted") return;
    if (event.data?.provider !== this.state.currentProvider) return;
    if (event.data.status !== "completed") {
      if (this.active) this.#fail(`${titleCase(event.data.provider)} ended with status ${event.data.status}.`);
      return;
    }

    const completedTurns = this.state.completedTurns + 1;
    const providerCostTokens = this.state.providerCostTokens + Math.max(0, Number(event.data.providerCostTokenCount ?? event.data.tokenCount) || 0);
    const generatedTokens = this.state.generatedTokens + Math.max(0, Number(event.data.generatedTokenCount) || 0);
    const semanticDelta = event.data.semanticDelta?.kind ?? null;
    const emptyDeltas = semanticDelta ? 0 : this.state.emptyDeltas + 1;
    const progress = appendSemanticDelta(this.state, event.data.provider, event.data.semanticDelta);
    this.state = {
      ...this.state, ...progress, completedTurns, providerCostTokens, consumedTokens: providerCostTokens, generatedTokens, emptyDeltas,
      tokenCountEstimated: this.state.tokenCountEstimated || Boolean(event.data.tokenCountEstimated),
      lastActivityAt: new Date().toISOString(),
    };

    // Progress/loop safety has precedence over cost accounting. Provider-cost
    // usage may include a large resumed-session context and must never mask two
    // consecutive turns that contributed no semantic delta.
    if (emptyDeltas >= 2) return this.#finish("Loop protection stopped the run after two turns added no decision, evidence, question, or disagreement.", "loop-stopped");
    if (Date.now() >= new Date(this.state.deadlineAt).getTime()) return this.#finish("Deadline expired.", "expired");
    if (completedTurns >= this.state.totalTurns) return this.#finish("Turn budget completed.");
    if (providerCostTokens >= this.state.tokenBudget && emptyDeltas === 0) return this.#finish("Provider-cost token budget reached.", "budget-stopped");

    const nextProvider = this.state.nextProvider;
    const attended = this.presence();
    const delay = attended ? this.attendedDelayMs : this.unattendedDelayMs;
    this.state = {
      ...this.state, status: "intervention", currentProvider: null, nextProvider,
      waitingUntil: new Date(Date.now() + delay).toISOString(),
      reason: attended ? "Waiting briefly for Rick to interject." : "Continuing unattended within explicit limits.",
    };
    this.#update();
    this.timer = this.scheduler.set(() => this.#continue(nextProvider), delay);
  }

  async #continue(provider) {
    this.timer = null;
    if (!this.active || this.state.status !== "intervention" || this.state.nextProvider !== provider) return;
    if (Date.now() >= new Date(this.state.deadlineAt).getTime()) return this.stop("The Autopilot deadline expired.", "expired");
    const message = this.db.snapshot().messages.find(item => item.id === this.state.initiatorMessageId);
    if (!message) return this.#fail("The initiating message is no longer available.");
    this.state = {
      ...this.state, status: "thinking", currentProvider: provider,
      nextProvider: provider === "codex" ? "claude" : "codex", waitingUntil: null,
      reason: null, lastActivityAt: new Date().toISOString(),
    };
    this.#update();
    await this.#askCurrent(message);
  }

  async #askCurrent(message) {
    const provider = this.state.currentProvider;
    const turnNumber = this.state.completedTurns + 1;
    const instruction = `Rick explicitly enabled Autopilot through the authenticated UI for objective: ${this.state.objective}\nThis is turn ${turnNumber} of at most ${this.state.totalTurns}; deadline ${this.state.deadlineAt}; token budget ${this.state.tokenBudget}. Respond directly to the attributed discussion. Do not take actions. End with exactly one line in this form when you add something material: [AUTOPILOT DELTA: decision|evidence|question|disagreement] concise detail. If you add none of those, omit the marker; two consecutive empty deltas stop the run.`;
    try {
      const context = buildCompactAutopilotContext(this.state, this.db.snapshot().messages);
      await this.agents[provider].ask(message, this.state.topicTitle, context, { instruction, freshContext: true, roomBrief: this.roomBrief(provider) });
    } catch (error) {
      this.#fail(`${titleCase(provider)} could not start: ${safeError(error)}`);
    }
  }

  #finish(reason, terminalStatus = "completed") {
    if (!this.active) return false;
    this.#clearTimers();
    this.state = {
      ...this.state, status: terminalStatus, currentProvider: null, nextProvider: null,
      waitingUntil: null, reason, lastActivityAt: new Date().toISOString(),
    };
    this.#finalizeSummary();
    this.#update();
    this.#statusMessage(this.#closeoutText());
    return true;
  }

  #fail(reason) {
    if (!this.active) return false;
    this.#clearTimers();
    this.state = { ...this.state, status: "error", currentProvider: null, nextProvider: null, waitingUntil: null, reason, lastActivityAt: new Date().toISOString() };
    this.#finalizeSummary();
    this.#update();
    this.#statusMessage(this.#closeoutText(), "error");
    return true;
  }

  #finalizeSummary() {
    const replies = this.db.snapshot().messages.filter(message => message.replyTo === this.state.initiatorMessageId && ["codex", "claude"].includes(message.author));
    const items = kind => replies.filter(message => message.deltaKind === kind && message.deltaDetail).map(message => `${titleCase(message.author)}: ${message.deltaDetail}`);
    const decisions = items("decision");
    const evidence = items("evidence");
    const questions = items("question");
    const disagreements = items("disagreement");
    const summary = [...decisions, ...evidence];
    const openDecisions = [...questions, ...disagreements];
    this.state = { ...this.state, summary, openDecisions };
  }

  #closeoutText() {
    const bullets = values => values.length ? values.map(value => `- ${value}`).join("\n") : "- None recorded.";
    return `Autopilot ${this.state.status}: ${this.state.reason}\n\nFinal summary\n${bullets(this.state.summary)}\n\nOpen decisions\n${bullets(this.state.openDecisions)}\n\nTurns: ${this.state.completedTurns}/${this.state.totalTurns} · Generated output: ${this.state.generatedTokens} tokens · Provider cost: ${this.state.providerCostTokens}/${this.state.tokenBudget}${this.state.tokenCountEstimated ? " (includes estimates)" : ""}`;
  }

  #statusMessage(body, kind = "status") {
    const message = this.db.createMessage({ topicId: this.state.topicId, author: "system", kind, body, replyTo: this.state.initiatorMessageId });
    this.publish("message.created", message);
  }

  #armExpiry() {
    if (this.expiryTimer !== null) this.scheduler.clear(this.expiryTimer);
    const delay = Math.max(0, Math.min(2_147_000_000, new Date(this.state.deadlineAt).getTime() - Date.now()));
    this.expiryTimer = this.scheduler.set(() => { this.expiryTimer = null; this.stop("The Autopilot deadline expired.", "expired"); }, delay);
  }

  #update() {
    this.db.setState?.("autopilot.run", this.state);
    this.publish("autopilot.updated", this.snapshot);
  }

  #clearTimers() {
    if (this.timer !== null) this.scheduler.clear(this.timer);
    if (this.expiryTimer !== null) this.scheduler.clear(this.expiryTimer);
    this.timer = null;
    this.expiryTimer = null;
  }
}

export function normalizeTurns(value = DEFAULT_TURNS) {
  const turns = Number(value);
  if (!Number.isSafeInteger(turns) || turns < 2 || turns > SERVER_TURN_CAP) throw clientError(400, `Maximum turns must be between 2 and ${SERVER_TURN_CAP}.`);
  return turns;
}

export function normalizeTokenBudget(value = DEFAULT_TOKEN_BUDGET) {
  const tokens = Number(value);
  if (!Number.isSafeInteger(tokens) || tokens < 256 || tokens > MAX_TOKEN_BUDGET) throw clientError(400, `Token budget must be between 256 and ${MAX_TOKEN_BUDGET}.`);
  return tokens;
}

export function normalizeDeadline(value) {
  const time = new Date(value).getTime();
  const now = Date.now();
  if (!Number.isFinite(time) || time <= now) throw clientError(400, "Deadline must be a valid future date and time.");
  if (time - now > 7 * 24 * 60 * 60 * 1000) throw clientError(400, "Deadline must be within seven days.");
  return new Date(time).toISOString();
}

function inactiveState(enabled = false) {
  return {
    enabled, id: null, status: "inactive", topicId: null, topicTitle: null, initiatorMessageId: null,
    objective: null, totalTurns: 0, completedTurns: 0, tokenBudget: 0, consumedTokens: 0, providerCostTokens: 0, generatedTokens: 0,
    tokenCountEstimated: false, deadlineAt: null, currentProvider: null, nextProvider: null,
    waitingUntil: null, emptyDeltas: 0, startedAt: null, lastActivityAt: null,
    reason: null, summary: [], openDecisions: [],
  };
}

export function buildCompactAutopilotContext(state, messages) {
  const recentTurns = messages
    .filter(message => message.replyTo === state.initiatorMessageId && ["codex", "claude"].includes(message.author))
    .slice(-4)
    .map(message => `${titleCase(message.author)}: ${truncate(message.body, 1600)}`);
  const section = (title, values, empty) => `${title}:\n${values.length ? values.slice(-12).map(value => `- ${truncate(value, 600)}`).join("\n") : `- ${empty}`}`;
  return [
    `Objective:\n${truncate(state.objective ?? "", 2000)}`,
    section("Running summary", state.summary ?? [], "No decisions or evidence recorded yet."),
    `Recent turns:\n${recentTurns.length ? recentTurns.join("\n\n") : "- No agent turns yet."}`,
    section("Open decisions", state.openDecisions ?? [], "None recorded."),
  ].join("\n\n");
}

function appendSemanticDelta(state, provider, delta = {}) {
  if (!delta?.kind || !delta.detail) return { summary: state.summary, openDecisions: state.openDecisions };
  const item = `${titleCase(provider)}: ${delta.detail}`;
  if (["decision", "evidence"].includes(delta.kind)) return { summary: [...state.summary, item], openDecisions: state.openDecisions };
  return { summary: state.summary, openDecisions: [...state.openDecisions, item] };
}

function truncate(value, limit) {
  const text = String(value ?? "").trim();
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}

const defaultScheduler = { set: (callback, delay) => setTimeout(callback, delay), clear: handle => clearTimeout(handle) };
function clientError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }
function safeError(error) { return (error instanceof Error ? error.message : String(error)).replace(/[\r\n]+/g, " ").slice(0, 500); }
function titleCase(value) { return value.charAt(0).toUpperCase() + value.slice(1); }
