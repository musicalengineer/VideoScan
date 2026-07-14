const state = { topics: [], messages: [], activeTopicId: null, busy: false, draft: null };
const $ = selector => document.querySelector(selector);
const elements = {
  topics: $("#topics"), timeline: $("#timeline"), currentTopic: $("#currentTopic"), welcome: $("#welcome"),
  composer: $("#composer"), message: $("#message"), target: $("#target"), send: $("#send"), stop: $("#stop"),
  typing: $("#typing"), status: $("#roomStatus"), pulse: $("#statusPulse"), codex: $("#codexParticipant"), toast: $("#toast"),
};

boot().catch(error => showError(error.message));

async function boot() {
  const data = await api("/api/bootstrap");
  state.topics = data.topics;
  state.messages = data.messages;
  state.activeTopicId = state.topics.find(topic => topic.status === "active")?.id ?? state.topics[0]?.id ?? null;
  setAgent(data.agent);
  render();
  const events = new EventSource("/api/events");
  events.addEventListener("room", event => receive(JSON.parse(event.data)));
  events.onerror = () => setAgent({ connection: "disconnected", busy: state.busy });
}

function receive(event) {
  const { type, data } = event;
  if (type === "snapshot") {
    state.topics = data.topics; state.messages = data.messages; setAgent(data.agent); render(); return;
  }
  if (type === "topic.created") { upsert(state.topics, data); if (!state.activeTopicId) state.activeTopicId = data.id; render(); }
  if (type === "topic.updated") { upsert(state.topics, data); render(); }
  if (type === "message.created") {
    upsert(state.messages, data);
    renderMessages();
  }
  if (type === "turn.started") { state.draft = { topicId: data.topicId, text: "" }; setBusy(true); }
  if (type === "agent.message.delta") { if (state.draft) state.draft.text += data.text; renderMessages(); }
  if (type === "turn.completed" || type === "turn.interrupted") { state.draft = null; setBusy(false); renderMessages(); }
  if (type === "codex.connection") setAgent({ connection: data.state, busy: state.busy });
  if (type === "room.error") { setBusy(false); showError(data.message); }
}

function render() { renderTopics(); renderMessages(); }

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
  const visibleDraft = state.draft?.topicId === state.activeTopicId ? state.draft.text : "";
  if (rows.length === 0 && !visibleDraft) elements.timeline.append(elements.welcome);
  for (const message of rows) elements.timeline.append(messageNode(message));
  if (visibleDraft) elements.timeline.append(messageNode({ id: "draft", author: "codex", body: visibleDraft, createdAt: new Date().toISOString() }));
  requestAnimationFrame(() => { elements.timeline.scrollTop = elements.timeline.scrollHeight; });
}

function messageNode(message) {
  const row = document.createElement("article"); row.className = `message-row ${message.author}`; row.dataset.id = message.id;
  const avatar = document.createElement("div"); avatar.className = "avatar"; avatar.textContent = message.author === "rick" ? "R" : message.author === "codex" ? "C" : "·";
  const card = document.createElement("div"); card.className = "message-card";
  const meta = document.createElement("div"); meta.className = "message-meta";
  const author = document.createElement("strong"); author.textContent = ({ rick: "Rick", codex: "Codex", system: "Room" })[message.author] ?? message.author;
  const time = document.createElement("time"); time.dateTime = message.createdAt; time.textContent = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(new Date(message.createdAt));
  const body = document.createElement("div"); body.className = "message-body"; body.textContent = message.body;
  meta.append(author, time); card.append(meta, body); row.append(avatar, card); return row;
}

function setAgent(agent = {}) {
  state.busy = Boolean(agent.busy);
  const connected = agent.connection === "connected";
  elements.status.textContent = connected ? (state.busy ? "Codex is in conversation" : "Room is ready") : "Codex is offline";
  elements.pulse.classList.toggle("connected", connected);
  elements.codex.classList.toggle("present", connected);
  setBusy(state.busy);
}

function setBusy(busy) {
  state.busy = busy; elements.typing.hidden = !busy; elements.stop.hidden = !busy;
  elements.send.disabled = busy && elements.target.value === "codex";
  if (busy) elements.status.textContent = "Codex is in conversation";
  else if (elements.codex.classList.contains("present")) elements.status.textContent = "Room is ready";
}

elements.composer.addEventListener("submit", async event => {
  event.preventDefault();
  const text = elements.message.value.trim();
  if (!text) return;
  elements.send.disabled = true;
  try {
    await api("/api/messages", { method: "POST", body: { topicId: state.activeTopicId, target: elements.target.value, text } });
    elements.message.value = "";
  } catch (error) { showError(error.message); }
  finally { elements.send.disabled = state.busy && elements.target.value === "codex"; }
});

elements.message.addEventListener("keydown", event => {
  if (event.key === "Enter" && event.metaKey) { event.preventDefault(); elements.composer.requestSubmit(); }
});
elements.target.addEventListener("change", () => { elements.send.disabled = state.busy && elements.target.value === "codex"; });
elements.stop.addEventListener("click", () => api("/api/turns/current/interrupt", { method: "POST", body: {} }).catch(error => showError(error.message)));
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

async function api(url, options = {}) {
  const init = { method: options.method ?? "GET", headers: {} };
  if (options.body !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(options.body); }
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `Request failed (${response.status}).`);
  return body;
}

function upsert(list, value) { const index = list.findIndex(item => item.id === value.id); if (index === -1) list.push(value); else list[index] = value; }
let toastTimer;
function showError(message) { clearTimeout(toastTimer); elements.toast.textContent = message; elements.toast.hidden = false; toastTimer = setTimeout(() => { elements.toast.hidden = true; }, 7000); }
