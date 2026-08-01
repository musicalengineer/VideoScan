const state = {
  topics: [], messages: [], activeTopicId: null,
  agents: {
    codex: { connection: "connecting", busy: false },
    claude: { connection: "connecting", busy: false },
    qwen: { connection: "connecting", busy: false },
  },
  drafts: {},
  autopilot: { enabled: false, status: "inactive" },
  controlPlane: { agents: [], tasks: [], decisions: [], events: [] },
};
const $ = selector => document.querySelector(selector);
const elements = {
  topics: $("#topics"), timeline: $("#timeline"), currentTopic: $("#currentTopic"), welcome: $("#welcome"),
  composer: $("#composer"), message: $("#message"), target: $("#target"), send: $("#send"), stop: $("#stop"),
  typing: $("#typing"), typingLabel: $("#typingLabel"), status: $("#roomStatus"), pulse: $("#statusPulse"),
  codex: $("#codexParticipant"), claude: $("#claudeParticipant"), qwen: $("#qwenParticipant"), toast: $("#toast"),
  speak: $("#speakReplies"),
  autopilotStatus: $("#autopilotStatus"), autopilotHeadline: $("#autopilotHeadline"),
  autopilotDetail: $("#autopilotDetail"), autopilotCountdown: $("#autopilotCountdown"),
  autopilotEnabled: $("#autopilotEnabled"), autopilotFields: $("#autopilotFields"),
  autopilotObjective: $("#autopilotObjective"), autopilotDeadline: $("#autopilotDeadline"),
  autopilotTurns: $("#autopilotTurns"), autopilotTokens: $("#autopilotTokens"), startAutopilot: $("#startAutopilot"),
  hint: $("#composerHint"),
  boardSummary: $("#teamBoardSummary"), boardAgents: $("#teamBoardAgents"),
  boardTasks: $("#teamBoardTasks"),
  boardDecisions: $("#teamBoardDecisions"), boardDecisionSummary: $("#teamBoardDecisionSummary"),
  directiveManager: $("#directiveManager"), directiveTaskTitle: $("#directiveTaskTitle"),
  directiveObjective: $("#directiveObjective"), directiveMachine: $("#directiveMachine"), queueDirective: $("#queueDirective"),
};
const speechAvailable = "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;
let speakReplies = speechAvailable && readPreference("engineering-room-speak") === "true";
updateSpeechButton();

boot().catch(error => showError(error.message));

async function boot() {
  const data = await api("/api/bootstrap");
  state.topics = data.topics;
  state.messages = data.messages;
  state.activeTopicId = state.topics.find(topic => topic.status === "active")?.id ?? state.topics[0]?.id ?? null;
  setAgents(data.agents ?? { codex: data.agent });
  state.autopilot = data.autopilot ?? { enabled: false, status: "inactive" };
  state.controlPlane = data.controlPlane ?? state.controlPlane;
  setDefaultDeadline();
  render();
  const events = new EventSource("/api/events");
  events.addEventListener("room", event => receive(JSON.parse(event.data)));
  events.onerror = () => setAgents(Object.fromEntries(Object.entries(state.agents).map(([provider, status]) => [provider, { ...status, connection: "disconnected" }])));
}

function receive(event) {
  const { type, data } = event;
  if (type === "snapshot") {
    state.topics = data.topics; state.messages = data.messages; state.autopilot = data.autopilot ?? { enabled: false, status: "inactive" }; state.controlPlane = data.controlPlane ?? state.controlPlane; setAgents(data.agents ?? { codex: data.agent }); render(); return;
  }
  if (type === "topic.created") { upsert(state.topics, data); if (!state.activeTopicId) state.activeTopicId = data.id; render(); }
  if (type === "topic.updated") { upsert(state.topics, data); render(); }
  if (type === "message.created") {
    const isNew = !state.messages.some(message => message.id === data.id);
    upsert(state.messages, data);
    renderMessages();
    if (isNew && ["codex", "claude", "qwen"].includes(data.author) && speakReplies) speak(`${displayName(data.author)} says. ${data.body}`);
  }
  if (type === "turn.started") {
    state.drafts[data.provider ?? "codex"] = { topicId: data.topicId, text: "" };
    setBusy(data.provider ?? "codex", true);
  }
  if (type === "agent.message.delta") {
    const draft = state.drafts[data.provider ?? "codex"];
    if (draft) draft.text += data.text;
    renderMessages();
  }
  if (type === "turn.completed" || type === "turn.interrupted") {
    delete state.drafts[data.provider ?? "codex"];
    setBusy(data.provider ?? "codex", false); renderMessages();
  }
  if (type === "agent.connection" || type === "codex.connection") {
    const provider = data.provider ?? "codex";
    setAgents({ [provider]: { ...state.agents[provider], connection: data.state } });
  }
  if (type === "room.error") { if (data.provider) setBusy(data.provider, false); showError(data.message); }
  if (type === "autopilot.updated") { state.autopilot = data; renderAutopilot(); updateRoomStatus(); }
  if (type === "control-plane.updated") { state.controlPlane = data; renderTeamBoard(); }
}

function render() { renderTopics(); renderMessages(); renderAutopilot(); renderTeamBoard(); }

function renderTeamBoard() {
  const board = state.controlPlane ?? { agents: [], tasks: [], decisions: [] };
  const counts = new Map();
  for (const agent of board.agents ?? []) counts.set(agent.effectiveState ?? agent.state, (counts.get(agent.effectiveState ?? agent.state) ?? 0) + 1);
  const reporting = (board.agents ?? []).filter(agent => !["not-reporting", "done", "failed"].includes(agent.effectiveState ?? agent.state)).length;
  const notReporting = counts.get("not-reporting") ?? 0;
  elements.boardSummary.textContent = `${reporting} reporting · ${notReporting} not reporting · ${(board.tasks ?? []).filter(task => task.state === "working").length} active tasks`;
  elements.boardAgents.replaceChildren();
  const rank = { blocked: 0, "waiting-on-human": 1, working: 2, idle: 3, "not-reporting": 4, failed: 5, done: 6 };
  for (const agent of [...(board.agents ?? [])].sort((a, b) => (rank[a.effectiveState ?? a.state] ?? 9) - (rank[b.effectiveState ?? b.state] ?? 9) || a.id.localeCompare(b.id))) {
    const card = document.createElement("article");
    const effectiveState = agent.effectiveState ?? agent.state;
    card.className = `board-agent ${effectiveState}`;
    const top = document.createElement("div");
    const name = document.createElement("strong"); name.textContent = agent.displayName ?? agent.id;
    const badge = document.createElement("span"); badge.textContent = effectiveState;
    top.append(name, badge);
    const task = document.createElement("p"); task.textContent = agent.task ? `[${agent.task.machine ?? "unrouted"}] ${agent.task.title}` : "No assigned task";
    const evidence = document.createElement("small");
    evidence.textContent = effectiveState === "not-reporting"
      ? `Last heartbeat: ${formatAge(agent.lastHeartbeatAt)}`
      : `${agent.progress ?? effectiveState} · heartbeat ${formatAge(agent.lastHeartbeatAt)}`;
    card.append(top, task, evidence);
    const agentPercent = parseProgressPercent(agent.progress);
    if (agentPercent !== null) card.append(progressMeter(agentPercent));
    elements.boardAgents.append(card);
  }
  elements.boardDecisions.replaceChildren();
  elements.boardTasks.replaceChildren();
  for (const taskRow of (board.tasks ?? []).filter(task => !["done", "failed"].includes(task.state))) {
    const task = document.createElement("article"); task.className = `board-task ${taskRow.state}`;
    const title = document.createElement("strong"); title.textContent = taskRow.title;
    const detail = document.createElement("small"); detail.textContent = `${taskRow.machine ?? "unrouted"} · ${taskRow.state} · ${taskRow.progress ?? "No progress reported"}`;
    task.append(title, detail);
    const taskPercent = parseProgressPercent(taskRow.progress);
    if (taskPercent !== null) task.append(progressMeter(taskPercent));
    elements.boardTasks.append(task);
  }
  for (const decision of board.decisions ?? []) {
    const item = document.createElement("li"); item.textContent = `${decision.question} — ${decision.owner ?? "unassigned"}`; elements.boardDecisions.append(item);
  }
  elements.boardDecisionSummary.textContent = `Open decisions (${(board.decisions ?? []).length})`;
}

function formatAge(value) {
  if (!value) return "never reported";
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

function parseProgressPercent(value) {
  if (!value) return null;
  const percent = String(value).match(/(?:^|\s)(\d{1,3}(?:\.\d+)?)\s*%/);
  if (percent) return Math.min(100, Math.max(0, Number(percent[1])));
  const ratio = String(value).match(/(?:^|\s)(\d+)\s*\/\s*(\d+)(?:\s|$)/);
  if (!ratio || Number(ratio[2]) <= 0) return null;
  return Math.min(100, Math.max(0, Number(ratio[1]) / Number(ratio[2]) * 100));
}

function progressMeter(percent) {
  const meter = document.createElement("div"); meter.className = "progress-meter";
  meter.setAttribute("role", "progressbar"); meter.setAttribute("aria-valuemin", "0"); meter.setAttribute("aria-valuemax", "100"); meter.setAttribute("aria-valuenow", String(Math.round(percent)));
  const fill = document.createElement("span"); fill.style.width = `${percent}%`;
  const label = document.createElement("b"); label.textContent = `${Math.round(percent)}%`;
  meter.append(fill, label); return meter;
}

function renderTopics() {
  elements.topics.replaceChildren();
  for (const topic of [...state.topics].sort((a, b) => a.position - b.position)) {
    const button = document.createElement("button");
    button.className = `topic ${topic.id === state.activeTopicId ? "active" : ""} ${topic.status}`;
    button.type = "button";
    const dot = document.createElement("span"); dot.className = "dot";
    const title = document.createElement("span"); title.textContent = topic.title;
    const count = document.createElement("small"); count.textContent = String(state.messages.filter(message => message.topicId === topic.id).length);
    button.append(dot, title, count);
    button.addEventListener("click", () => { state.activeTopicId = topic.id; render(); });
    elements.topics.append(button);
  }
  const current = state.topics.find(topic => topic.id === state.activeTopicId);
  elements.currentTopic.textContent = current?.title ?? "Room notes";
  $("#topicMenu").textContent = current?.status === "parked" ? "Reactivate topic" : "Park topic";
}

function renderMessages() {
  const rows = state.messages.filter(message => message.topicId === null || message.topicId === state.activeTopicId);
  elements.timeline.replaceChildren();
  const visibleDrafts = Object.entries(state.drafts).filter(([, draft]) => draft.topicId === state.activeTopicId && draft.text);
  if (rows.length === 0 && visibleDrafts.length === 0) elements.timeline.append(elements.welcome);
  for (const message of rows) elements.timeline.append(messageNode(message));
  for (const [provider, draft] of visibleDrafts) elements.timeline.append(messageNode({ id: `draft-${provider}`, author: provider, body: draft.text, createdAt: new Date().toISOString() }));
  requestAnimationFrame(() => { elements.timeline.scrollTop = elements.timeline.scrollHeight; });
}

function messageNode(message) {
  const row = document.createElement("article"); row.className = `message-row ${message.author}`; row.dataset.id = message.id;
  const avatar = document.createElement("div"); avatar.className = "avatar"; avatar.textContent = ({ rick: "R", codex: "C", claude: "A", qwen: "Q", system: "·" })[message.author] ?? "·";
  const card = document.createElement("div"); card.className = "message-card";
  const meta = document.createElement("div"); meta.className = "message-meta";
  const author = document.createElement("strong"); author.textContent = displayName(message.author);
  const time = document.createElement("time"); time.dateTime = message.createdAt; time.textContent = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(new Date(message.createdAt));
  const body = document.createElement("div"); body.className = "message-body"; body.textContent = message.body;
  meta.append(author, time); card.append(meta, body); row.append(avatar, card); return row;
}

function setAgents(patch = {}) {
  for (const [provider, status] of Object.entries(patch)) state.agents[provider] = { ...state.agents[provider], ...status };
  elements.codex.classList.toggle("present", state.agents.codex.connection === "connected");
  elements.claude.classList.toggle("present", ["connected", "available"].includes(state.agents.claude.connection));
  elements.qwen.classList.toggle("present", state.agents.qwen.connection === "connected");
  updateRoomStatus();
}

function setBusy(provider, busy) {
  state.agents[provider] = { ...state.agents[provider], busy };
  updateRoomStatus();
}

function updateRoomStatus() {
  const busy = Object.entries(state.agents).filter(([, status]) => status.busy).map(([provider]) => displayName(provider));
  const online = Object.values(state.agents).filter(status => ["connected", "available"].includes(status.connection)).length;
  const unverified = Object.values(state.agents).filter(status => status.connection === "available").length;
  const autopilotActive = ["thinking", "intervention", "recovering"].includes(state.autopilot.status);
  elements.typing.hidden = busy.length === 0;
  elements.stop.hidden = busy.length === 0 && !autopilotActive;
  elements.typingLabel.textContent = busy.length ? `${busy.join(" and ")} ${busy.length === 1 ? "is" : "are"} thinking` : "";
  elements.status.textContent = autopilotActive ? `Autopilot ${state.autopilot.completedTurns}/${state.autopilot.totalTurns}` : busy.length ? `${busy.join(" and ")} in conversation` : unverified ? "Room ready · Claude login checks on first message" : online === 3 ? "Room is ready" : `${online}/3 agents available`;
  elements.pulse.classList.toggle("connected", online === 3 && unverified === 0);
  elements.send.disabled = targetBusy();
}

function targetBusy() {
  const target = elements.target.value;
  if (target === "both") return state.agents.codex.busy || state.agents.claude.busy;
  if (target === "all") return Object.values(state.agents).some(agent => agent.busy);
  return Boolean(state.agents[target]?.busy);
}

function renderAutopilot() {
  const autopilot = state.autopilot;
  elements.autopilotEnabled.checked = Boolean(autopilot.enabled);
  elements.autopilotFields.hidden = !autopilot.enabled;
  const active = ["thinking", "intervention", "recovering"].includes(autopilot.status);
  elements.startAutopilot.disabled = active || !autopilot.enabled;
  const visible = autopilot && autopilot.status !== "inactive";
  elements.autopilotStatus.hidden = !visible;
  if (!visible) return;
  const turn = Math.min((autopilot.completedTurns ?? 0) + 1, autopilot.totalTurns ?? 0);
  const provider = autopilot.currentProvider ? displayName(autopilot.currentProvider) : autopilot.nextProvider ? displayName(autopilot.nextProvider) : "";
  elements.autopilotHeadline.textContent = autopilot.status === "thinking"
    ? `Autopilot · turn ${turn}/${autopilot.totalTurns} · ${provider} thinking`
    : autopilot.status === "intervention"
      ? `Autopilot · ${autopilot.completedTurns}/${autopilot.totalTurns} complete · ${provider} next`
      : `Autopilot · ${autopilot.status}`;
  const heartbeat = autopilot.lastActivityAt ? new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit", second: "2-digit" }).format(new Date(autopilot.lastActivityAt)) : "—";
  elements.autopilotDetail.textContent = `${autopilot.reason ?? autopilot.objective ?? "Alternating unattended discussion."} · Output ${autopilot.generatedTokens ?? 0} · Provider cost ${autopilot.providerCostTokens ?? autopilot.consumedTokens ?? 0}/${autopilot.tokenBudget ?? 0} · Last activity ${heartbeat}`;
  elements.autopilotStatus.classList.toggle("error", ["error", "loop-stopped", "budget-stopped", "expired"].includes(autopilot.status));
  updateCountdown();
}

function updateCountdown() {
  const autopilot = state.autopilot;
  if (!["thinking", "intervention", "recovering"].includes(autopilot?.status) || !autopilot.deadlineAt) { elements.autopilotCountdown.textContent = ""; return; }
  const seconds = Math.max(0, Math.ceil((new Date(autopilot.deadlineAt).getTime() - Date.now()) / 1000));
  const minutes = Math.floor(seconds / 60);
  elements.autopilotCountdown.textContent = minutes ? `${minutes}m ${seconds % 60}s left` : `${seconds}s left`;
}
setInterval(updateCountdown, 250);

elements.composer.addEventListener("submit", async event => {
  event.preventDefault();
  const text = elements.message.value.trim();
  if (!text) return;
  elements.send.disabled = true;
  try {
    const body = { topicId: state.activeTopicId, target: elements.target.value, text };
    await api("/api/messages", { method: "POST", body });
    elements.message.value = "";
  } catch (error) { showError(error.message); }
  finally { elements.send.disabled = targetBusy(); }
});

elements.message.addEventListener("keydown", event => {
  if (event.key === "Enter" && event.metaKey) { event.preventDefault(); elements.composer.requestSubmit(); }
});
elements.target.addEventListener("change", () => {
  elements.hint.textContent = "Use your keyboard’s Dictation mic · ⌘ ↵ sends";
  updateRoomStatus();
});
elements.autopilotEnabled.addEventListener("change", async () => {
  const desired = elements.autopilotEnabled.checked;
  elements.autopilotEnabled.disabled = true;
  try {
    state.autopilot = await api("/api/autopilot/control", { method: "POST", body: { enabled: desired } });
    renderAutopilot(); updateRoomStatus();
  } catch (error) { elements.autopilotEnabled.checked = !desired; showError(error.message); }
  finally { elements.autopilotEnabled.disabled = false; }
});
elements.startAutopilot.addEventListener("click", async () => {
  const objective = elements.autopilotObjective.value.trim();
  if (!objective) return showError("Enter an Autopilot objective.");
  elements.startAutopilot.disabled = true;
  try {
    await api("/api/autopilot/start", { method: "POST", body: {
      topicId: state.activeTopicId, objective,
      deadlineAt: new Date(elements.autopilotDeadline.value).toISOString(),
      maxTurns: Number(elements.autopilotTurns.value), tokenBudget: Number(elements.autopilotTokens.value),
    } });
  } catch (error) { showError(error.message); elements.startAutopilot.disabled = false; }
});
elements.stop.addEventListener("click", () => api("/api/turns/current/interrupt", { method: "POST", body: {} }).catch(error => showError(error.message)));
elements.speak.addEventListener("click", () => {
  if (!speechAvailable) return;
  speakReplies = !speakReplies;
  writePreference("engineering-room-speak", String(speakReplies));
  if (!speakReplies) window.speechSynthesis.cancel();
  updateSpeechButton();
});
$("#newTopic").addEventListener("click", async () => {
  const title = window.prompt("New topic name:");
  if (!title?.trim()) return;
  try { const topic = await api("/api/topics", { method: "POST", body: { title } }); state.activeTopicId = topic.id; render(); }
  catch (error) { showError(error.message); }
});
$("#topicMenu").addEventListener("click", async () => {
  const topic = state.topics.find(item => item.id === state.activeTopicId); if (!topic) return;
  try { await api(`/api/topics/${topic.id}`, { method: "PATCH", body: { status: topic.status === "parked" ? "active" : "parked" } }); }
  catch (error) { showError(error.message); }
});
$("#refreshTeamBoard").addEventListener("click", async () => {
  try { const result = await api("/api/control-plane/ingest", { method: "POST", body: {} }); state.controlPlane = result.board; renderTeamBoard(); }
  catch (error) { showError(error.message); }
});
$("#generateRoomBrief").addEventListener("click", async () => {
  try { await api("/api/control-plane/briefs", { method: "POST", body: { publishToRoom: true, topicId: state.activeTopicId } }); }
  catch (error) { showError(error.message); }
});
$("#generateStandup").addEventListener("click", async () => {
  try { await api("/api/control-plane/standups", { method: "POST", body: { publishToRoom: true, topicId: state.activeTopicId } }); }
  catch (error) { showError(error.message); }
});
elements.queueDirective.addEventListener("click", async () => {
  const title = elements.directiveTaskTitle.value.trim();
  const objective = elements.directiveObjective.value.trim();
  const machine = elements.directiveMachine.value;
  if (!title || !objective || !machine) return showError("Enter a task title, objective, and explicit machine route.");
  elements.queueDirective.disabled = true;
  try {
    await api("/api/control-plane/directives", { method: "POST", body: {
      title, objective, machine, manager: elements.directiveManager.value, topicId: state.activeTopicId, priority: 50,
    } });
    elements.directiveTaskTitle.value = ""; elements.directiveObjective.value = ""; elements.directiveMachine.value = "";
  } catch (error) { showError(error.message); }
  finally { elements.queueDirective.disabled = false; }
});
setInterval(renderTeamBoard, 60000);

async function api(url, options = {}) {
  const init = { method: options.method ?? "GET", headers: {} };
  if (options.body !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(options.body); }
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `Request failed (${response.status}).`);
  return body;
}

function upsert(list, value) { const index = list.findIndex(item => item.id === value.id); if (index === -1) list.push(value); else list[index] = value; }
function displayName(author) { return ({ rick: "Rick", codex: "Codex", claude: "Claude", qwen: "Qwen", system: "Room" })[author] ?? author; }
function updateSpeechButton() {
  elements.speak.disabled = !speechAvailable;
  elements.speak.setAttribute("aria-pressed", String(speakReplies));
  elements.speak.textContent = speechAvailable ? `Read replies aloud: ${speakReplies ? "on" : "off"}` : "Spoken replies unavailable";
}
function speak(text) {
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.rate = 1;
  window.speechSynthesis.speak(utterance);
}
function readPreference(key) { try { return localStorage.getItem(key); } catch { return null; } }
function writePreference(key, value) { try { localStorage.setItem(key, value); } catch { /* Current-tab behavior still works. */ } }
function setDefaultDeadline() {
  if (elements.autopilotDeadline.value) return;
  const date = new Date(Date.now() + 30 * 60 * 1000);
  date.setMinutes(date.getMinutes() - date.getTimezoneOffset());
  elements.autopilotDeadline.value = date.toISOString().slice(0, 16);
}
let toastTimer;
function showError(message) { clearTimeout(toastTimer); elements.toast.textContent = message; elements.toast.hidden = false; toastTimer = setTimeout(() => { elements.toast.hidden = true; }, 7000); }
