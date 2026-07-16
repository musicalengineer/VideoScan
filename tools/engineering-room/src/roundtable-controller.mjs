import { randomUUID } from "node:crypto";

const DEFAULT_TURNS = 4;
const SERVER_TURN_CAP = 12;

export class RoundtableController {
  constructor({ agents, database, publish, transcript, presence = () => false, scheduler = defaultScheduler, attendedDelayMs = 8000, unattendedDelayMs = 250 }) {
    this.agents = agents;
    this.db = database;
    this.publish = publish;
    this.transcript = transcript;
    this.presence = presence;
    this.scheduler = scheduler;
    this.attendedDelayMs = attendedDelayMs;
    this.unattendedDelayMs = unattendedDelayMs;
    this.timer = null;
    this.state = inactiveState();
    for (const agent of Object.values(agents)) agent.on("event", event => this.#agentEvent(event));
  }

  get snapshot() { return { ...this.state }; }
  get active() { return ["thinking", "intervention"].includes(this.state.status); }

  preflight(turns = DEFAULT_TURNS) {
    if (this.active) throw clientError(409, "A roundtable is already active. Stop it or interject first.");
    const totalTurns = normalizeTurns(turns);
    const unavailable = Object.entries(this.agents).filter(([, agent]) => agent.status.connection !== "connected" && agent.status.connection !== "available");
    if (unavailable.length) throw clientError(409, `${unavailable.map(([provider]) => titleCase(provider)).join(" and ")} must be connected before a roundtable starts.`);
    const busy = Object.entries(this.agents).filter(([, agent]) => agent.status.busy);
    if (busy.length) throw clientError(409, `${busy.map(([provider]) => titleCase(provider)).join(" and ")} must finish before a roundtable starts.`);
    return totalTurns;
  }

  async start({ message, topicTitle, turns = DEFAULT_TURNS }) {
    const totalTurns = this.preflight(turns);

    this.state = {
      id: randomUUID(), status: "thinking", topicId: message.topicId, topicTitle,
      initiatorMessageId: message.id, totalTurns, completedTurns: 0,
      currentProvider: "codex", nextProvider: "claude", waitingUntil: null,
      reason: null,
    };
    this.#update();
    await this.#askCurrent(message);
    return this.snapshot;
  }

  async stop(reason = "Stopped by Rick.") {
    if (!this.active) return false;
    this.#clearTimer();
    const provider = this.state.currentProvider;
    this.state = { ...this.state, status: "stopped", waitingUntil: null, reason };
    this.#update();
    if (provider && this.agents[provider]?.status.busy) {
      try { await this.agents[provider].interrupt(); } catch { /* State is already safely stopped. */ }
    }
    this.#statusMessage(`Roundtable stopped: ${reason}`);
    return true;
  }

  async interject() {
    return this.stop("Rick interjected; automatic continuation was cancelled.");
  }

  #agentEvent(event) {
    if (!this.active || this.state.status !== "thinking") return;
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
    if (completedTurns >= this.state.totalTurns) {
      this.state = { ...this.state, completedTurns, status: "completed", currentProvider: null, nextProvider: null, waitingUntil: null, reason: "Turn budget completed." };
      this.#update();
      this.#statusMessage(`Roundtable completed its ${completedTurns}-turn budget.`);
      return;
    }

    const nextProvider = this.state.nextProvider;
    const attended = this.presence();
    const delay = attended ? this.attendedDelayMs : this.unattendedDelayMs;
    this.state = {
      ...this.state, completedTurns, status: "intervention", currentProvider: null,
      nextProvider, waitingUntil: new Date(Date.now() + delay).toISOString(),
      reason: attended ? "Waiting briefly for Rick to interject." : "Continuing unattended within the fixed budget.",
    };
    this.#update();
    this.timer = this.scheduler.set(() => this.#continue(nextProvider), delay);
  }

  async #continue(provider) {
    this.timer = null;
    if (!this.active || this.state.status !== "intervention" || this.state.nextProvider !== provider) return;
    const message = this.db.snapshot().messages.find(item => item.id === this.state.initiatorMessageId);
    if (!message) return this.#fail("The initiating message is no longer available.");
    this.state = {
      ...this.state, status: "thinking", currentProvider: provider,
      nextProvider: provider === "codex" ? "claude" : "codex", waitingUntil: null,
      reason: null,
    };
    this.#update();
    await this.#askCurrent(message);
  }

  async #askCurrent(message) {
    const provider = this.state.currentProvider;
    const turnNumber = this.state.completedTurns + 1;
    const instruction = turnNumber === 1
      ? `Rick explicitly started a bounded ${this.state.totalTurns}-turn roundtable. Give your opening engineering view. Be concise and constructive; do not take actions.`
      : `This is turn ${turnNumber} of ${this.state.totalTurns} in Rick's bounded roundtable. Respond directly to the latest attributed peer response: identify agreement, disagreement, risks, or a useful synthesis. Do not take actions.`;
    try {
      await this.agents[provider].ask(message, this.state.topicTitle, this.transcript(message.topicId, message.id), { instruction });
    } catch (error) {
      this.#fail(`${titleCase(provider)} could not start: ${safeError(error)}`);
    }
  }

  #fail(reason) {
    if (!this.active) return;
    this.#clearTimer();
    this.state = { ...this.state, status: "error", currentProvider: null, nextProvider: null, waitingUntil: null, reason };
    this.#update();
    this.#statusMessage(`Roundtable stopped on error: ${reason}`, "error");
  }

  #statusMessage(body, kind = "status") {
    const message = this.db.createMessage({ topicId: this.state.topicId, author: "system", kind, body, replyTo: this.state.initiatorMessageId });
    this.publish("message.created", message);
  }

  #update() { this.publish("roundtable.updated", this.snapshot); }
  #clearTimer() { if (this.timer !== null) this.scheduler.clear(this.timer); this.timer = null; }
}

export function normalizeTurns(value = DEFAULT_TURNS) {
  const turns = Number(value);
  if (!Number.isSafeInteger(turns) || turns < 2 || turns > SERVER_TURN_CAP) throw clientError(400, `Roundtable turns must be between 2 and ${SERVER_TURN_CAP}.`);
  return turns;
}

function inactiveState() {
  return { id: null, status: "inactive", topicId: null, topicTitle: null, initiatorMessageId: null, totalTurns: 0, completedTurns: 0, currentProvider: null, nextProvider: null, waitingUntil: null, reason: null };
}
const defaultScheduler = { set: (callback, delay) => setTimeout(callback, delay), clear: handle => clearTimeout(handle) };
function clientError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }
function safeError(error) { return (error instanceof Error ? error.message : String(error)).replace(/[\r\n]+/g, " ").slice(0, 500); }
function titleCase(value) { return value.charAt(0).toUpperCase() + value.slice(1); }
