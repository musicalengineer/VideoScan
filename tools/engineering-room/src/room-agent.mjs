import { EventEmitter } from "node:events";

export class RoomAgent extends EventEmitter {
  constructor({ client, database }) {
    super();
    this.client = client;
    this.db = database;
    this.threadId = null;
    this.active = null;
    this.connectionState = "connecting";
    client.on("notification", message => this.#notification(message));
    client.on("connection", status => {
      this.connectionState = status.state;
      this.emit("event", { type: "codex.connection", data: status });
      if (status.state === "disconnected" && this.active) {
        this.#finishFailure(new Error(status.error || "Codex disconnected during the turn."));
      }
    });
    client.on("approvalDenied", () => {
      this.emit("event", { type: "room.error", data: { message: "Codex attempted an action; the room denied it." } });
    });
  }

  get status() {
    return { connection: this.connectionState, busy: Boolean(this.active), turnId: this.active?.localTurn.id ?? null };
  }

  async initialize() {
    const abandoned = this.db.reconcileIncompleteTurns();
    if (abandoned > 0) {
      this.db.createMessage({ author: "system", kind: "error", body: `${abandoned} unfinished Codex turn${abandoned === 1 ? " was" : "s were"} marked failed after the room restarted.` });
    }
    await this.client.connect();
    const saved = this.db.getSession("codex");
    if (saved) {
      try {
        this.threadId = await this.client.resumeThread(saved.externalThreadId);
        return;
      } catch (error) {
        const message = this.db.createMessage({ author: "system", kind: "status", body: `Codex continuity was reset because the saved discussion could not be resumed: ${safeError(error)}` });
        this.emit("event", { type: "message.created", data: message });
      }
    }
    this.threadId = await this.client.startThread();
    this.db.setSession("codex", this.threadId);
  }

  async ask(message, topicTitle = "General discussion") {
    if (this.active) {
      const error = new Error("Codex is still answering the previous message.");
      error.code = "BUSY";
      throw error;
    }
    if (!this.threadId) throw new Error("Codex is not ready yet.");
    const localTurn = this.db.createTurn(message.id);
    this.active = { localTurn, externalTurnId: null, message, deltas: "", pendingNotifications: [], completionTimer: null };
    this.emit("event", { type: "turn.started", data: { turnId: localTurn.id, requestMessageId: message.id, topicId: message.topicId } });
    try {
      const prompt = `[Engineering Room topic: ${topicTitle}]\n\nRick says:\n${message.body}`;
      const externalTurnId = await this.client.startTurn(this.threadId, prompt);
      if (!this.active) return;
      this.active.externalTurnId = externalTurnId;
      this.db.updateTurn(localTurn.id, { externalTurnId, status: "inProgress" });
      const pending = this.active.pendingNotifications.splice(0);
      for (const notification of pending) this.#notification(notification);
      if (!this.active) return;
      this.active.completionTimer = setTimeout(() => {
        if (!this.active || this.active.localTurn.id !== localTurn.id) return;
        this.client.interrupt(this.threadId, externalTurnId).catch(() => {});
        this.#finishFailure(new Error("Codex did not complete the turn within 10 minutes."));
      }, 10 * 60 * 1000);
      this.active.completionTimer.unref?.();
    } catch (error) {
      this.#finishFailure(error);
      return;
    }
  }

  async interrupt() {
    if (!this.active?.externalTurnId) return false;
    await this.client.interrupt(this.threadId, this.active.externalTurnId);
    return true;
  }

  #notification(message) {
    if (!this.active) return;
    const { method, params } = message;
    if ((method === "item/agentMessage/delta" || method === "turn/completed") && !this.active.externalTurnId) {
      this.active.pendingNotifications.push(message);
      return;
    }
    if (method === "item/agentMessage/delta" && params.turnId === this.active.externalTurnId) {
      this.active.deltas += params.delta;
      this.emit("event", { type: "agent.message.delta", data: { turnId: this.active.localTurn.id, text: params.delta } });
      return;
    }
    if (method === "turn/completed" && params.turn?.id === this.active.externalTurnId) {
      const active = this.active;
      const status = params.turn.status;
      const finalText = findFinalText(params.turn.items) || active.deltas.trim();
      clearTimeout(active.completionTimer);
      if (finalText && status === "completed") {
        const response = this.db.createMessage({ topicId: active.message.topicId, author: "codex", body: finalText, replyTo: active.message.id });
        this.emit("event", { type: "message.created", data: response });
      } else if (finalText) {
        const response = this.db.createMessage({ topicId: active.message.topicId, author: "codex", kind: "status", body: `[Partial response — ${status}]\n${finalText}`, replyTo: active.message.id });
        this.emit("event", { type: "message.created", data: response });
      }
      this.db.updateTurn(active.localTurn.id, { externalTurnId: active.externalTurnId, status });
      this.active = null;
      this.emit("event", { type: status === "interrupted" ? "turn.interrupted" : "turn.completed", data: { turnId: active.localTurn.id, status } });
    }
  }

  #finishFailure(error) {
    const active = this.active;
    if (!active) return;
    clearTimeout(active.completionTimer);
    this.db.updateTurn(active.localTurn.id, { externalTurnId: active.externalTurnId, status: "failed" });
    this.active = null;
    this.emit("event", { type: "room.error", data: { turnId: active.localTurn.id, message: safeError(error) } });
    this.emit("event", { type: "turn.completed", data: { turnId: active.localTurn.id, status: "failed" } });
  }
}

function findFinalText(items = []) {
  const messages = items.filter(item => item.type === "agentMessage" && item.text?.trim());
  return (messages.findLast(item => item.phase === "final_answer") ?? messages.at(-1))?.text?.trim() ?? "";
}

function safeError(error) {
  const text = error instanceof Error ? error.message : String(error);
  return text.replace(/[\r\n]+/g, " ").slice(0, 500);
}
